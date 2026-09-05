//! The shared JSON readers every adjustment op's `parse` is built from, so
//! `adjust` keeps only the schema table, the enum and the dispatch and no
//! parser code lands there twice.
//!
//! Every reader follows the ONE contract the module doc of `adjust` states:
//! a MISSING key takes its default; a key that is present but has the wrong
//! JSON type, or a value outside the range the schema table publishes, makes
//! the whole meta malformed (`None`, and the layer composites as a plain
//! raster layer). JSON cannot encode NaN or an infinity, so a number that
//! reaches these readers is always finite — the narrowing checks below are
//! against the f64 -> f32 overflow a `1e308` literal would cause, not
//! against NaN.
//!
//! **This file is shared and append-only, ordered by first caller.** A
//! reader lands here with the op that first needs it, which is what keeps
//! `cargo clippy -D warnings` green at every step: nothing here is ever
//! unused. The colour and mapping ops added [`boolean`], [`color`] (through
//! `style_names::parse_color`) and [`nested`], the reader for the small
//! fixed-key objects three of them carry (`{cyan_red, magenta_green,
//! yellow_blue}`, `{r, g, b, constant}`, `{c, m, y, k}`) — one reader
//! rather than three near-copies.

use std::ops::RangeInclusive;

use serde_json::{Map, Value};

use crate::style_names::parse_color;

/// `params[key]` as a float inside `range`, or `default` when the key is
/// absent. `None` for a present non-number, a value outside `range`, or a
/// magnitude f32 cannot hold.
pub(crate) fn num_in(
    params: &Map<String, Value>,
    key: &str,
    range: RangeInclusive<f64>,
    default: f64,
) -> Option<f32> {
    let value = match params.get(key) {
        None => default,
        Some(v) => v.as_f64()?,
    };
    if !range.contains(&value) {
        return None;
    }
    let narrowed = value as f32;
    narrowed.is_finite().then_some(narrowed)
}

/// `params[key]` as an INTEGER inside `range` (a float with a zero fraction,
/// e.g. `33.0`, is accepted — the `posterize` precedent). `default` is
/// `None` for a REQUIRED key, in which case an absent key is malformed.
pub(crate) fn int_in(
    params: &Map<String, Value>,
    key: &str,
    range: RangeInclusive<i64>,
    default: Option<i64>,
) -> Option<i64> {
    let value = match params.get(key) {
        None => return default.filter(|d| range.contains(d)),
        Some(v) => v.as_f64()?,
    };
    if value.fract() != 0.0 {
        return None;
    }
    // Rust's float -> int casts saturate, so an absurd magnitude lands at
    // i64::MAX and fails the range test rather than wrapping.
    let n = value as i64;
    range.contains(&n).then_some(n)
}

/// `params[key]` as a nested object. The outer `None` is malformed (the key
/// is present but is not an object); the inner `None` means the key is
/// absent, which every nested block in the schema treats as "all defaults".
pub(crate) fn obj<'a>(
    params: &'a Map<String, Value>,
    key: &str,
) -> Option<Option<&'a Map<String, Value>>> {
    match params.get(key) {
        None => Some(None),
        Some(v) => Some(Some(v.as_object()?)),
    }
}

/// `params[key]` as a string, with the same two-level shape as [`obj`]:
/// outer `None` = present but not a string, inner `None` = absent.
pub(crate) fn text<'a>(params: &'a Map<String, Value>, key: &str) -> Option<Option<&'a str>> {
    match params.get(key) {
        None => Some(None),
        Some(v) => Some(Some(v.as_str()?)),
    }
}

/// The index into `allowed` of `params[key]`'s string value. `default` is
/// `None` for a REQUIRED key; an unlisted string is always malformed.
pub(crate) fn string_enum(
    params: &Map<String, Value>,
    key: &str,
    allowed: &[&str],
    default: Option<usize>,
) -> Option<usize> {
    let Some(value) = params.get(key) else {
        return default;
    };
    let name = value.as_str()?;
    allowed.iter().position(|candidate| *candidate == name)
}

/// `params[key]` as an array of exactly `count` numbers, or `default` when
/// the key is absent. Kept in f64: the values these describe (a LUT's
/// domain) are written back into JSON, and narrowing them first would make
/// a round trip inexact.
pub(crate) fn numbers(
    params: &Map<String, Value>,
    key: &str,
    count: usize,
    default: &[f64],
) -> Option<Vec<f64>> {
    let Some(value) = params.get(key) else {
        return (default.len() == count).then(|| default.to_vec());
    };
    let list = value.as_array()?;
    if list.len() != count {
        return None;
    }
    list.iter().map(Value::as_f64).collect()
}

/// `params[key]` as a boolean, or `default` when the key is absent. A
/// present non-boolean (`"true"`, `1`) is malformed rather than coerced —
/// the same strictness every other reader here applies.
pub(crate) fn boolean(params: &Map<String, Value>, key: &str, default: bool) -> Option<bool> {
    match params.get(key) {
        None => Some(default),
        Some(v) => v.as_bool(),
    }
}

/// `params[key]` as a `"#rrggbb"` colour (the `#rrggbbaa` spelling is
/// accepted and its alpha dropped — `style_names::parse_color`, the ONE
/// colour parser), or `default` when the key is absent.
///
/// The bytes are the DOCUMENT's numbers, not authored sRGB: see the colour
/// note in `adjust`'s module doc for why an adjustment converts nothing.
pub(crate) fn color(params: &Map<String, Value>, key: &str, default: [u8; 3]) -> Option<[u8; 3]> {
    match params.get(key) {
        None => Some(default),
        Some(v) => parse_color(v.as_str()?),
    }
}

/// The N named floats of an OPTIONAL nested object — `color_balance`'s tone
/// triples, `channel_mixer`'s matrix rows and `selective_color`'s ink
/// quartets all have this shape. An absent object takes `defaults` whole; a
/// present one is read key by key with [`num_in`], so a missing key inside
/// it still takes its default and a wrong type or an out-of-range value
/// still makes the whole meta malformed.
pub(crate) fn nested<const N: usize>(
    params: &Map<String, Value>,
    key: &str,
    keys: [&str; N],
    range: RangeInclusive<f64>,
    defaults: [f64; N],
) -> Option<[f32; N]> {
    // `defaults` are the schema table's own literals, so the narrowing is
    // exact — unlike a caller-supplied number, which `num_in` still checks.
    let Some(sub) = obj(params, key)? else {
        return Some(defaults.map(|d| d as f32));
    };
    let mut out = [0.0f32; N];
    for ((slot, name), default) in out.iter_mut().zip(keys).zip(defaults) {
        *slot = num_in(sub, name, range.clone(), default)?;
    }
    Some(out)
}
