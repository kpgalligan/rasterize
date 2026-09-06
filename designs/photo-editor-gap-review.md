# From Compositor to Photo Editor: a Gap Review

**Status: in progress (updated 5 September 2026) — phases 1 to 6 of the order in section 4 have shipped; section 0 records what landed, what was decided along the way, and where to restart.** A
fresh-eyes review of the shipped feature set against what a working
photographer actually reaches for in Photoshop, followed by a large, sized
catalog of what to build. Companion to `next-features.md` (whose open
follow-ons — layer groups, layer styles, the healing brush — reappear here
with concrete designs) and `high-leverage-roadmap.md`. The GIMP study
(`gimp-image-manipulation-capabilities.md`) is cited by section where its
mechanism notes apply.

Sizing used throughout: **S** a day or less · **M** a few days · **L** a
week or more · **XL** a model change that touches every op.

---

## 0. Progress and restart notes

Work proceeds in the order of section 4, one phase per commit on the
`refactor` branch. Each phase is built by one ultracode workflow with the
same shape — parallel read-only mappers, an architect plan attacked by
two critics, a sequential "spine" that owns every shared or frozen file,
parallel fill-in items with disjoint file ownership, an integration gate
(cargo fmt, make lint, make test, make typecheck, make app), an MCP
end-to-end drive of the built app per the recipe in `CLAUDE.md`, and
adversarial review rounds (reviewers, one verifier per finding that must
reproduce it, a fix agent) until a round confirms nothing new. Keep the
fan-out modest — five mappers, five fill items, three review lenses, one
verifier per finding — because bursts of parallel agents have tripped
session limits and API overloads mid-run; a workflow resumed with its run
id replays finished agents from cache, and a lone fix is quicker done
directly when subagents keep failing. Re-run the checks yourself before
each commit.

### Phase 1 — layer styles (§2.1): shipped, commit `125795a`

Everything in §2.1 except knockout (deferred; not parsed or stored).
Decisions worth knowing:

- `Layer.style: Option<Arc<LayerStyle>>` is a core field, not `meta`;
  its JSON (schema table in `core/src/style.rs`'s module doc) is the FFI
  and `.rz` contract. `.rz` is at version 4.
- Effects render from the layer's shape (alpha × enabled mask) into
  padded planes cached inside the `Arc<LayerStyle>` and keyed on pixel
  and mask `Arc` pointers; colour-only edits restamp cached planes, brush
  ticks re-render only a sub-plane, and a replaced style inherits the old
  cache lazily. Large blurs downsample. Layer opacity applies once to the
  whole package; effects follow Photoshop's render order; Blend If weights
  source alpha.
- Layer > Layer Style… is one sheet (checklist + a pane per effect, live
  preview), with Copy / Paste / Clear Layer Style; the panel badges "fx".
  MCP: `set_layer_style`, `set_global_light`; `get_document` reports both.
- The sheet itself was never driven interactively (no MCP surface for
  it); worth a manual look.

### Phase 2 — symbolic transforms and text typography (§2.2): shipped, commit `70000ac`

- Text, shape and Live Photo payloads are version 2: `transform`
  `[a, b, c, d]` (row-major on the wire, x′ = a·x + b·y), `origin_frac`,
  and for text `weight`, `italic`, `tracking`, `leading`,
  `baseline_shift`, `underline`, `strikethrough`, `box_width` (null =
  point text). A payload whose new fields are all defaults is still
  written as version 1. `DescribedLayer.swift` holds the anchor rule
  (translation is the core's offset, never the payload's) and
  `DescribedLayerGeometry.swift` the document rotate/flip/resize sync.
- Free Transform and `transform_layer` compose any affine (a parallelogram
  ⌘-corner drag included) and re-render; whole-pixel moves and the core's
  exact forms take the lossless path with a meta patch. True perspective
  still prompts to rasterize. Rasters that a pre-change Image Size
  resampled are detected by size and never re-rendered behind the user's
  back.
- Two core exports were added, one more than the brief asked for:
  `rz_doc_set_layer_content` (pixels + offset + mask atomically) and
  `rz_doc_transform_layer_mask` (harvests a transformed mask without
  resampling pixels about to be replaced). Both are in the header,
  `RasterCore.swift`, the null-safety sweep and `content_tests.rs`.
- The on-canvas text editor stays axis-aligned (opens at the anchor,
  clamped and scrolled into view); rotated shapes re-box through the
  inverse map; frame picks keep map, mask and style.

### Phase 3 — channels (§2.3): shipped, commit `e860fe2`

All of §2.3. Decisions worth knowing:

- `RzDocument.channels: Vec<Channel { name, data: Arc<GrayImage>
  (always canvas-sized), overlay_color, overlay_opacity,
  color_indicates_selected }>` — a core field with a stable per-channel
  id the UI keys its target on (an index would follow the wrong row
  after a delete). `.rz` is at version 5; version 4 loads with an empty
  list. Channel pixels have their own budget
  (`MAX_RZDC_TOTAL_CHANNEL_PIXELS`, 9 × `MAX_PIXELS`, so a whole
  luminosity-mask set fits the largest canvas the app builds), and every
  UI path that creates a channel asks the budget first and names it in
  the refusal.
- `doc_plane.rs` is the ONE plane implementation — reader, writer, the
  paint lerp (`doc.rs`'s mask painting routes through it), the blend,
  the box reduction thumbnails use. `doc_channel.rs` holds the channel
  ops. Every geometry op carries channels; straighten and resize share
  `resample_canvas_plane` with layer masks, so a channel and a mask
  under the same matrix come out byte-identical.
- Plane edits run in the LAYER's own space (filters, fills and
  gradients alike) and write back through `with_layer_space_plane`;
  doing it in canvas space dropped the off-canvas ring and left a seam.
- The edit target is `PaintTarget` (own file, out of the frozen
  controller): layer | mask | plane | channel. Only the coverage-paint
  tools reach a plane or channel — clone, dodge and text refuse rather
  than silently rewriting the whole layer.
- iPhone auxiliary mattes arrive through `AuxiliaryMattes.swift` on the
  HEIC open path. No sample with mattes exists in the repo; that path is
  verified by reading and typecheck only, and a plain HEIC adds none.
- Two review passes (six rounds, five lenses) confirmed and fixed 67
  defects. The rounds never went dry — a feature this size keeps
  yielding minor findings — so the stopping rule was severity, not a
  silent round.

### Phase 4 — colour management and metadata (§3A rows 1–5): shipped, commit `3d22373`

The first five rows of §3A: ICC on open, canvas tagging, embedding on
export, EXIF/XMP/IPTC preservation with the orientation reset, and ppi
with print size and printing. RAW, HEIC/AVIF/JXL export, the histogram
and info panels, linear-light compositing and 16 bit stayed out.
Decisions worth knowing:

- **The colour engine is ours, and `core/Cargo.toml` is untouched.**
  `icc.rs` parses the ICC v2/v4 header and tag table, `icc_transform.rs`
  holds the matrix/TRC model and the transform, `icc_builtin.rs` writes
  the two built-ins (sRGB IEC61966-2.1 and Display P3) as real ICC v2
  blobs — ColorSync and littleCMS both read them back. There is no curve
  *inverter* anywhere: encoding binary-searches 255 forward-evaluated
  thresholds, which is exactly-rounding for every curve kind and cannot
  index out of bounds. `moxcms` is already in the lock file through
  `image`, and the reasons for not promoting it (we must WRITE profiles
  byte-exactly, the four-way parse outcome is ours, and "no input may
  panic" is only guaranteeable for code we test) are in the phase plan.
- **The PCS white comes from the three XYZ tags, full stop.** For a
  matrix/TRC profile `rXYZ`/`gXYZ`/`bXYZ` are already D50-adapted;
  `chad` merely records the adaptation and `wtpt` is advisory. Apple's
  own `sRGB Profile.icc` proves it — D50 columns, no `chad`, a D65
  `wtpt` — so both are parsed and used for nothing.
- **Parsing has five outcomes**, and the unconvertible one is not an
  error: a LUT-based (A2B/B2A) RGB profile is KEPT as the document
  profile, so the pixels stay put, CoreGraphics still displays them
  correctly and an export re-embeds the original bytes byte-for-byte —
  only *our* transform is unavailable, and Assign is offered instead. A
  Gray/CMYK/Lab profile is refused with a sentence saying why, and so is
  one whose profile CLASS is a device link, an abstract transform or a
  named-colour list: those carry RGB numbers while describing a
  transform rather than a space, and CoreGraphics cannot convert out of
  one, so tagging a document with it drew an empty image everywhere at
  once (macOS ships such a profile, `WebSafeColors.icc`).
- `RzDocument` gained `profile: Arc<IccProfile>` (non-optional,
  defaulting to the built-in sRGB — a live document has no "untagged"
  state), `metadata: Metadata` — three independently `Arc`-shared,
  byte-exact `Option<Arc<[u8]>>` packets rather than the brief's single
  `Option<Arc<Metadata>>`, so a document clone is three pointer bumps
  and one packet can be replaced without copying the others — and a ppi
  pair. `doc_color.rs` holds `assign_profile` / `convert_to_profile`
  / `set_resolution` / `set_metadata` and the document-level
  `save_image`, which takes the host's already-warm composite rather
  than re-flattening on every ⌘S.
- **One container walk, one ICC reader.** `metadata.rs` scans JPEG and
  PNG only — those are the two containers we can also splice on the way
  out, so we capture exactly what we can put back — while ICC bytes come
  from `ImageDecoder::icc_profile()`, which already reassembles JPEG
  APP2 chunks and inflates PNG `iCCP` and covers TIFF and WebP too.
  `MetadataInjector` splices on the way out as a stream, so a large save
  does not double peak memory.
- **EXIF is patched in place and never grown**: Orientation → 1 (the
  rotation is baked into the pixels at open, so a preserved 6 would
  double-rotate everywhere), X/YResolution and ResolutionUnit → the
  document's ppi, the pixel-dimension tags → the canvas, and IFD0's
  next-IFD link → 0 so a stale pre-edit thumbnail cannot travel.
  Inserting an absent tag would shift every out-of-line datum and
  corrupt MakerNotes, so an absent tag stays absent and the container's
  own density carries the ppi. A malformation drops the packet rather
  than writing one we could not verify. The Photoshop APP13 run is
  filtered on write — `0x03ED`, `0x040F`, `0x0422`, `0x0424` are
  dropped because they would contradict what we just wrote; every other
  8BIM block survives byte-exactly.
- `.rz` is at **version 6**: a document tail of the ppi pair plus four
  optional blobs, appended after the channel list so a v5 file is a
  strict prefix. The ICC slot is elided when the profile is the built-in
  sRGB, so a plain v6 file is a v5 file plus twelve bytes. Versions 1–5
  still load (sRGB, no metadata, 72 ppi).
- **The working space is a preference, and the open rule is one line**:
  assign the profile the numbers actually belong to, then adopt the
  working space exactly once, for every non-`.rz` open, on both the Rust
  and the ImageIO decode paths. `.rz` is exempt — a native document
  carries its own profile. The consequence to know: under a Display P3
  working space an *untagged* file is converted on open, so opening and
  re-saving it does not reproduce the input bytes. Under the default
  sRGB working space that branch never fires.
- **App side**: `ColorProfile` is the single place a document's pixels
  get a `CGColorSpace` (coverage — masks, channels, brush falloff — and
  UI chrome deliberately do not come there), and the built-in sRGB
  resolves to the platform's *named* space so an sRGB document is
  byte-for-byte where it was before. It answers two questions, not one:
  the pixels' TAG and the space to DRAW into. They differ for exactly the
  LUT profiles the core keeps — ColorSync can display and convert *from*
  such a space but not *into* it, and a CGContext built on one silently
  paints opaque black — so those documents are tagged with their own
  profile and painted in sRGB numbers. An **authored** colour (the colour
  well, a theme default, an MCP hex) converts into the document space
  once; a **sampled** colour (the eyedropper, `sample_color`) converts
  nowhere, so the sample → paint round trip is byte-exact.
- Image > Mode gained Assign Profile…, Convert to Profile… and Working
  Space; the export panel gained Embed colour profile / Strip metadata;
  Image Size gained Resolution with a Resample checkbox and print size
  in inches and centimetres; File gained Print (⌘P) and Page Setup
  (⇧⌘P). MCP grew five tools — `get_color_profile`, `assign_profile`,
  `convert_profile`, `set_resolution`, `get_metadata` — to **70**, and
  `save_copy` took `embed_profile` / `strip_metadata`.
- Known limits, all deliberate: EXIF/XMP/IPTC for JPEG and PNG only, and
  IPTC for JPEG alone since a PNG has nowhere to put an 8BIM run
  (TIFF carries ICC alone, WebP ICC and EXIF, BMP and GIF nothing); a
  TIFF states no print resolution and carries the encoder's 1/1 default,
  which some applications read as 1 dpi; HEIC contributes
  its profile and dpi but no packets, and an export from any document the
  walk skipped says the capture data was never read in (the core answers
  which containers those are, so the host does not restate the policy);
  a Live Photo frame is decoded into
  the working space and labelled with it (there is no per-frame profile
  to preserve); PSD contributes neither profile nor resolution;
  adjustment-layer parameters are not converted by
  Convert to Profile, and neither are layer-style or text colours — those
  are AUTHORED sRGB and convert where they are used (a style's at
  composite time, a text layer's when it re-renders), so an effect
  matches a fill of the same hex and keeps its appearance across a
  convert; ExtendedXMP is neither read nor written; painting
  into a LUT-profile document authors its colours in sRGB numbers (see
  above); and `sample_color`'s `paint_hex` is the *closest* sRGB spelling
  of a pixel, exact only inside the sRGB gamut — outside it the result
  says so rather than clamping silently.
- Verified end to end over MCP against hand-written byte-stream parsers
  and an independent littleCMS cross-check (sRGB→P3 and AdobeRGB→sRGB
  agree code-for-code). Not exercised on screen: the Assign/Convert
  sheets, the Working Space check marks, Image Size with Resample off,
  ⌘P and ⇧⌘P, and a wide-gamut display — all worth one manual pass.

### Phase 5 — the adjustment batch (§3B) plus histogram and info panels (§3A rows 6–7): shipped, commit `c4f38be`

The whole of §3B — twelve new adjustments and the auto trio — plus the
histogram and Info rows of §3A. Match Color and Equalize stayed out (the
spec defers them), and so did the presets browser, on-canvas targeted
adjustment and any change to the existing nine ops' semantics.
Adjustment-layer ops: 9 → **21**. Decisions worth knowing:

- **There is exactly ONE destructive twin, not twelve.**
  `rz_image_adjust_op(img, op, params_json, err_out)` runs
  `Adjustment::from_op` + `adjust_math::apply_to_image` — the same code
  the compositor runs — so "apply the layer" and "run the filter" cannot
  drift, and the invariant is now literal rather than mirrored. Twelve
  exports with up to 37 float parameters each is not a C surface anyone
  could maintain; a JSON + `err_out` FFI has the `rz_doc_set_layer_style`
  precedent. `adjustment_tests.rs`'s parity test gained a row per op.
  Measured end to end over MCP on `samples/plasma.jpg`: all ten pairs of
  full-resolution PNGs saved from `add_adjustment_layer` and from
  `apply_filter` with the same params are **byte-identical**, hashes and
  all. That is not luck — `doc::composite_adjustment_into` takes the
  blended value VERBATIM when `k >= 1.0` (a full-opacity, unmasked
  adjustment) instead of lerping to it, because `cb + (e - cb) * 1.0` is
  not the floating-point identity and a value on an exact half-code
  quantizes one step apart. Delete that branch and the drift comes back;
  `adjustment_tests::full_strength_adjustment_layer_is_byte_identical_over_every_level`
  is what stops that happening silently. The parity table keeps a ±1
  tolerance only for the legacy nine, whose 0–255 arithmetic is frozen.
- **The first stated exception to that invariant is spatial.** Every op is
  a pure function of the pixels handed to it; `shadows_highlights` — the
  only op that reads a neighbourhood — is handed the layer's own image by
  the filter and the backdrop below itself by the layer, so the two agree
  on the same input and are deliberately different pictures on different
  inputs. That is Photoshop's own distinction. It is written verbatim in
  `adjust.rs`'s module doc, the `add_adjustment_layer` catalog entry and
  the README, alongside the other two: the legacy nine's 0–255 arithmetic,
  and `gradient_map`'s position-keyed dither, which the layer counts from
  the canvas and the filter from the layer it was handed — so on a layer
  at a non-zero offset the jitter falls on different pixels (`dither:
  false` makes them exact again).
- **`Adjustment::apply` became `apply_at(rgb, guide, xy)`.** Two
  arguments ride along for ops that cannot be written per pixel:
  `guide` is this pixel's value in the plane `Adjustment::guide` builds
  once per image or composite (Shadows/Highlights' large-radius,
  **alpha-weighted** blur of the luma, routed through the one
  `style_render::blur_plane` — the alpha weighting is what stops a
  cut-out haloing), and `xy` is the pixel's position, canvas on the layer
  path and image on the destructive one, the convention
  `blend::dissolve_threshold` already used. Every other op returns no
  plane and pays one `Option` check. There is deliberately **no plane
  cache** — the plane is a function of the BACKDROP, which a live stroke
  on a layer underneath changes on every tick, so anything keyed more
  cheaply than the backdrop's contents would serve a stale guide. What is
  bounded instead is the cost of building it, and both bounds matter at
  the sizes the app supports (measured at 12 MP through
  `rz_image_adjust_op`, against a 69 ms per-pixel-op baseline): the plane
  is held at the resolution a blur at that radius actually carries
  (`adjust_tone::GuidePlane`, one box-averaged pass into a
  `downsample_factor`-sized grid and a blur of THAT, read back bilinear —
  479 ms → 384 ms at radius 30, and three canvas-sized intermediates plus
  two full-canvas resample round trips replaced by three of 1/64 the
  size); and a Shadows/Highlights whose two amounts are zero never reads
  the guide, so it builds none (428 ms → 162 ms). The earlier record's
  "~2 % of composite time" was measured against a whole-document
  composite that included the layer's own per-pixel cost; the guide alone
  was closer to half of it.
- **An adjustment's parameters are DOCUMENT-space numbers, and no
  adjustment converts anything through a profile.** An `RzImage` carries
  no profile, so a profile-dependent adjustment would make the
  destructive twin and the layer disagree on a non-sRGB document — the
  one thing that must stay tested. So a colour in an adjustment's params
  is the document's numbers, like an eyedropper sample, not an authored
  sRGB colour like a layer style's; where an op needs a space for its
  arithmetic (`white_balance`'s XYZ round trip) it uses the sRGB transfer
  function and sRGB D65 primaries, stated in its schema row. Two visible
  consequences: (1) `gradient_map` reuses `style::GradientFill` and its
  parser — one gradient spelling in the core — so the **same JSON shape
  means different things** under a style (authored sRGB, converted at
  composite time) and under a map (the document's numbers, converted
  nowhere); that sentence is in the schema row, the catalog, the now
  `pub(crate)` `style_json::gradient` and `GradientEditorView`'s class
  doc, and the view takes a `colorSpace` so a future style caller can
  hand it sRGB. (2) **Named presets are still authored colours** — Photo
  Filter's eight, Black & White's `#998a66`, Gradient Map's ramps — so
  they are defined in sRGB and converted into the document's numbers
  ONCE, by the sheet, at the moment the user picks one. What is stored is
  always the document's numbers. White Balance's identity is D65
  (6504 K / 0), snapped exactly rather than left near-identity by the CCT
  fit, because that is the number a photographer expects.
- **The two gamma conventions are the one place a word means opposite
  things**, so all three surfaces say which: `levels`' midtone gamma is
  `out = in^(1/γ)` and above 1 **brightens**; `exposure`'s is
  `out = u^γ` and above 1 **darkens** (Photoshop's Exposure convention),
  with the sheet's slider drawn reversed — 9.99 left, 0.01 right — so
  dragging right lightens while the number falls.
- **A Hue/Saturation band selects on chroma as well as hue.** The ramp
  itself is Photoshop's (inner 15°, falloff 30°, so the six bands sum to
  exactly 1 at every hue and "all six" IS the master edit), but a hue
  alone cannot say which pixels a range is about: `rgb_to_hsl` answers 0°
  for a neutral, so every grey sat at the dead centre of Reds and a pixel
  one 8-bit level off neutral landed on an exact multiple of 60°. Hue and
  Saturation hid it — both are fixed points at zero chroma — while
  Lightness applied the edit in full, so one slider of one range behaved
  unlike all the others and one level of sensor noise blotched. The band
  weight is therefore multiplied by `(min(chroma / 0.05, 1))²` on the
  max-min extent (`adjust_color::band_chroma_gate`): zero at a neutral,
  full by about 13 levels, and quadratic so its slope at zero is zero and
  quantization noise earns 0.6 % of the band rather than 8 %.
- **Shadows/Highlights has ONE radius**, not Photoshop's one per band:
  two radii mean two blurred guide planes per composite for the same
  picture. The schema row says so.
- **The LUT lives in the layer's meta**, base64 little-endian f32, with a
  storage cap of 3D **33** / 1D **1024**; a bigger `.cube` (files up to
  3D 64 / 1D 65536 are read) is resampled down by `rz_lut_parse_cube`,
  which always reports the file's own size as `source_size` so a host can
  say "resampled from 64". 33³ is the industry delivery size and
  film-emulation packs are smooth by construction, so the resample is
  invisible; `MAX_RZDC_META_LEN` (16 MiB) was never the binding
  constraint. **Render cost was the real problem**, since
  `Adjustment::from_meta` runs on every `composite_layer_into`: fixed by
  an `Arc<Vec<f32>>` table, a `Clone` derive, and a 16-entry LRU memo in
  `adjust_lut` keyed on the whole meta string (sampled prehash, verified
  by full equality) consulted **only when `meta.len() > 64 KiB`**, so the
  other twenty ops pay one integer comparison. The capacity is a
  correctness-of-caching matter, not a tuning knob: one composite walks
  the layers in a fixed order, so a memo smaller than the number of
  Color Lookup layers evicts exactly the entry the next lookup wants and
  every layer re-parses its ~575 KB meta on every render. Measured at
  20 MP: a 33³ `color_lookup` layer costs ~1 % of composite time (757 ms
  vs 748 ms). The memo is transparent — same input, same output — which
  is why it does not violate the core's purity rule. `get_document`
  elides the table, replacing it with a placeholder that names the entry
  count and BOTH recovery paths — keep the stored LUT by omitting the key
  or echoing the placeholder back, or replace it wholesale with a `file`
  path (`AgentServer+Adjustments.elidedAdjustmentParams` builds the exact
  wording, and `mergingStoredLut` implements the keep) — and keeps every
  other key, `source_size` included; MCP accepts an input-only
  `params.file` path the app parses and expands.
- **Auto Tone / Contrast / Color are menu commands and MCP tools, never
  layers.** All three derive Levels parameters from the image's own
  histogram — the one `ops_stats::histogram` definition, and its one
  counting rule — and apply them through the existing levels math via a
  new per-channel `rz_image_levels_channels`. Clipping is **0.001
  (0.1 %) per end**, Photoshop's own Auto Color Correction default.
  Auto Color's midtone snap is a **neutral-candidate** mean, not
  gray-world (gray-world neutralises a sunset, a forest or a brick wall,
  whose channel means are legitimately unequal): candidates are counted
  pixels whose post-stretch `max − min < 0.1` and whose luma is in
  0.25–0.75, fewer than 0.5 % of them means every gamma is 1, the
  logarithms are guarded *before* they are taken (a NaN gamma would fail
  the range check and silently refuse the whole op), and the result is
  clamped into [0.5, 2] to bound how far an automatic command may rewrite
  a scene's colour.
- **The alpha rule is the whole point of the histogram's counting
  predicate**: a pixel counts when alpha > 0 and, with a mask, coverage
  ≥ 128 (`doc_select`'s existing contour rule). Every alpha-0 pixel of an
  `RgbaImage` is (0,0,0,0), so an alpha-blind scan spikes bin 0 and pins
  the black point at 0 on any cut-out. Verified on `shapes-alpha.png`:
  58 660 of 160 000 canvas pixels counted, bin 0 empty, and the derived
  black points 0.27 / 0.22 / 0.27 rather than zero.
- **Lab goes through the document's own profile.** `rz_doc_lab`
  linearizes with the profile's own TRC, multiplies by its own `to_pcs`
  columns (already D50-adapted — phase 4's rule) and converts against the
  D50 PCS white; a profile this build cannot model returns false and the
  host says "—" rather than assuming sRGB. Verified against a
  hand-written oracle: the same bytes `#443D45` read L 26.713 / a 4.423 /
  b −3.750 in an sRGB document and L 26.794 / a 5.355 / b −4.004 after
  Assign Display P3, both within 0.02 of the oracle (the residual is the
  profile's s15Fixed16 matrix and parametric TRC against published
  floats).
- **One histogram view, three places.** `HistogramView` draws the bins
  per-channel or as luminosity with a clipping wedge at each end, and is
  used by the new Info tab, by Levels and inside the Curves editor — the
  last two drew nothing behind their controls before. On an adjustment
  layer the plot is `HistogramSource.backdrop(below:)`, captured once at
  sheet open, so it shows what the curve acts on rather than the
  already-corrected composite. `rz_image_histogram` gained a `stride`
  and the panel samples ~4 M pixels on a background loader (bumping the
  stride until `gcd(stride, width) == 1`, so a stride sharing a factor
  with the row length cannot sample the same columns forever); sheets and
  the MCP tool always pass 1.
- **Destructive adjustments moved to `Image ▸ Adjustments`.** There was
  no Adjustments menu; rather than grow Filters to 27 items, the eight
  existing destructive adjustment items moved and Filters kept the true
  pixel filters (Blur, Sharpen, Pixelate, Add Noise, Edge Detect,
  Emboss). Selectors, shortcuts and semantics are untouched. New
  shortcuts: ⇧⌘L Auto Tone, ⌥⇧⌘L Auto Contrast, ⇧⌘B Auto Color, ⌃⌘I
  Info — none collide.
- **Core layout**: `adjust.rs` keeps the schema table, the enum and the
  dispatch; every op's payload struct *and* its `parse` live in its math
  module — `adjust_tone`, `adjust_color`, `adjust_mix`, `adjust_map`,
  `adjust_white_balance`, `adjust_lut`, with `adjust_curves` split out
  and `adjust_math` / `adjust_parse` shared. `ops_stats`, `ops_auto` and
  `lab` are new; `ffi_adjust.rs` holds all seven new shims. `doc.rs`
  changed in one place (the guide plane and the position argument),
  `icc_transform.rs` gained `to_pcs_xyz` (forward only — coming back
  would need the curve inverter this crate deliberately does not have),
  and **`.rz` did not change**: `meta` is an existing slot, so
  `RZDC_VERSION` stays 6.
- **App side**: one `AdjustmentSheet` base class owns the five-step
  live-preview contract for all twelve dialogs, reachable from both
  Image ▸ Adjustments and Layer ▸ New Adjustment Layer; one
  `AdjustmentSchema` table drives MCP validation for the twelve (the
  legacy nine keep their hand-written arms untouched); `GradientEditorView`
  is the reusable stop bar Gradient Map uses — the layer-style Gradient
  Overlay pane was deliberately left alone. The core's gradient model has
  **no per-span midpoint and no separate opacity stops**, so the editor
  has no midpoint diamond; adding one would be a model change
  (`RZDC_VERSION`, schema, parser, writer, Swift mirror, catalog).
- MCP grew five tools — `histogram`, `sample_pixel`, `auto_tone`,
  `auto_contrast`, `auto_color` — to **75**, and `apply_filter` gained
  the twelve op names plus a `params` **object** (the flat namespace was
  already colliding on `gamma`, `levels`, `amount`), validated once in
  `applyFilter` where a refusal can still name the offending key. All
  seventy-five catalog entries and handlers match, and `tools/list`
  returns 75.
- Verified end to end over MCP on `plasma.jpg`, `portrait-exif6.jpg` and
  `shapes-alpha.png`: every op round-trips through
  `add_adjustment_layer` → `get_document` (params echo back byte-identical)
  → `render` → `edit_adjustment_layer` → `undo`; refusals name the
  offending key on **both** surfaces (unknown key, out-of-range value,
  nested unknown key, bad enum, 33 stops, malformed colour, wrong type, a
  malformed `.cube` — `line 2: data row is missing a value` — and a
  missing file); the auto trio reports its derived nine numbers and
  refuses an out-of-range clip. One leniency worth knowing:
  Foundation's NSNumber bridging means JSON `1` is accepted for a boolean
  and `true` for a number, both **normalized** to a valid stored value —
  which is strictly better than the legacy nine, where the same input is
  accepted and then silently degrades the layer to plain raster because
  the core's parse is typed.
- Not exercised on screen (worth one manual pass): all twelve sheets from
  both menus and their live preview; Cancel leaving no undo step and
  Apply exactly one; the gradient editor's add/drag/remove and its
  two-stop floor; the Info readout following the cursor and freezing when
  it leaves; the histogram behind Levels and Curves; Exposure's reversed
  gamma slider; White Balance's "As shot" snap; Hue/Saturation's grid
  resizing as rows collapse; Photo Filter's popup snapping to Custom;
  and footnote widths against the Cancel/Apply row at 420 pt.

### Phase 6 — healing brush and Content-Aware Fill (§3C rows 1–4 + red-eye): shipped, commit `315d98c`

The first four rows of §3C plus red-eye: the **Healing Brush**, the **Spot
Healing Brush**, the **Patch tool**, **Content-Aware Fill** and **Red Eye**
(the drag rectangle and a Vision automatic pass). The Smudge / Blur /
Sharpen / Sponge brushes, the frequency-separation helper and Liquify are the
NEXT retouching phase — no code, no stubs, no enum cases. MCP: 75 → **81**
tools. Decisions worth knowing:

- **Two algorithms, each written once.** `poisson.rs` is the ONE membrane
  solver (the correction form `Δũ = 0`, `ũ|∂Ω = dest − source`, so the
  right-hand side is zero and the seam is exact by construction) and
  `patchmatch.rs`/`patchmatch_nnf.rs` the ONE PatchMatch search, masked
  pyramid and Wexler vote. Every tool is a composition of those two with a
  different source: the Healing Brush and the Patch tool hand the solver
  sampled pixels, Spot Healing and Content-Aware Fill hand it an inpaint.
  `doc_heal::heal_window_into_pixels` is the single write-back all four go
  through, and `doc_heal::components` the single walk all four split their
  coverage with.
- **The solver's schedule is fixed and its accuracy does not decay with the
  region's size.** The plan's cascade (40/48/32 sweeps, 96 updates per
  unknown) was measured to leave 3.0 code values of error at the seam at
  n = 1000 — banding is visible at 1 — so what shipped is red-black
  multigrid: a short cascade for the initial guess, then four V(2,2) cycles.
  It is three times CHEAPER (32 updates per unknown) and a thousand times
  more accurate: 0.0018 code values at the seam at n = 300, 0.0024 at
  n = 1000. Two details had to be measured to get there, and both are in
  `poisson.rs`'s module doc: coarsening the CLASSIFICATION rather than the
  coverage (the obvious rule swallows the one-pixel Dirichlet ring and makes
  the cycle diverge), and a coarse right-hand side scaled by 4 (the stencil
  is the unscaled 5-point Laplacian). There is no convergence test at all —
  a fixed sweep count is the whole stopping rule, so cost is bounded and the
  result deterministic.
- **One overlay currency.** Every healing caller — UI and agent alike —
  builds the same canvas-sized premultiplied RGBA overlay
  `rz_doc_painting_layer` already takes: alpha is the footprint's coverage,
  RGB the already-aligned source. The Healing Brush therefore IS the Clone
  Stamp with a different op at commit, and no offset crosses the FFI. Spot
  Healing is the exception on purpose: its overlay carries coverage only,
  because the core generates the source.
- **The write-back is a hard cut at the α = 128 contour, not the overlay's
  alpha.** Weighting by a soft alpha outside the solved set would blend in
  the *uncorrected* clone — the illumination mismatch the op exists to
  remove — as a fringe around every stroke. The join needs no feather
  because the solution equals the destination on ∂Ω exactly. The visible
  consequence: Hardness SHRINKS the healed footprint rather than fading the
  heal, and Flow is forced to 1 for both healing brushes (a flowed-down dab
  would leave nothing above the threshold to solve), with Opacity carrying
  the strength — the dodge/burn precedent.
- **A SELECTION's soft edge is not a brush dab's, and Content-Aware Fill
  takes its region out to the far edge of the ramp.** The hole was
  `coverage >= 128` for both callers with the write weight taken from the
  byte inside it, so a feathered selection got nothing at coverage 127 and
  half the fill's own effect at 128 — a hard edge exactly on the 50 %
  contour of an edge the user asked to be soft, measured at 9 code values.
  `Caller::hole_threshold` is the one-line distinction: a fill inpaints every
  pixel the selection touches, so the weight rises continuously from 0; a
  brush dab keeps the hard cut above.
- **Caps bound the work of ONE CALL, not the bounding box and not one
  component.** `MAX_INPAINT_HOLE_PIXELS` (1 M) counts the covered pixels of
  the whole selection, `MAX_INPAINT_TARGET_PIXELS` (4 M) bounds the hole
  dilated by its ring, `MAX_INPAINT_PLAN_PIXELS` (80 M) bounds the SUM of
  every part's working window, and `MAX_SOLVE_WINDOW_PIXELS` (32 M) is a
  memory bound on one component's window — that last one per component on
  purpose, because those buffers are freed before the next one starts. A bbox
  cap PER COMPONENT would have refused the tool's most common use — a
  scratch, a wire, a hair — whose box is the whole photo and whose area is a
  few thousand pixels; that case now fills in 0.47 s and has its own test.
  Their SUM still has to be bounded, because the dilated cap cannot see it:
  twenty such scratches on one canvas are 2.7 M dilated and 99 megapixels of
  window, and measured 14.1 s.
- **The measured cost, and the number that turned out to be an artifact.** A
  300 × 300 hole in a 2000 × 1500 photograph is 0.53 s in the core and 0.75 s
  through the app; at the megapixel cap the fill is **~5 s, at every ring** —
  5.4 s at a requested 48 (rule 1 widens it to 282), 5.2 s at 512 — and,
  since the pyramid defect below was fixed, the same wherever in the frame
  the selection sits. The worst PERMITTED call found is about twelve seconds,
  which is what the caps are sized to, and inside the 15 s budget §0.3 set.
  An earlier pass recorded 32–41 s at the automatic ring and concluded "the
  ring, not the hole, drives the cost", which put a false five-fold ring
  effect into the module doc, the catalog entry, the sheet footnote and the
  README, together with the advice to pass a ring explicitly for a large
  fill. Both halves were wrong: the slow numbers were measured in an
  App-Napped app (next bullet), and rule 1 widens a small explicit ring from
  below anyway, so on a megapixel hole a requested 21, 48, 100 and 282 are
  all the same 282.
  **Cost follows the region DILATED by its sampling ring, plus the bounding
  boxes the separate parts are worked in — never the selected count**; a
  linear fit over the measured shapes is 0.1 s per megapixel of window plus
  1.2 s per megapixel of dilated region, and a 3 px scratch selecting 6 k
  pixels costs more than a compact 90 k selection. To make a fill cheaper,
  shorten the region or select fewer separate parts — thinning it buys
  nothing. A pass that recorded "cost is the SELECTION's area" here had
  generalized one 2000 × 1500 scratch measurement, which the 5000 × 5000 rows
  in `doc_inpaint`'s own table falsify by a factor of ten; sizing a cap from
  that model would bound the one quantity that does not drive the time.
  Rule 1 is unchanged: it is a quality rule, and it costs nothing — and,
  since the ring the caller passes now sizes nothing (the ring the NARROWING
  settles on does), that is true of a scattered selection too, where a
  requested 512 used to cost 26× a requested 21.
- **A refusal is decided from the components' BOUNDING BOXES, before a
  window exists.** `inpaint_plan` climbs its ladder twice. The first pass is
  arithmetic over the boxes — every component dilates to at least a
  quarter-disc of its ring, and to at least `bw·(ring+1)` and `bh·(ring+1)`,
  since a 4-connected run occupies every column and row of its own box — and
  it answers both "could this fit at all" and "which ring is worth measuring
  exactly". Only then does the exact pass run a distance transform per
  component, and its windows are sized from the ring the NARROWING settled
  on rather than the one the caller asked for. The pass exists because
  neither was true before: 90 000 one-pixel specks cost 2.4 s to refuse and a
  million cost 28.7 s (7 ms and 15 ms now), and `ring: 512` on a scattered
  selection multiplied every window by 26 — 78.9 s against 3.0 s — on a
  parameter the schema calls free.
- **A preview is bounded by the PART COUNT as well as by the reduction.** A
  component's window is at least `2·RING_MIN` on a side, so a small part
  cannot be reduced at all, and it still costs ~3.4 ms — its planes, its
  transform, its pyramid, its integral image and a membrane solve. A dust
  selection is nothing but small parts, so the "reduced" preview cost what
  the fill cost (2.3 s for 900 specks, and 9.8 s for the largest speck
  selection the caps admit) with the sheet's Cancel blocking on it. It now
  fills the biggest 200 parts and leaves the rest showing the original:
  0.28-0.80 s on every shape measured.
- **App Nap demotes the app after its first multi-second op, and does not
  undo it** — the phase's most useful measurement, and the thing that made
  the fill look 5x slower than it is. On a freshly launched app a 300 × 300
  fill measures 0.75 s four times running; run one megapixel fill (7 s of
  solid main-thread compute) and the same 300 × 300 fill measures 3.4–3.9 s
  for the rest of the session, whatever is frontmost and however long the app
  then idles. The process burns CPU throughout (CPU time tracks wall time),
  the identical core call in a command-line process is unaffected before and
  after, and `-NSAppSleepDisabled YES` removes the effect entirely. The fix
  is one assertion, `AppActivity.userInitiated`, held around every tool call
  by both agent trampolines (`AgentServer.swift`, `Assistant.swift`) — a tool
  call is user-initiated work by definition. It applies to every heavy op the
  agent drives, not only this one; the UI's own edits do not need it, since a
  foreground app is not napped.
- **Red-eye scores red DOMINANCE, not `R > G`.** `doc_redeye.rs`'s module doc
  carries the fifteen-colour table that is the proof — every skin tone passes
  `R > G` — and the shipped gate is the ratio `R/((G+B)/2)` times HSV
  saturation times hue proximity. A specular catchlight scores zero and comes
  out bit-identical, which is the quality difference and has a test.
  `pupil_size` defaults to **100 %** of the rectangle's SHORTER side, not 50:
  its job is to spare a red shirt caught by a sloppy rectangle, not to
  require a small pupil — at 50 the tool refused its own documented gesture.
  That default alone was a no-op, though, and the end-to-end pass caught it:
  a component is clipped to the rectangle, so on a square one its larger side
  can never exceed the rectangle's shorter side, and a 70 × 70 rectangle
  dragged over a red cloud desaturated all 4900 of its pixels into a
  hard-edged square. A second rule now runs beside the size gate — **a
  component that reaches all four sides of the rectangle is rejected** — which
  refuses exactly that case (the rectangle is inside the red, with no pupil in
  it to find) and cannot reject a plausible drag, since a pupil that touches
  all four sides means the rectangle is inside the pupil. It is deliberately
  the weakest form of the test: a red region filling most but not all of the
  rectangle still passes at 100 %, and turning Pupil Size down is how the user
  says so. Two tests hold both ends of it.
- **Vision's face landmarks are the second platform-model seam**
  (`RedEye.swift`, beside `SubjectSelection.swift`), and they are NOT flat in
  image size the way segmentation is: 3–5 ms warm at 1 MP, 29–30 ms at
  48 MP, plus ~3 ms per face for the landmark stage, so the whole automatic
  pass stays on the main thread with no new queue. No repo sample holds a
  face Vision will find, so the detector is verified by probes only and
  `red_eye_auto` takes an explicit `eyes` array to drive the rest end to end
  — the phase-3 auxiliary-mattes precedent. With no face it says so and
  changes nothing.
- **Deliberately left out, and said so everywhere**: the Healing Brush's
  Replace mode (in this build it would be exactly the Clone Stamp), and Spot
  Healing's Proximity Match and Create Texture (Content-Aware is the only
  type). The Patch tool's default direction is Source, Photoshop's.
- **Verified end to end over MCP** on the built app: 81 tools; a blemish
  healed out of an exactly linear gradient comes back **byte-identical to the
  pristine gradient**, and one undo restores the blemish; the same seed twice
  gives byte-identical fills and spot heals, a different seed differs; every
  pixel outside a selection is untouched by Content-Aware Fill; the cap
  refusals name their limits; a patch whose source falls off-canvas refuses
  with a sentence; (220,40,45) corrects to (26,24,27) with the catchlight
  bit-identical, and `pupil_size` 50 refuses the same disc. Each of the six
  tools is exactly one undo step. That pass is also what found the two
  defects the bullets above record; both are fixed and re-verified on the
  built app — three megapixel fills in ONE session at 7.2 / 7.3 / 7.3 s with
  no drift, and the 70 × 70 rectangle over a red cloud in `plasma.jpg`
  refused with the sentence that names the rule, while a tight rectangle over
  the synthetic eye still corrects.
- **Seven defects the second review pass found, all fixed and re-verified.**
  Four were the same root cause in different clothes and one was a crash:
  (1) `patchmatch::should_coarsen` took the NARROWEST of the window's four
  margins, and the window is clamped to the canvas — so any selection
  touching a border built no pyramid and ran the coarsest level's schedule at
  full resolution: 1.66 s against 0.71 s and 2.9x the error for a 300 × 300
  hole, 19.4 s against 8.5 s at the megapixel cap. It is the widest margin
  now, and a ratio test holds it. (2) Both work caps were tested per
  connected COMPONENT, so four disjoint 620 × 620 squares — half again the
  documented megapixel — were accepted and cost the sum, with nothing
  bounding the component count; they bound the call now. (3) Spot healing
  passed the brush dab's raw alpha as the write weight, so a soft tip faded
  the heal instead of shrinking the footprint and left a visible ghost of the
  blemish — the exact opposite of the hard-cut bullet above, which is now
  true of every caller but Content-Aware Fill. (4) `RasterDocument.redEyeLayer`
  converted an unbounded `Double` with `Int(_:)`, which TRAPS rather than
  saturating: `red_eye {"x": 1e300, …}` killed the process and every open
  document's unsaved work. It clamps in Double space now, and both red-eye
  handlers wall their arguments at ±100,000 px like `parsePoints` and
  `patch_region`. (5) The inpaint driver cloned the whole layer buffer per
  component — 20 s of pure `memcpy` for a thousand-speck dust selection on a
  100 MP canvas — and now threads one clone, `heal_layer`'s rule. (6) The
  precomputed finest-level distance transform was consumed on the coarsest
  iteration and discarded, so every multi-level fill paid two full-resolution
  exact EDTs. (7) The C header and both MCP schemas said the ring clamps to
  `[7, 512]`; the floor is `3·PATCH` = 21, and every value from 1 to 20
  silently produced the same result. Three Swift ones came with them: the
  Content-Aware Fill sheet previewed the layer it captured but filled
  whatever was active at Apply (an MCP `set_active_layer` behind a sheet is
  enough); the Patch tool's close-the-outline threshold was 8 CANVAS px where
  the Lasso's identical gesture uses 8 SCREEN px, so the same click behaved
  differently at every zoom; and the canvas cancelled the patch session on
  ANY image swap, so the patch's own commit destroyed the region it had just
  placed and "a second patch from the same outline is one more drag" never
  held.
- Not exercised on screen (worth one manual pass): the four tools' drags
  themselves — the Healing Brush's raw-clone preview being replaced at
  mouse-up, Spot Healing's blue footprint ghost, the Patch outline and its
  drag feedback (click-a-polygon, double-click or Return to close), the Red
  Eye marquee — the Content-Aware Fill sheet with its live preview and
  Cancel/Apply, the options-bar rows (Aligned, Sample All Layers, Pupil Size,
  Darken, Direction), the rail's new fifth slot and `p` cycling its four
  tools, and Filters > Remove Red Eye on a real photograph of a face.

### Remaining order

Section 4's steps 7–8 in order — groups, lock, multi-select, guides and
snapping is next, then RAW develop and Actions — then the breadth of
section 3. The rest of §3C (the Smudge / Blur / Sharpen / Sponge brushes,
frequency separation and Liquify) is a phase of its own whenever it is
reached. Kevin asked on 3 September
for this to run through the whole list without stopping between phases:
finish, commit, start the next.

---

## 1. Where the app stands

What has shipped is a *compositing and painting* editor with unusually
good bones for its age:

- The layer model is right: `Arc`-shared pure ops, an f32 compositor, the
  complete 27-mode Photoshop blend set, masks, clipping groups, and an
  opaque `meta` slot that already carries three parametric layer types
  (text, shape, Live Photo) plus adjustment layers.
- Non-destructive adjustments chain in f32 on the accumulator, so five
  stacked adjustment layers do not quantize between steps. Only the
  destructive Filters-menu twins round to 8 bits.
- Selections are canvas-sized coverage masks with real algebra,
  feathering, Euclidean morphology, Quick Mask, and Vision subject
  segmentation. That representation is what makes channels (§4) cheap.
- Free Transform is a true homography pipeline resampling in premultiplied
  alpha; the brush engine has the full Photoshop tip set.
- The MCP catalog and the built-in assistant are a scripting API nobody
  else has.

Three findings that the README's feature list hides, in order of how much
they matter to a photographer:

1. **Color is not managed at all.** The core reads pixel bytes and drops
   the ICC profile; the save path writes none. An iPhone photo (Display
   P3) opens with its numbers reinterpreted as sRGB, so saturated reds and
   greens are wrong on screen and wrong in the export. EXIF and XMP are
   stripped on export; there is no DPI, so a print shop gets a 72-ppi file.
   This is invisible in the feature list and the first thing a photographer
   would notice as "the colours look off in Rasterize". §3A.
2. **Parametric layers cannot be transformed.** Free Transform on a text
   or shape layer asks to rasterize. Worse, the README's own known limit —
   document rotate/flip leave a text layer's description upright, so the
   next re-edit re-renders it at the wrong angle — is the same bug seen
   from the other side. One `transform` field on the payload fixes both.
   §2.2.
3. **The stack is a list, not a tree, and a layer has no styles.** No
   groups, no layer effects, no alpha channels, no lock. These are the
   features that make a 20-layer retouch manageable, and 20 layers is
   where adjustment layers and shape layers push every document.

Everything else is breadth — adjustments, brushes, filters, selection
tools — and breadth is cheap here because each new adjustment or filter
is one Rust variant that lands simultaneously as an adjustment layer, a
destructive twin, and an MCP tool.

---

## 2. The three requested features

### 2.1 Layer styles and blending options (drop shadow first) — SHIPPED (§0)

Blend *modes* are done. What is missing is Photoshop's **Layer Style**
dialog, whose first pane is titled "Blending Options": the effect stack
(fx) and the per-layer compositing knobs beyond opacity and mode.

**Model.** A new core field, not more `meta`: the compositor must
interpret styles, and a text layer's `meta` is already spoken for.

```
Layer.style: Option<Arc<LayerStyle>>
LayerStyle {
  fill_opacity: f32,             // opacity of the pixels, not of the effects
  knockout: None|Shallow|Deep,   // punch through to the group base / bottom
  blend_if: Option<BlendIf>,     // channel, this-layer and underlying ranges,
                                 //   each a split-slider pair (lo0,lo1,hi0,hi1)
  effects: Vec<Effect>,          // in Photoshop's fixed render order
}
Effect = DropShadow{color, opacity, blend, angle, use_global_light, distance, spread, size}
       | InnerShadow{…same…}
       | OuterGlow{color|gradient, opacity, blend, spread, size}
       | InnerGlow{…, source: Edge|Center}
       | Stroke{size, position: Outside|Inside|Center, color|gradient, opacity, blend}
       | ColorOverlay{color, opacity, blend}
       | GradientOverlay{gradient, angle, scale, style, opacity, blend}
       | BevelEmboss{style, depth, direction, size, soften, angle, altitude, highlight, shadow}
       | Satin{color, blend, opacity, angle, distance, size}
RzDocument.global_light: (angle, altitude)
```

**Rendering.** Every effect is a function of the layer's *shape* — its
alpha times its enabled mask — and reuses primitives the core already has:

- Drop shadow / outer glow: dilate the shape by `spread` (the Euclidean
  distance transform behind Grow Selection), Gaussian-blur by `size` (the
  existing blur kernel), offset by `(distance, angle)`, colorize, and
  composite *below* the layer with the effect's own blend mode and
  opacity.
- Inner shadow / inner glow: the same on the inverted shape, clipped to
  the shape, composited *above* the pixels.
- Stroke: a band of the signed distance field, filled with a color or
  gradient. Outside strokes composite below the layer like a shadow,
  inside strokes above it.
- Color / gradient overlay: a fill clipped to the shape, above the
  pixels, at its own blend mode (this is how everyone recolors text).
- Bevel & Emboss: a normal from the gradient of the blurred shape, lit
  from `(angle, altitude)`, split into a highlight pass and a shadow pass.
- Blend If: a per-pixel weight from the source (or backdrop) channel value
  through the two split ramps, multiplied into source alpha before
  blending. Lands in `composite_layer_into` as a few lines. It is the
  photographer's tool for "this warm adjustment only in the highlights".
- Fill opacity: scales the pixels' alpha but not the effects'. A text
  layer at 0% fill with a stroke and drop shadow is outlined text — a
  five-minute test case that exercises the whole design.

Render order, as Photoshop fixes it: drop shadow, outer glow (below);
the pixels at fill opacity; then above them overlays, satin, inner glow,
inner shadow, bevel; strokes at their position. Effects render into the
clipping group's projection when the layer is a clip base, so a shadow
under a clipped texture falls once.

**Performance.** The blur and distance transform run at composite time,
so cache the rendered effect planes per layer keyed on
`(Arc::as_ptr(pixels), Arc::as_ptr(mask), style hash)` — the pure model
makes that key exact. During a live brush stroke on a styled layer,
composite the stroke overlay without re-running the effects; the commit
re-renders once. Effects scale with Free Transform (Photoshop's "Scale
Effects"): multiply distance/size/spread by the mean scale on commit.

**Surfaces.** Layer > Layer Style… opens one sheet with an effect checklist
down the left and a pane per effect, live-previewed through the normal
projection; Copy / Paste / Clear Layer Style; an "fx" badge with a
disclosure that lists effect rows (each with its own eye) under the layer
in the panel; `.rz` bump (shared with §2.3 — one bump); `set_layer_style`
(whole style, idempotent) and `get_document` reporting it over MCP; PSD
import of the `lfx2` block is a stretch goal, PSD export rasterizes the
effects into the layer with a note in the layer name. Size: **L** — the
largest single item in this document, and the one with the most visible
payoff.

### 2.2 Symbolic transforms on parametric layers — SHIPPED (§0)

Give every `meta` payload a `transform: [a, b, c, d, tx, ty]` (an affine
in layer space; a homography can come later). Free Transform on a text,
shape, or Live Photo layer stops prompting to rasterize: the session's
final matrix composes into the payload and the layer **re-renders through
the transform** — CoreText glyph outlines and shape paths drawn under the
CTM, so a rotated headline has crisp vector edges and can be rotated back
losslessly. Move stays an offset change. Document-level rotate and flip
compose into the same field, which closes the README's "re-edits land
upright" limit for text and for Live Photo re-frames alike. The on-canvas
text editor can stay axis-aligned in a first cut (edit in an unrotated
overlay, commit re-renders rotated); a rotated editor is polish.

Size: **M**. Payload version 2 (older builds read those layers as plain
rasters, per the graceful-degradation rule), no `.rz` bump. Same-day
follow-ons on the text payload, each **S**: weight and italic traits,
tracking, leading, underline, fixed-width paragraph boxes vs point text.
Outline and shadow come from layer styles rather than from the text
payload, exactly as in Photoshop.

### 2.3 Channels: alpha channels and per-channel colour — SHIPPED (§0)

The selection mask is already a canvas-sized u8 plane, and the GIMP study
(§6) is explicit that selection, mask, and channel should be one
representation. So:

**Model.** `RzDocument.channels: Vec<Channel { name, data: Arc<GrayImage>
(canvas-sized), overlay_color, overlay_opacity }>`. Save Selection writes
one; Load Selection reads one (with the add / subtract / intersect algebra
that exists); delete, duplicate, invert, rename. Quick Mask becomes a
temporary channel rather than its own buffer. `.rz` bump shared with §2.1.

**Panel.** A Channels tab beside Layers: RGB, Red, Green, Blue (extracted
from the composite), then the active layer's Transparency and Mask, then
the alpha channels. Viewing a single channel shows it in grayscale;
viewing an alpha channel over RGB draws it as a rubylith — the Quick Mask
overlay code, unchanged. ⌘-click any channel row **or any layer
thumbnail** loads it as a selection (Shift/Option/Shift+Option combine),
which is how Photoshop users have selected "this layer's pixels" for
thirty years and which the app cannot do today.

**Editing a single channel.** The paint `target` grows from `layer|mask`
to `layer|mask|red|green|blue|alpha|channel:<name>`: the stroke overlay's
luminance replaces that plane within its coverage. Filters and
adjustments on a single channel (blur the blue channel to kill chroma
noise, Curves already has per-channel) extract the plane, run the op,
re-insert.

**Channel arithmetic.** Apply Image and Calculations are one function —
`plane = blend(a, b, mode, opacity)` over two gray planes with the
existing blend table — and yield the photographer's luminosity masks
(Lights / Darks / Midtones and their intersections) for free.

**The distinctive part.** iPhone HEICs carry auxiliary images that ImageIO
exposes in one call each: the depth map, the portrait effects matte, and
the semantic mattes for skin, hair, teeth, glasses and sky. Open a portrait
and those arrive as named alpha channels. "Blur the background using the
depth map", "select the hair" and "warm the skin" become a ⌘-click plus an
adjustment layer. No desktop editor does this for iPhone photos without a
plugin; the Swift-side ImageIO decode path for HEIC is where it plugs in.

Size: **M** for the model, panel, and load/save; **S** each for
single-channel painting, Apply Image, and auxiliary mattes. MCP:
`save_selection`, `load_selection {from: channel|layer_alpha|layer_mask,
mode}`, `list_channels`, `target` on the paint tools, `render {channel}`.

---

## 3. The catalog

### 3A. Photo correctness — colour management, metadata, RAW

| Feature | Size | Notes |
|---|---|---|
| Read the embedded ICC profile and convert to the document space on open — SHIPPED | M | `image` exposes decoder ICC bytes; convert with a pure-Rust CMS (`qcms` or `moxcms`). Document space is sRGB by default with an option to keep Display P3. GIMP §7: keep *assign* and *convert* as separate commands. |
| Tag the canvas with the document profile — SHIPPED | S | Hand the display a CGImage in the document's `CGColorSpace` and the window server does the monitor transform. Correct on-screen colour on a P3 MacBook display for one line of Swift. |
| Embed the profile on export — SHIPPED | S | PNG, JPEG, TIFF, WebP encoders take profile bytes. |
| Preserve EXIF / XMP / IPTC on export, orientation reset to 1 — SHIPPED | M | Keep the raw metadata blobs from open and re-splice after encoding (the `img-parts` crate does this for JPEG/PNG/WebP). Export panel gets a "strip metadata" toggle. |
| Image resolution (ppi) and print size in Image Size; File > Print — SHIPPED | S/M | `RzDocument` gains a ppi pair; the `.rz` bump carries it. |
| Camera RAW (CR3, NEF, ARW, DNG, ProRAW) via Core Image's `CIRAWFilter` | M | Swift-side decode, like HEIC today. A small "Develop" sheet before the pixels land — exposure, temperature/tint, noise reduction, lens correction — is the whole reason to own a RAW workflow. Highest photo value per day in this table. |
| HEIC export; AVIF and JPEG XL open/export | S/M | `image` has AVIF behind a feature flag; JXL via `jxl-oxide`. HEIC export through ImageIO on the Swift side. |
| Histogram panel with per-channel view and clipping warning — SHIPPED | S | Levels and Curves want it too. A parallel scan with merged bins (GIMP §8). |
| Info panel: cursor position, RGB/HSB/Lab readout, selection bounds — SHIPPED | S | Table over values the eyedropper already samples. |
| A per-document **linear-light compositing** toggle | M | Photoshop's "Blend RGB colors using gamma 1.0". Decode 8-bit sRGB to linear f32 on ingest (a 256-entry LUT), encode on output; storage stays 8-bit sRGB. Soft brushes and gradients stop turning muddy in the middle. Not the GIMP §3 three-axis system — one flag — and honestly optional. |
| 16-bit / half-float pixels | XL | Every op assumes `RgbaImage<u8>`. Defer; the f32 adjustment chain covers the banding case that matters most. |

### 3B. Adjustments — every row is one `Adjustment` variant — SHIPPED (§0), except Match Color / Equalize

Each lands at once as an adjustment layer, a destructive Filters twin,
and an MCP op; each is **S** unless marked.

- **Exposure** (exposure, offset, gamma) — the RAW-style trio.
- **Vibrance** — saturation weighted toward unsaturated pixels, skin-safe.
- **Hue / Saturation** with per-range targeting — six hue bands each with
  hue, saturation, lightness, plus Colorize. The workhorse; **M**.
- **Color Balance** — shadows / midtones / highlights, preserve luminosity.
- **Black & White** — per-hue weights and a tint; the Grayscale op is the
  degenerate case.
- **Photo Filter** — warming/cooling, density, preserve luminosity.
- **Channel Mixer** — a 3×4 matrix with a monochrome mode.
- **Selective Color** — per-primary CMYK nudges; **M**.
- **Shadows / Highlights** — a local-contrast op (large-radius blur as
  the tone estimate); **M**.
- **White balance / Temperature-Tint** — Bradford-adapted, on any layer.
- **Gradient Map** — luma through a gradient; needs the multi-stop
  gradient editor from §3E.
- **Color Lookup (LUT)** — `.cube` parser plus trilinear interpolation.
  Film emulation packs become drag-and-drop presets.
- **Auto Tone / Auto Contrast / Auto Color** — the Levels op with
  histogram-derived parameters; menu items, not layers.
- **Match Color / Equalize** — later.

### 3C. Retouching

| Feature | Size | Mechanism |
|---|---|---|
| Healing brush and Spot Healing | L | Clone the source's *texture* while keeping the destination's illumination: Poisson-blend the difference field over the dab footprint (GIMP §9). Spot Healing picks the source automatically from a ring around the dab. The clone stamp's overlay path supplies everything but the solve. |
| Patch tool | M | Healing brush over a lasso'd region moved by a drag. |
| Content-Aware Fill | L | PatchMatch inpainting over the selection, sampled from a ring around it. The follow-on `next-features.md` already named; "remove the person" becomes one assistant call after `select_subject`. |
| Red-eye | S | Vision face landmarks locate the eyes; desaturate red within the pupil radius. |
| Smudge, Blur, Sharpen, Sponge brushes | M | Per-dab ops through the dodge/burn core-op path; smudge keeps a running accumulation buffer (GIMP §9). |
| Frequency separation helper | S | A menu command that builds the two-layer setup (blurred low, High Pass linear-light high) most retouchers set up by hand. |
| Liquify | L | Brush strokes accumulate into a displacement field; the layer is looked up through it at commit (GIMP §10's warp note). Forward warp, pucker, bloat, push, reconstruct. |

### 3D. Selection

- **Freehand lasso** (drag) and **magnetic lasso** (Dijkstra over an
  edge-cost map, GIMP §6) — the polygon lasso is the only lasso today. S / M.
- **Quick Selection brush** — region growing under a dab with edge
  awareness. M.
- **Color Range** — fuzziness around a sampled colour, or the
  highlights / midtones / shadows presets; produces a soft mask. S.
- **Refine Edge** — a guided filter on the coverage mask against the
  composite, with radius, smooth, feather, shift-edge and decontaminate.
  Turns Select Subject's mask into hair. M.
- **Transform Selection** — the Free Transform session on the mask alone
  (already deferred in Phase 4). M.
- **Select Subject: people instances** — `VNGeneratePersonInstanceMaskRequest`
  for up to four separated people. S.
- **Stroke Selection… / Fill Selection…** with the multi-stop gradient and
  pattern fills. S.
- **Reselect (⇧⌘D)**, **Load/Save Selection** (§2.3), **Select > Grow by
  colour** (the wand's global mode over the current selection). S.

### 3E. Paint and fill

- **Multi-stop gradient editor** with colour and opacity stops, plus the
  angle, reflected and diamond styles the options-bar comment already
  plans; **gradient presets**. M.
- **Pattern fill** (bucket, fill dialog, Pattern Overlay effect) from a
  pattern library and Define Pattern from Selection. M.
- **Custom brush tips** from a selection, scattering, dual brush,
  texture, colour dynamics; **Pencil** (aliased) and **Background Eraser**
  / **Magic Eraser** (the wand as an eraser). S each.
- **Colour swatches panel**, recent colours, HSB and Lab in the picker,
  `X` to swap and `D` to reset foreground/background, ⌥⌫ / ⌘⌫ fill with
  foreground/background. S.

### 3F. Layer structure and workflow

| Feature | Size | Notes |
|---|---|---|
| **Layer groups** with opacity, blend mode, mask, and pass-through | L | The compositor recurses: a group renders its children into a private projection and composites once (GIMP §4). The stack becomes a tree; `.rz`, the panel, MCP `get_document`, and PSD import all follow. Photoshop's Knockout and clipping to a group ride on it. |
| Lock: transparency, pixels, position, all | S | A flags field on `Layer`; the paint path honours transparency lock by multiplying stroke coverage by existing alpha. |
| Multi-select layers; transform, move, delete, group, merge them together | M | Free Transform over a set of layers is the same matrix applied per layer. |
| Link layers; Align and Distribute | S | |
| Layer Via Copy (⌘J) / Via Cut (⇧⌘J); Merge Visible; Stamp Visible (⇧⌥⌘E); Bring/Send arrange shortcuts | S | |
| Auto-Select with the Move tool (click a layer's pixels to activate it) | S | Hit-test alpha from the top down. |
| Layer colour labels, filter-by-kind, search | S | |
| Linked image layers | M | `{type:"image", path}` in `meta` — the Live Photo layer's mechanism generalized: place a file, keep it re-renderable at any transform, Replace Contents. Most of what people use Smart Objects for, without the subsystem. |
| Layer comps / snapshots | S | Named document handles; the pure model makes a snapshot one pointer. |
| History panel | S | A table over the undo stack that exists; raise `levelsOfUndo` from 24 with a byte budget and a step floor (GIMP §12). |

### 3G. Filters (and non-destructive filters)

New ops, **S** each unless marked: Unsharp Mask and Smart Sharpen (the
sharpen everyone actually uses; the current Sharpen has no radius),
High Pass, Motion Blur, Radial / Zoom Blur, Box and Lens Blur (M),
Surface / Bilateral Blur, Median and Reduce Noise (M), Vignette, Lens
Correction and Chromatic Aberration (M), Film Grain, Clouds / Render,
Offset, Dust & Scratches.

**Filter layers.** The adjustment-layer mechanism already applies an op
to the accumulated backdrop, so a *blur* or *sharpen* adjustment layer is
the same code path with an area op instead of a point op. With a mask it
is non-destructive selective blur — background blur under a subject
selection — without the live filter graph the earlier roadmaps rightly
deferred (GIMP §5). Cost is that the adjustment renders per composite;
cache it as §2.1 caches effects. **M** for the mechanism, then each
filter opts in.

### 3H. Geometry

- **Arbitrary canvas rotation** (Image > Rotate… by angle), and
  **auto-straighten** from `VNDetectHorizonRequest`. S.
- **Perspective Crop** — the crop box's corners become a quad; commit
  runs the existing homography. S.
- **Skew / Distort / Perspective / Warp** as named Free Transform
  submodes; the first three are the current ⌘-corner drag with
  constraints, warp is a 4×4 Bézier mesh resampled through the
  displacement-field machinery Liquify needs. S / L.
- **Content-Aware Scale** — seam carving with a protect mask. M.
- **Trim** (to transparent or to a corner colour) and **Reveal All**
  (canvas to the union of layer bounds). S.
- **Guides, rulers, grid, and snapping** — every tool's drag snaps to
  guides, canvas edges, layer bounds and selection bounds; Smart Guides
  when moving. M, and the single most-missed piece of chrome.

### 3I. Files, export and sharing

- **PSD export** with layers, masks, blend modes (a 1:1 table), opacity,
  clipping, groups; text and shapes rasterized with their payload kept in
  a private XMP block so a re-import restores them. L, and the feature
  that lets a Rasterize document go to a collaborator on Photoshop.
- **Export for Web** — resize, format, quality, and *file size* preview
  side by side, with a metadata toggle; **Quick Export as PNG**. M.
- **Export Layers to Files**, contact sheet, **batch export** of a folder
  through an action (§3J). S once actions exist.
- **PDF and SVG import** (rasterize at a chosen size), PDF export. S.
- **Drag a layer out** of the canvas as a PNG; the macOS Share menu. S.
- **Multi-frame GIF and multi-page TIFF** as layers rather than first
  frame only; animated export from layers as frames. M.
- **Autosave and version browsing** on `.rz` via `NSDocument`'s standard
  machinery, which the app already sits on. S.

### 3J. Automation — the distinctive one

The MCP catalog is already a complete scripting surface, and the
assistant already drives it. **Actions** are recorded tool-call sequences:
turn on Record, work normally, and every UI edit that has an MCP twin
(all of them, by the parity rule in `app/CLAUDE.md`) is appended as a
call; stop, name it, replay it on the current document or on a folder
(File > Batch…). Parameters that reference the current document —
selection, active layer, canvas size — are captured symbolically. The
assistant can author an action from a sentence and the user can edit it
as JSON. **M**, and unlike every other item here it compounds with each
new tool that ships.

Two smaller ones in the same spirit: **Filters > Repeat Last (⌃F)** and
a **command palette** (⌘K-style fuzzy search over the whole menu).

---

## 4. Suggested order

1. ✅ **Layer styles and blending options** (§2.1) — the request, the most
   visible payoff, and it forces the effect cache that §3G reuses.
2. ✅ **Symbolic transforms** on text, shape and Live Photo layers (§2.2),
   with the text typography follow-ons — small, and it deletes a known
   limit.
3. ✅ **Channels** (§2.3) with ⌘-click-to-select, luminosity masks, and the
   iPhone auxiliary mattes — one `.rz` bump shared with step 1.
4. ✅ **Colour management and metadata** (§3A, first five rows) — silent
   correctness. Do it before more people export photos from the app.
5. ✅ **The adjustment batch** (§3B) plus the histogram and info panels —
   two weeks of S items that make the Adjustments menu look like a photo
   editor's.
6. ✅ **Healing brush and Content-Aware Fill** (§3C) — the retouching gap.
7. ▶ **Groups, lock, multi-select** (§3F) and **guides / rulers / snapping**
   (§3H) — the workflow layer that 20-layer documents demand.
8. **RAW develop** (§3A) and **Actions** (§3J) — the two features that
   would make this app a reason to leave Photoshop rather than a
   replacement for it.

Everything after that is breadth, and breadth here is one variant at a
time.

## 5. Cross-cutting

- **One `.rz` bump** carries layer styles, channels, ppi, groups when they
  land, and the linear-light flag — reserve the fields now even where
  nothing writes them, exactly as the earlier roadmap did for `meta`.
- **Per-layer render caches** (effects, filter layers) are keyed on `Arc`
  pointer identity plus a parameter hash; the pure model makes that
  exact, and it is the only reason composite-time effects stay fast on a
  100 MP canvas.
- **Every item ships three surfaces** — UI, MCP tool with a catalog entry
  naming the UI path it mirrors, and `.rz` where state persists — plus
  core tests and README, per the standard recipe in `CLAUDE.md`.
- **Still deferred, and still rightly:** 16-bit storage, a tiled render
  graph, a Bézier path subsystem, CMYK, and full three-axis blend and
  composite spaces. The linear-light toggle in §3A is the one deliberate,
  bounded step toward the last of those.
