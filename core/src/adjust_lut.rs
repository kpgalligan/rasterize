//! The `color_lookup` adjustment end to end: the Adobe Cube LUT (`.cube`)
//! parser, the stored table, trilinear (and linear) evaluation, the strength
//! lerp, and the ONE memo that keeps a big table from being re-parsed on
//! every composite.
//!
//! # Where the table lives, and the storage cap
//!
//! The table is stored IN THE LAYER'S META, base64 of little-endian f32 in
//! red-fastest order, with a hard storage cap of **3D size 33, 1D size
//! 1024**; a larger `.cube` is resampled down to the cap by
//! [`parse_cube_file`], which reports the file's own size as `source_size`
//! so a host can say "resampled from 64".
//!
//! Why a cap at all: the meta travels in `.rz` and in every `get_document`
//! reply, and 33^3 is the industry delivery size (Photoshop's own Color
//! Lookup tables are 32^3). Film-emulation packs are smooth by construction,
//! so the resample is invisible. The 16 MiB `MAX_RZDC_META_LEN` is not the
//! binding constraint — 33^3 is about 575 KB of base64.
//!
//! # The memo, and why it does not violate purity
//!
//! `Adjustment::from_meta` runs on EVERY `composite_layer_into` call, so a
//! 33^3 table would otherwise mean a serde_json scan of a ~575 KB string
//! plus a base64 decode into 431 KB of floats on every render, export,
//! thumbnail and brush dab. Three things fix that, all here:
//!
//! 1. [`CubeLut::table`] is an `Arc<Vec<f32>>` and `Adjustment` derives
//!    `Clone`, so handing back a parsed adjustment is a refcount bump.
//! 2. [`memoized`] keeps [`MEMO_CAPACITY`] entries keyed on the WHOLE meta
//!    string: a cheap sampled prehash (length, the first and last 64 bytes,
//!    every 4096th byte) narrows the candidates and a full `==` on the
//!    string confirms, so a collision is impossible rather than merely
//!    unlikely. A poisoned lock falls through to a normal parse — never a
//!    panic, never an `unwrap`.
//! 3. `from_meta` consults it only when the meta is longer than
//!    [`MEMO_MIN_META_LEN`], so the twenty other ops pay one integer
//!    comparison and nothing else.
//!
//! The memo is transparent — same input, same output, never observable — so
//! it is not the kind of hidden state the core's purity rule forbids.
//!
//! # The format (Adobe Cube LUT Specification 1.0)
//!
//! Plain ASCII, one directive or one data row per line; `#` starts a comment
//! and blank lines are ignored. `TITLE "..."` is optional. Exactly one of
//! `LUT_1D_SIZE n` / `LUT_3D_SIZE n` may appear and it must precede the
//! data. `DOMAIN_MIN r g b` / `DOMAIN_MAX r g b` default to `0 0 0` and
//! `1 1 1`; `LUT_1D_INPUT_RANGE min max` / `LUT_3D_INPUT_RANGE min max` are
//! the Resolve-era spelling of the same bounds on all three channels. Data
//! rows are three whitespace-separated floats, `n` of them for a 1D LUT and
//! `n^3` for a 3D one, with **red changing fastest**
//! (`i = r + g*n + b*n^2`). Values are NOT clamped by the spec (an HDR LUT
//! carries values above 1); the clamp happens on the way into 8 bits.
//!
//! Lookup is trilinear (linear for 1D) over
//! `t_c = clamp((v_c - min_c) / (max_c - min_c), 0, 1) * (n - 1)`; see
//! [`split`]. A zero-width domain is the divide-by-zero landmine and is
//! refused at parse, as is a corner the stored form cannot hold (see
//! [`domain_number`]) — the domain is the one thing about a file a caller
//! cannot re-derive, so it is never quantized into something else.

use std::sync::{Arc, Mutex, OnceLock};

use serde_json::{Map, Number, Value};

use crate::adjust::Adjustment;
use crate::adjust_parse::{int_in, num_in, numbers, string_enum, text};

/// Largest `.cube` file this build will read, checked BEFORE reading it: a
/// `LUT_3D_SIZE 256` file is 16.7 M rows of text, and refusing by size is
/// how every other reader in this crate keeps a hostile file from becoming
/// an allocation.
const MAX_CUBE_BYTES: u64 = 64 * 1024 * 1024;

/// Sizes the PARSER accepts from a file (the spec's 1D bound; 3D is capped
/// at 64 because that is the largest table anyone ships).
const MAX_FILE_1D: i64 = 65536;
const MAX_FILE_3D: i64 = 64;

/// Sizes this build STORES in a layer's meta (the module doc's cap).
const MAX_STORED_1D: i64 = 1024;
const MAX_STORED_3D: i64 = 33;

/// Longest `title` kept, in characters — display only, so a long one is
/// truncated by the file parser rather than failing the whole read.
const MAX_TITLE_CHARS: usize = 128;

/// Meta shorter than this skips the memo entirely (module doc).
pub(crate) const MEMO_MIN_META_LEN: usize = 64 * 1024;

/// How many parsed adjustments the memo holds.
///
/// It must be at least as large as the number of Color Lookup layers ONE
/// COMPOSITE walks, because `Adjustment::from_meta` runs per layer per
/// `composite_layer_into` and the layers are visited in the same order every
/// time: with a capacity below that, the entry evicted is always the one the
/// next lookup asks for, so every layer re-parses its ~575 KB meta on every
/// render, export, thumbnail and live stroke tick — a cache that is worse
/// than none. (Measured on a 64x64 canvas at capacity 2: 0.07 ms of marginal
/// cost per layer up to two layers, then 1.5 ms per layer from the third on,
/// and it never comes back down.) 16 is well past the number of Color Lookup
/// layers a document carries in practice and costs at most a few MB, since
/// each entry is a meta string plus an `Arc` to a table the layer already
/// holds.
const MEMO_CAPACITY: usize = 16;

/// A parsed lookup table. `table` holds `size` (1D) or `size^3` (3D) RGB
/// triples, red fastest.
#[derive(Clone)]
pub(crate) struct CubeLut {
    three_d: bool,
    size: usize,
    domain_min: [f32; 3],
    domain_max: [f32; 3],
    table: Arc<Vec<f32>>,
    strength: f32,
}

impl CubeLut {
    /// Parses the `color_lookup` params per the schema row in `adjust`.
    /// `kind`, `size` and `table` are REQUIRED; `source_size` is accepted
    /// and ignored by the math (it is what the FILE declared, kept so a host
    /// can report "resampled from 64" and so an edit round trip is not
    /// refused for an unknown key).
    pub(crate) fn parse(params: &Map<String, Value>) -> Option<CubeLut> {
        let three_d = string_enum(params, "kind", &["1d", "3d"], None)? == 1;
        let max = if three_d {
            MAX_STORED_3D
        } else {
            MAX_STORED_1D
        };
        let size = int_in(params, "size", 2..=max, None)? as usize;
        // Validated and then discarded: `source_size` is what the FILE
        // declared, for display, and must be ACCEPTED or an edit round trip
        // of a resampled LUT would be refused for an unknown key.
        int_in(params, "source_size", 2..=MAX_FILE_1D, Some(size as i64))?;
        let domain_min = triple(numbers(params, "domain_min", 3, &[0.0, 0.0, 0.0])?)?;
        let domain_max = triple(numbers(params, "domain_max", 3, &[1.0, 1.0, 1.0])?)?;
        if !domain_max.iter().zip(&domain_min).all(|(hi, lo)| hi > lo) {
            return None;
        }
        if let Some(title) = text(params, "title")? {
            if title.chars().count() > MAX_TITLE_CHARS {
                return None;
            }
        }
        let encoded = text(params, "table")??;
        let bytes = base64_decode(encoded)?;
        let entries = node_count(three_d, size).checked_mul(3)?;
        if bytes.len() != entries.checked_mul(4)? {
            return None;
        }
        let mut table = Vec::with_capacity(entries);
        for chunk in bytes.chunks_exact(4) {
            let v = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
            if !v.is_finite() {
                return None;
            }
            table.push(v);
        }
        Some(CubeLut {
            three_d,
            size,
            domain_min,
            domain_max,
            table: Arc::new(table),
            strength: num_in(params, "strength", 0.0..=1.0, 1.0)?,
        })
    }

    /// One straight RGB triple in [0, 1], lerped from the original by
    /// `strength` (1 = the LUT alone, 0 = the identity).
    pub(crate) fn apply(&self, rgb: [f32; 3]) -> [f32; 3] {
        let node = [0, 1, 2].map(|c| self.axis(c, rgb[c]));
        let mapped = if self.three_d {
            sample_3d(&self.table, self.size, node)
        } else {
            [0, 1, 2].map(|c| sample_1d(&self.table, self.size, node[c], c))
        };
        [0, 1, 2].map(|c| rgb[c] + (mapped[c] - rgb[c]) * self.strength)
    }

    /// Channel `c`'s input value in NODE space, [0, size - 1].
    fn axis(&self, c: usize, v: f32) -> f32 {
        let span = self.domain_max[c] - self.domain_min[c];
        ((v - self.domain_min[c]) / span).clamp(0.0, 1.0) * (self.size - 1) as f32
    }
}

/// `size` for a 1D table, `size^3` for a 3D one.
fn node_count(three_d: bool, size: usize) -> usize {
    if three_d {
        size * size * size
    } else {
        size
    }
}

/// The lower node index and the fraction above it for a node-space
/// coordinate. The `min(.., n - 2)` is what keeps the top of the domain from
/// indexing past the end. `n` is always at least 2 — every construction path
/// (the params parse and the file parse) refuses a smaller size.
fn split(t: f32, n: usize) -> (usize, f32) {
    let i = (t.floor().max(0.0) as usize).min(n - 2);
    (i, (t - i as f32).clamp(0.0, 1.0))
}

/// Trilinear sample of a 3D table at a node-space coordinate — THE 3D
/// lookup, shared by evaluation and by the resample to the storage cap.
fn sample_3d(table: &[f32], n: usize, t: [f32; 3]) -> [f32; 3] {
    let (ir, fr) = split(t[0], n);
    let (ig, fg) = split(t[1], n);
    let (ib, fb) = split(t[2], n);
    let mut out = [0.0f32; 3];
    for db in 0..2 {
        let wb = if db == 1 { fb } else { 1.0 - fb };
        for dg in 0..2 {
            let wg = if dg == 1 { fg } else { 1.0 - fg };
            for dr in 0..2 {
                let w = wb * wg * if dr == 1 { fr } else { 1.0 - fr };
                if w == 0.0 {
                    continue;
                }
                let base = ((ir + dr) + (ig + dg) * n + (ib + db) * n * n) * 3;
                for (o, v) in out.iter_mut().zip(&table[base..base + 3]) {
                    *o += w * v;
                }
            }
        }
    }
    out
}

/// Linear sample of channel `c` of a 1D table at a node-space coordinate.
fn sample_1d(table: &[f32], n: usize, t: f32, c: usize) -> f32 {
    let (i, f) = split(t, n);
    table[i * 3 + c] * (1.0 - f) + table[(i + 1) * 3 + c] * f
}

/// A 3-element f64 list narrowed to finite f32.
fn triple(values: Vec<f64>) -> Option<[f32; 3]> {
    let mut out = [0.0f32; 3];
    for (slot, v) in out.iter_mut().zip(values) {
        *slot = v as f32;
        if !slot.is_finite() {
            return None;
        }
    }
    Some(out)
}

/// One domain corner in its STORED form: quantized to six decimals so a
/// `-0.1` does not round-trip as `-0.10000000149`, and `None` when that form
/// is not a number [`CubeLut::parse`] will read back.
///
/// The two ways a corner can fail are the same failure at different scales.
/// `triple` narrows every stored corner to f32, so anything past f32's range
/// (`DOMAIN_MAX 3.5e38`) has no stored representation at all; and past about
/// 1.8e302 the quantizer's own multiply overflows f64, so `Number::from_f64`
/// has nothing to write either. Both are refused rather than substituted:
/// a parser whose contract is "every failure is an `Err`" may not return
/// success carrying a domain the file never declared — that produced params
/// the compositor then refused, and the host was left holding an adjustment
/// layer that did nothing.
fn domain_number(v: f64) -> Option<Number> {
    let quantized = (v * 1e6).round() / 1e6;
    if !(quantized as f32).is_finite() {
        return None;
    }
    Number::from_f64(quantized)
}

// ------------------------------------------------------------ .cube file --

/// Reads the Adobe Cube LUT at `path` and returns the params object a
/// `color_lookup` adjustment stores, as a JSON string. A table larger than
/// this build stores is resampled down to the cap and `source_size` reports
/// what the FILE declared. Every failure is an `Err` naming the path and
/// what was wrong; nothing panics.
///
/// A leading UTF-8 BOM is dropped before the text is read. `String::from_utf8`
/// keeps it as a U+FEFF character, where it glues itself to the first token —
/// so a perfectly good file saved by a Windows tool (Notepad, `Out-File` and
/// several LUT exporters all write one) was refused with
/// "`\u{feff}LUT_3D_SIZE` is not a number", a message that blames the one
/// directive the file got right.
pub(crate) fn parse_cube_file(path: &str) -> Result<String, String> {
    let meta = std::fs::metadata(path).map_err(|e| format!("failed to read {path}: {e}"))?;
    if meta.len() > MAX_CUBE_BYTES {
        return Err(format!(
            "{path} is too large to read as a cube LUT ({} bytes, max {MAX_CUBE_BYTES})",
            meta.len()
        ));
    }
    let bytes = std::fs::read(path).map_err(|e| format!("failed to read {path}: {e}"))?;
    let source = String::from_utf8(bytes)
        .map_err(|_| format!("failed to read {path}: not a valid UTF-8 cube LUT"))?;
    let source = source.strip_prefix('\u{feff}').unwrap_or(&source);
    let parsed = read_cube(source).map_err(|reason| format!("failed to read {path}: {reason}"))?;
    parsed
        .to_params_json()
        .map_err(|reason| format!("failed to read {path}: {reason}"))
}

/// Everything one `.cube` file declares.
struct CubeFile {
    three_d: bool,
    size: usize,
    source_size: usize,
    domain_min: [f64; 3],
    domain_max: [f64; 3],
    table: Vec<f32>,
    title: Option<String>,
}

impl CubeFile {
    /// The stored params object, with each domain corner in the stored form
    /// [`domain_number`] defines. `read_cube` has already refused a corner
    /// with no such form, so the `Err` here is the belt to its braces: the
    /// one thing this may never do is write a number the file did not
    /// declare.
    fn to_params_json(&self) -> Result<String, String> {
        let mut params = Map::new();
        params.insert(
            "kind".into(),
            Value::String(if self.three_d { "3d" } else { "1d" }.into()),
        );
        params.insert("size".into(), Value::from(self.size));
        params.insert("source_size".into(), Value::from(self.source_size));
        for (key, values) in [
            ("domain_min", self.domain_min),
            ("domain_max", self.domain_max),
        ] {
            let mut list = Vec::with_capacity(values.len());
            for v in values {
                let number = domain_number(v)
                    .ok_or_else(|| format!("{key} {v:e} has no stored representation"))?;
                list.push(Value::Number(number));
            }
            params.insert(key.into(), Value::Array(list));
        }
        let mut bytes = Vec::with_capacity(self.table.len() * 4);
        for v in &self.table {
            bytes.extend_from_slice(&v.to_le_bytes());
        }
        params.insert("table".into(), Value::String(base64_encode(&bytes)));
        if let Some(title) = &self.title {
            params.insert("title".into(), Value::String(title.clone()));
        }
        Ok(Value::Object(params).to_string())
    }
}

/// Parses the text of a `.cube` file and resamples it to the storage cap.
fn read_cube(source: &str) -> Result<CubeFile, String> {
    let mut three_d: Option<bool> = None;
    let mut size = 0usize;
    let mut domain_min = [0.0f64, 0.0, 0.0];
    let mut domain_max = [1.0f64, 1.0, 1.0];
    let mut title: Option<String> = None;
    let mut table: Vec<f32> = Vec::new();

    for (n, raw) in source.lines().enumerate() {
        let line = raw.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        let mut parts = line.split_whitespace();
        let head = parts.next().unwrap_or("");
        match head {
            "TITLE" => {
                let rest = line[head.len()..].trim();
                let unquoted = rest.strip_prefix('"').and_then(|s| s.strip_suffix('"'));
                title = Some(
                    unquoted
                        .unwrap_or(rest)
                        .chars()
                        .take(MAX_TITLE_CHARS)
                        .collect(),
                );
            }
            "LUT_1D_SIZE" | "LUT_3D_SIZE" => {
                if three_d.is_some() {
                    return Err(format!("line {}: a second size directive", n + 1));
                }
                if !table.is_empty() {
                    return Err(format!("line {}: the size directive follows data", n + 1));
                }
                let cube = head == "LUT_3D_SIZE";
                let max = if cube { MAX_FILE_3D } else { MAX_FILE_1D };
                let declared = number(&mut parts, n, head)?;
                if declared.fract() != 0.0 {
                    return Err(format!("line {}: {head} must be a whole number", n + 1));
                }
                let value = declared as i64;
                if !(2..=max).contains(&value) {
                    return Err(format!(
                        "line {}: {head} {value} is outside 2..={max}",
                        n + 1
                    ));
                }
                three_d = Some(cube);
                size = value as usize;
            }
            "DOMAIN_MIN" | "DOMAIN_MAX" => {
                let mut bound = [0.0f64; 3];
                for slot in bound.iter_mut() {
                    *slot = number(&mut parts, n, head)?;
                }
                if head == "DOMAIN_MIN" {
                    domain_min = bound;
                } else {
                    domain_max = bound;
                }
            }
            "LUT_1D_INPUT_RANGE" | "LUT_3D_INPUT_RANGE" => {
                let lo = number(&mut parts, n, head)?;
                let hi = number(&mut parts, n, head)?;
                domain_min = [lo; 3];
                domain_max = [hi; 3];
            }
            _ => {
                let mut row = [0.0f32; 3];
                let mut fields = line.split_whitespace();
                for slot in row.iter_mut() {
                    let v = number(&mut fields, n, "data row")?;
                    if !(v as f32).is_finite() {
                        return Err(format!("line {}: a data value is not finite", n + 1));
                    }
                    *slot = v as f32;
                }
                if fields.next().is_some() {
                    return Err(format!("line {}: a data row is not three numbers", n + 1));
                }
                if three_d.is_none() {
                    return Err(format!("line {}: data before any size directive", n + 1));
                }
                table.extend_from_slice(&row);
            }
        }
    }

    let three_d = three_d.ok_or("no LUT_1D_SIZE or LUT_3D_SIZE directive")?;
    let expected = node_count(three_d, size) * 3;
    if table.len() != expected {
        return Err(format!(
            "expected {} data rows, found {}",
            expected / 3,
            table.len() / 3
        ));
    }
    if !domain_max.iter().zip(&domain_min).all(|(hi, lo)| hi > lo) {
        return Err("the domain has zero or negative width".to_string());
    }
    // A corner the STORED form cannot hold is refused here, next to the
    // width check, so `rz_lut_parse_cube` can never hand a host params
    // `CubeLut::parse` will turn round and refuse: the file's own domain is
    // the one thing about it a caller cannot re-derive.
    for (what, bound) in [("DOMAIN_MIN", domain_min), ("DOMAIN_MAX", domain_max)] {
        for v in bound {
            if domain_number(v).is_none() {
                // `{:e}` because the values that reach here are enormous by
                // definition, and a 90-digit literal is not a message.
                return Err(format!(
                    "{what} {v:e} is outside the range a stored domain can hold"
                ));
            }
        }
    }
    let cap = if three_d {
        MAX_STORED_3D
    } else {
        MAX_STORED_1D
    } as usize;
    let (stored, resampled) = if size > cap {
        (cap, resample(&table, three_d, size, cap))
    } else {
        (size, table)
    };
    Ok(CubeFile {
        three_d,
        size: stored,
        source_size: size,
        domain_min,
        domain_max,
        table: resampled,
        title,
    })
}

/// The next whitespace-separated field of `parts` as a finite number.
fn number<'a>(
    parts: &mut impl Iterator<Item = &'a str>,
    line: usize,
    what: &str,
) -> Result<f64, String> {
    let field = parts
        .next()
        .ok_or_else(|| format!("line {}: {what} is missing a value", line + 1))?;
    let value: f64 = field
        .parse()
        .map_err(|_| format!("line {}: `{field}` is not a number", line + 1))?;
    if !value.is_finite() {
        return Err(format!("line {}: `{field}` is not finite", line + 1));
    }
    Ok(value)
}

/// Resamples a table from `from` nodes per axis to `to`, through the SAME
/// interpolation the lookup uses. Node index `i` of the result sits at the
/// same fraction of the domain as `i * (from - 1) / (to - 1)` of the source,
/// so the domain is carried across untouched.
fn resample(table: &[f32], three_d: bool, from: usize, to: usize) -> Vec<f32> {
    let scale = (from - 1) as f32 / (to - 1) as f32;
    let mut out = Vec::with_capacity(node_count(three_d, to) * 3);
    if three_d {
        for b in 0..to {
            for g in 0..to {
                for r in 0..to {
                    let t = [r as f32 * scale, g as f32 * scale, b as f32 * scale];
                    out.extend_from_slice(&sample_3d(table, from, t));
                }
            }
        }
    } else {
        for i in 0..to {
            let t = i as f32 * scale;
            for c in 0..3 {
                out.push(sample_1d(table, from, t, c));
            }
        }
    }
    out
}

// ------------------------------------------------------------- the memo --

/// One memo slot: the sampled prehash, the meta it was parsed from, and the
/// parsed adjustment.
type MemoEntry = (u64, String, Adjustment);

static MEMO: OnceLock<Mutex<Vec<MemoEntry>>> = OnceLock::new();

/// [`Adjustment::from_meta`]'s memoized path for a big meta (module doc).
/// Transparent: the same string always yields the same adjustment, and a
/// poisoned lock simply parses again.
pub(crate) fn memoized(meta: &str, parse: fn(&str) -> Option<Adjustment>) -> Option<Adjustment> {
    let memo = MEMO.get_or_init(|| Mutex::new(Vec::new()));
    let key = prehash(meta);
    if let Ok(mut entries) = memo.lock() {
        if let Some(i) = entries.iter().position(|(h, s, _)| *h == key && s == meta) {
            // Moved to the back, so eviction is genuinely LEAST RECENTLY
            // USED: a document whose layers outnumber the memo then keeps
            // the ones it is actually walking rather than the ones it
            // happened to parse first.
            let hit = entries.remove(i);
            let parsed = hit.2.clone();
            entries.push(hit);
            return Some(parsed);
        }
    }
    // Parsed OUTSIDE the lock: two documents opening at once should not
    // serialize on each other.
    let parsed = parse(meta)?;
    if let Ok(mut entries) = memo.lock() {
        if !entries.iter().any(|(h, s, _)| *h == key && s == meta) {
            while entries.len() >= MEMO_CAPACITY {
                entries.remove(0);
            }
            entries.push((key, meta.to_string(), parsed.clone()));
        }
    }
    Some(parsed)
}

/// FNV-1a over the length, the first and last 64 bytes, and every 4096th
/// byte — cheap on a 575 KB string, and only ever a candidate filter: a hit
/// is confirmed by a full string comparison.
fn prehash(meta: &str) -> u64 {
    fn mix(hash: u64, b: u8) -> u64 {
        (hash ^ u64::from(b)).wrapping_mul(0x100_0000_01b3)
    }
    let bytes = meta.as_bytes();
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes.len().to_le_bytes() {
        hash = mix(hash, b);
    }
    for &b in &bytes[..bytes.len().min(64)] {
        hash = mix(hash, b);
    }
    for &b in &bytes[bytes.len().saturating_sub(64)..] {
        hash = mix(hash, b);
    }
    for i in (0..bytes.len()).step_by(4096) {
        hash = mix(hash, bytes[i]);
    }
    hash
}

// ----------------------------------------------------------- base64 ------

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64 with padding — a few lines rather than a new dependency
/// (`core/Cargo.toml` is deliberately untouched by this feature).
fn base64_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b1 = chunk.get(1).copied().unwrap_or(0);
        let b2 = chunk.get(2).copied().unwrap_or(0);
        let n = (u32::from(chunk[0]) << 16) | (u32::from(b1) << 8) | u32::from(b2);
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(B64[((n >> (18 - 6 * i)) & 0x3f) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// The inverse. ASCII whitespace is skipped (a host may wrap the string);
/// any other character outside the alphabet, or a length that is not a whole
/// number of 4-character groups, is `None`.
fn base64_decode(s: &str) -> Option<Vec<u8>> {
    let mut acc: u32 = 0;
    let mut bits = 0u32;
    let mut pad = 0usize;
    let mut digits = 0usize;
    let mut out = Vec::with_capacity(s.len() / 4 * 3);
    for byte in s.bytes() {
        if byte.is_ascii_whitespace() {
            continue;
        }
        digits += 1;
        if byte == b'=' {
            pad += 1;
            continue;
        }
        if pad != 0 {
            return None; // data after padding
        }
        let value = match byte {
            b'A'..=b'Z' => u32::from(byte - b'A'),
            b'a'..=b'z' => u32::from(byte - b'a') + 26,
            b'0'..=b'9' => u32::from(byte - b'0') + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        };
        acc = (acc << 6) | value;
        bits += 6;
        if bits == 24 {
            out.extend_from_slice(&[(acc >> 16) as u8, (acc >> 8) as u8, acc as u8]);
            acc = 0;
            bits = 0;
        }
    }
    if !digits.is_multiple_of(4) || pad > 2 {
        return None;
    }
    match (bits, pad) {
        (0, 0) => Some(out),
        (12, 2) => {
            out.push((acc >> 4) as u8);
            Some(out)
        }
        (18, 1) => {
            out.extend_from_slice(&[(acc >> 10) as u8, (acc >> 2) as u8]);
            Some(out)
        }
        _ => None,
    }
}
