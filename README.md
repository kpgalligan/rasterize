# Rasterize

A native macOS raster image editor. Swift/AppKit UI with a Rust core for image
decoding, encoding, and manipulation.

## Features

- **Layers**: full layer stack with per-layer opacity, visibility, offsets,
  and the full 27-mode Photoshop blend set — the separable W3C modes plus
  Dissolve, Vivid/Linear/Pin Light, Hard Mix, Divide, Darker/Lighter Color,
  and the non-separable Hue/Saturation/Color/Luminosity — grouped in the
  panel exactly like Photoshop's menu;
  layers panel with thumbnails, inline rename, drag-reorder, a right-click
  row menu (Rename, Select Frame… on a Live Photo layer, Layer Style… with
  Copy / Paste / Clear Layer Style, Delete Layer), and
  new/delete/duplicate/merge-down/flatten; Move tool (V) with arrow-key
  nudges; Paste as New Layer; PSD files import with their real layers; the
  native `.rz` format saves the full layer stack — masks, clipping flags,
  layer styles, the global light, alpha channels, and text and adjustment
  descriptions included — losslessly, and older `.rz` files still load
- **Layer masks**: a grayscale coverage mask per layer that hides pixels
  without erasing them — Layer > Mask adds one revealing all, hiding all, or
  built from the current selection, then enables/disables it (a disabled mask
  is kept but ignored, to compare with and without), applies it (bakes the
  coverage into the layer's alpha) or deletes it (the layer comes back
  whole); a masked layer grows a second thumbnail beside its own in the
  layers panel — click either to aim the brush and eraser, which paint the
  mask white to reveal and black to hide. A mask is the layer's size and
  moves, rotates, crops and scales with it
- **Channels** (View > Channels, ⌃⌘C): a third tab of the right panel beside
  Layers and Assistant, listing RGB, the composite's Red, Green and Blue
  planes, the active layer's mask while it has one, and every **alpha
  channel** the document carries — named canvas-sized coverage planes that
  are saved selections, never part of the picture. Each row draws its own
  grayscale thumbnail and carries an eye: RGB shows the colour image, a
  single colour plane's eye shows that plane in grayscale, and a channel's
  eye washes it over the picture as a rubylith in its own colour, opacity
  and polarity (Color Indicates: Masked Areas by default — the same side
  Quick Mask washes). Selecting a row *is* the edit target: with Red
  selected the brush, eraser, fill, gradient and every destructive
  Filters/Adjustments item run on that one 8-bit plane of the active layer
  (previewing in grayscale and committing what they previewed), leaving the
  other planes byte-identical; with an alpha channel selected they paint the
  channel — white selects, black deselects — as one undo step each. Rows
  rename by double-click, and a right-click menu (mirrored under Image >
  Channels) duplicates, deletes, inverts, opens Channel Options… for the
  name and rubylith, or loads the channel as a selection. Selections move
  both ways: Select > Save Selection… writes one into a new or existing
  channel, Select > Load Selection… reads a channel, a layer's transparency,
  a layer's mask or a colour plane back out, and **⌘-clicking** a layer
  thumbnail, a mask thumbnail or a channel row does it in one gesture
  (Shift adds, Option subtracts, Shift+Option intersects — the selection
  tools' own convention). Image > Apply Image… blends one source onto the
  current target — onto the layer the three planes blend as one colour, so
  the whole mode set applies; onto a single plane or a channel the four HSL
  modes (Hue, Saturation, Color, Luminosity), which need an RGB triple to
  mean anything, are left out, as they are in Image > Calculations…, whose
  result is always one plane. Calculations blends two source planes into a
  new channel or a selection, and Select >
  Add Luminosity Masks appends the photographer's nine tone masks
  ("Lights 1".."Midtones 3") built from the composite's Rec. 709 luma.
  Opening an iPhone photo (HEIC or a "Most Compatible" JPEG) brings its
  **auxiliary mattes** in as channels — Depth, Portrait Matte, Skin, Hair,
  Teeth, Glasses, Sky — resampled to the canvas and ready to load as a
  selection; a file carrying none adds none, and a Live Photo takes the Live
  Photo path instead and contributes none. Channels ride along with every
  canvas-geometry op (crop crops them, Canvas Size pads them, rotate/flip
  permute them, Image Size resamples them — a growth that would push the
  channel list past what `.rz` can store is refused there, with an alert
  naming how many channels that canvas holds, rather than at save time) and
  are saved in `.rz`
- **Adjustment layers**: non-destructive color adjustments that live in the
  layer stack and recolor everything below them at composite time, their
  parameters editable forever. Layer > New Adjustment Layer offers
  twenty-one ops — Brightness/Contrast/Saturation, Levels, Curves (an
  interactive spline editor: click the curve to add up to 16 control points
  per channel, drag to move them, with a channel popup switching between the
  master RGB curve and Red/Green/Blue individually), Exposure (in linear
  light, with Photoshop's gamma convention, where above 1 darkens), Vibrance
  (weighted toward the least saturated pixels and half-strength on skin
  hues), Hue/Saturation (master plus six editable hue bands, and Colorize),
  Color Balance (shadows/midtones/highlights, holding Rec. 709 luma),
  Black & White (six hue weights and an optional tint), Photo Filter (the
  standard warming and cooling filters, or any colour, at a chosen density),
  Channel Mixer (a 3×4 matrix with a monochrome mode), Selective Color (nine
  ranges of CMYK nudges, relative or absolute), Shadows/Highlights (whose
  tone estimate is an alpha-weighted large-radius blur of the luma, so local
  contrast survives and a cut-out gets no halo), White Balance (temperature
  and tint, Bradford-adapted to D65), Gradient Map (luma through a multi-stop
  gradient you edit in place — drag a stop, click the ramp to add one, ⌫ to
  remove — with dithering that stops an 8-bit map banding a smooth sky),
  Color Lookup (a .cube LUT, 1D or 3D, parsed in the core and applied with
  trilinear interpolation at a chosen strength; a table larger than this
  build stores is resampled down and says what size it came from), Hue
  Rotate, Posterize, Threshold, Invert, Grayscale, and Sepia. The
  parameterized ops open live-preview dialogs and re-open any time via
  Layer > Adjustment Options… or a double-click on the layer's row in the
  panel (which badges adjustment layers "◐"). Every adjustment layer is
  created with a layer mask gating where the adjustment applies — built from
  the selection when one exists, else revealing all — and brush and eraser
  strokes on the layer paint that mask automatically. Because it is just a
  layer, opacity, blend mode and clipping all apply; the twelve newer ops'
  destructive Image > Adjustments twin runs the identical core op and lands
  on the identical bytes, so the only difference is reversibility. Three
  stated exceptions: Shadows/Highlights is the only op that reads a
  neighbourhood, so the layer reads the backdrop below it and the filter
  reads its own layer — the two agree on the same pixels and are
  deliberately different pictures on different ones; Gradient Map's dither
  is keyed on the pixel's position, and the layer counts that from the
  canvas while the filter counts it from the layer it was handed, so on a
  layer whose offset is not (0, 0) the same jitter falls on different pixels
  (turn `dither` off and they agree exactly at any offset); and the nine
  older adjustments keep the single-purpose filters that predate the shared
  twin, which do their arithmetic in 0-255 rather than 0-1 and so can land
  one step away on a value falling exactly between two codes
- **Clipping masks** (Layer > Create Clipping Mask, ⌥⌘G): confine a layer
  to the alpha footprint of the first unclipped layer beneath it —
  Photoshop group semantics, so the base's blend mode and opacity apply to
  the group as one unit, consecutive clipped layers all ride the same base,
  hiding the base hides its group, and reordering simply re-derives the
  groups. The layers panel indents a clipped layer behind a "↳" arrow;
  releasing (the same menu item, retitled) undoes it, pixels untouched
  either way
- **Layer styles** (Layer > Layer Style ▸): Photoshop's effect stack per
  layer — Drop Shadow, Inner Shadow, Outer Glow, Inner Glow, Stroke (outside
  / inside / center, color or gradient), Color Overlay, Gradient Overlay,
  Bevel & Emboss and Satin, each with its own blend mode and opacity, plus
  Blending Options (fill opacity, which scales the pixels but not the
  effects, and Blend If's split-slider ramps on this layer and the
  underlying composite) — rendered from the layer's shape (alpha × mask) at
  composite time, so they follow every move, mask edit and re-rendered
  text, live-previewed in one sheet with a checklist down the left and a
  pane per effect, copied/pasted/cleared from the same menu, badged "fx" in
  the layers panel (double-click a plain raster layer's row to open the
  sheet), scaled with Free Transform and Image Size, baked by Merge Down and
  Flatten, and saved losslessly in `.rz` (format version 6; older files
  still load). A document-level global light (angle, altitude) drives every
  effect with Use Global Light on. The Free Transform preview shows the
  layer without its effects until commit
- Open PNG, JPEG, Photoshop (PSD, layered), TIFF, BMP, GIF, WebP, HEIC/HEIF,
  and Apple Live Photos — EXIF orientation is applied on open, so camera
  photos display upright
- Export a copy to PNG, JPEG (with quality control), TIFF, BMP, GIF, WebP;
  failed saves never truncate or delete an existing destination file
- **Colour management**: a file's embedded ICC profile is read on open and
  the document is converted into the colour working space (Image > Mode >
  Working Space — sRGB by default, or Display P3; it affects future opens
  only). A file with no profile is assumed sRGB, which is what every reader
  does — so with the working space set to Display P3 an untagged file is
  converted too, and opening one and saving it straight back will not
  reproduce the input bytes; under the default sRGB working space that never
  happens. The canvas, the layer and channel thumbnails and every preview are
  tagged with the document's own profile, so a Display P3 photo finally
  looks right on a wide-gamut display. **Assign Profile…** relabels the
  document — the pixel numbers do not change, so the picture changes
  appearance, unless the new profile describes the space the document was
  already in — while **Convert to Profile…** transforms every layer's pixels
  so each layer keeps its appearance; both live under Image > Mode. The
  profile is embedded on export (PNG, JPEG, TIFF and WebP can carry one), and
  the EXIF / XMP / IPTC packets a JPEG or PNG arrived with are re-spliced into
  JPEG, and EXIF and XMP into PNG (a PNG has nowhere to put an 8BIM run), in
  both cases with the orientation reset to 1 — the camera rotation is
  already baked into the pixels, so a preserved 6 would double-rotate it in
  every viewer. The reset covers **both** copies a file carries: the EXIF tag
  and the XMP packet's `tiff:Orientation`, which XMP's own reconciliation
  rules make the authority for Bridge and Camera Raw. The resolution is
  written into both as well, and an EXIF block that cannot be brought to the
  document's is dropped — and reported dropped — rather than left
  contradicting the density beside it. A file that states its resolution twice is read from its EXIF
  tags, which the Exif specification makes the authority and which is what
  ImageIO and ImageMagick answer for the same file, with the container's own
  density (a JFIF header, a PNG `pHYs`) as the fallback. A non-sRGB export
  also gets EXIF's ColorSpace tag set to "Uncalibrated", the value that means
  "read the embedded profile" — a camera's "sRGB" left beside a Display P3
  profile is how a wide-gamut export comes out oversaturated elsewhere. The Export panel's **Embed colour
  profile** (on) and **Strip metadata** (off) checkboxes govern both, and a
  format that cannot carry something says so rather than dropping it
  silently — unless nothing is actually lost, as when an sRGB document is
  written to a format with no profile slot and every reader assumes sRGB
  anyway. **Image resolution** in pixels per inch travels with the
  document (Image Size's Resolution field, with Resample off changing only
  the print size, never a pixel), and **File > Print** (⌘P) prints the
  flattened composite at that resolution, fitted to the page; **Page
  Setup…** is ⇧⌘P. The colour management is Rasterize's own: ICC v2/v4 RGB
  matrix/TRC profiles are parsed and transformed by the core, and the two
  built-ins it writes (sRGB IEC61966-2.1 and Display P3) are real ICC blobs
  any other application reads
- Smooth zoom (pinch, ⌘+/⌘-, fit, actual size) and pan — plus a Zoom tool
  (Z: click steps in, ⌥-click out, drag a marquee to fill the window with
  it, or turn on scrubby zoom and drag left/right) and a Hand tool (H) that
  drags the view
- Rotate 90°/180°, flip horizontal/vertical
- **Free Transform** (Layer > Free Transform, ⌘T): rotate, scale and move the
  active layer in one session — drag the eight handles to scale (Shift keeps
  the proportions, Option grows about the pivot), drag just outside a corner to
  rotate (Shift snaps to 15°), drag inside to move, arrow keys nudge; Return or
  a double-click commits, Escape cancels. The options bar shows editable
  Angle / Scale X / Scale Y and W / H — the layer's own scaled pixel size,
  bound to the matrix both ways, so typing a width sets the scale (keeping
  a mirrored layer mirrored) — plus the resampling filter
  (nearest, bilinear, bicubic by default, or Lanczos). The drag is a live
  preview and the whole session commits as **one undo step** — the layer is
  resampled exactly once, in premultiplied alpha so rotated edges stay clean
  instead of fringing dark. A layer mask transforms with its layer, and whole-
  pixel moves and mirrors copy pixels losslessly. **⌘-drag a corner** to pull
  that corner alone — distort/perspective: the box becomes an arbitrary convex
  quad (drags that would fold it simply stop), the live preview warps with it,
  and the commit resamples through a true projective homography, mask riding
  along; rotating, scaling and moving carry a warped box rigidly, and a box
  whose corners are pulled back to a parallelogram commits as the exact affine
  it is, lossless fast paths included. Text, shape and Live Photo layers no
  longer rasterize for an affine transform: the session's matrix composes
  into the layer's description and the layer re-renders through it — glyphs
  and paths drawn under the matrix, so a rotated headline keeps crisp vector
  edges and rotating it back is lossless — with its mask and layer style
  riding along. Only the ⌘-corner perspective drag still asks to rasterize,
  and so does a layer whose source cannot be re-rendered right now — a text
  layer whose font is not installed on this machine (re-rendering it would
  substitute a face) or a Live Photo whose still or clip has been moved,
  deleted or damaged — since resampling the real pixels is the honest
  outcome there. Selections are not transformable yet —
  a session always transforms the whole layer and hides the marquee while it
  runs
- **Crop** (Image > Crop, ⌘K): the canvas shrinks to the selection's
  bounds and layers keep their pixels outside it, ready to be revealed
  again. Available only while the selection covers less than the whole
  image — anything else would be a no-op
- Image Size (scale with filter choice, up to 100 MP),
  and Canvas Size with the Photoshop-style 3×3 anchor selector — grow or
  trim the canvas without scaling; layers keep their pixels and can be
  revealed again later
- Image > Adjustments: the destructive twins of every adjustment layer
  above except Curves, which stays layer-only, with live in-context preview
  on the active layer — and Auto Tone,
  Auto Contrast (⇧⌘L, ⌥⇧⌘L) and Auto Color (⇧⌘B), which derive Levels
  parameters from the image's own histogram (clipping 0.1 % at each end,
  Photoshop's default) and apply them through that same levels math
- Filters: Gaussian blur, sharpen, Pixelate, Add Noise, Edge Detect, Emboss
- An **Info panel** (⌃⌘I) with the document's histogram — per-channel or
  luminosity, with a clipping wedge at each end — over a readout that
  follows the cursor and freezes with its last value when the cursor leaves:
  position, RGB, HSB, Lab (computed through the DOCUMENT's own profile
  against the D50 white, so the same bytes read differently in an sRGB and a
  Display P3 document), the selection's bounds and area, and the document's
  size, resolution and profile. The same plot is drawn behind the Levels and
  Curves controls — showing, for an adjustment layer, the backdrop below it
  rather than the already-corrected composite
- Selections beyond the rectangle: ellipse marquee (O), polygonal lasso
  (L — click vertices, double-click/Return/click-the-start closes, Escape
  cancels), and a magic wand (W) with tolerance + contiguous options that
  samples the flattened composite; Select > Select Subject hands the
  composite to macOS's Vision segmentation — the model behind Preview's
  Copy Subject — and turns the people, animals or objects it finds into a
  selection with no seed point, no tolerance and a genuinely soft edge,
  while the Subject tool (S) does it one subject at a time: press and the
  subject under the pointer is outlined, drag between subjects to change
  which, release to select it;
  combine selections with Shift (add),
  Option (subtract), or Shift+Option (intersect), invert (⇧⌘I), soften
  them with Select > Feather Selection…, reshape them with Grow, Shrink,
  Border, and Smooth Selection… — true Euclidean-distance morphology at
  the selection's 50% contour, so a moved edge comes back freshly
  anti-aliased instead of jagged — or paint them directly in Quick Mask
  mode (Q — the selection becomes a red rubylith overlay the brush adds
  to and the eraser removes from; toggling back out converts the buffer
  into the selection, and an empty one deselects), and the marching ants
  trace the true selection contour — disjoint pieces and holes each get their own
  dashed loop; selections confine brush, eraser, fill, and gradient, dim
  the outside, and define Crop. Delete (Edit > Clear, ⌫) clears the
  selected region of the active layer to transparency in one undo step,
  and does it proportionally where coverage is partial — a feathered
  selection leaves a soft-edged hole, not a hard one (text layers ask to
  rasterize first, as any destructive edit does)
- **Crop tool** (C): an interactive crop box over the whole canvas — drag
  the eight handles (aspect presets: Original, Free, 1:1, 4:3, 3:2, 16:9,
  plus editable W/H), move it from inside, draw a fresh one from outside,
  with a rule-of-thirds grid and a Straighten angle that live-rotates the
  image behind the fixed box; Return or a double-click commits (straighten
  rotates every layer about the box's center, then crops) as one undo
  step, Escape resets. Cropping only moves the canvas window — layer
  pixels outside it are kept and can be revealed again
- Fill tool (K): bucket flood fill on the active layer with tolerance,
  contiguous and opacity options, and a Gradient tool (G): drag to paint
  linear or radial gradients from the foreground to the background color
  (Reverse swaps them, Opacity fades both), both selection-aware
- **Clone Stamp** (J): ⌥-click sets the source, then strokes stamp the
  composite from that fixed offset through round dabs — the classic
  aligned clone, live-previewed through the projection like every stroke,
  `[`/`]` resize, selections confine it
- **Dodge / Burn** (D): brush-local tonal retouch — dodge brightens, burn
  darkens, banded to shadows / midtones / highlights with an exposure
  setting, applied by a Rust core op through the stroke's own coverage so
  soft edges fade the effect out
- **Shape layers** (R — repeated presses cycle Rectangle, Ellipse, Line):
  drag out a shape (Shift constrains squares, circles and 45° lines) and
  it lands as its own parametric layer — fill, stroke, weight and corner
  radius from the options bar, the description stored in the layer's meta
  like text, so Move keeps it honest and the `.rz` format round-trips it.
  Double-click a shape layer in the panel to reopen it: drag the eight
  handles or the interior to re-box it, restyle it from the options bar,
  Return (or a click away) re-renders it as one undo step, Escape cancels.
  A transformed shape reopens with its handles on the rotated box and
  re-boxes in its own space — a rotated rectangle grows along its own axes
- Eyedropper (I): picks the color under the cursor into the shared paint
  color, sampled from the flattened composite — what you actually see, not
  one layer — point, 3×3 or 5×5 mean sampling, a monospaced hex readout in
  the options bar and an optional copy-to-clipboard on pick; a drag keeps
  sampling, and Option-click borrows the eyedropper mid-tool from brush,
  fill, and gradient
- Brush and eraser with the full tip option set, shared with the clone
  stamp and dodge/burn (per-tool size, opacity/exposure, hardness, flow,
  spacing, angle, roundness, smoothing, pressure size and airbrush, plus
  built-in tip presets: hardness below 100% stamps soft airbrushed dabs;
  flow deposits per dab so a stroke builds up where it crosses itself,
  with opacity still capping the stroke once; spacing sets the dab
  rhythm — 150%+ reads as a dotted line; angle and roundness squash the
  tip into a calligraphy nib; smoothing steadies the hand with a
  pulled-string leash that catches up at mouse-up; pressure size tracks
  a tablet pen's pressure; airbrush keeps depositing while the pointer
  hovers; and the brush and clone stamp composite their paint through
  the full layer blend-mode set; shared color; `[`/`]` resize; 1 px
  pixel-snapped mode; fast drags render through a smoothing spline, so
  a flick lands as a curve instead of a chain of straight chords;
  strokes confine to an active selection)
  and on-canvas text (font/weight/size/color and left/center/right
  alignment, ⌘Return commits, Escape cancels) — tools switch via the left
  tool rail, Tools menu, or M/O/L/W/S/C/V/B/E/J/D/K/G/R/T/I/Z/H. Related
  tools share one rail slot: the five selection tools, the four paint
  tools (brush, eraser, clone, dodge), the three shapes, and zoom + hand,
  each slot showing whichever member is current with a corner triangle
  that drops a menu of the rest (with their keys). A group remembers the
  member last used
- **The redesigned chrome**: a 48pt icon rail down the left with the
  foreground/background swatches at its foot, and a fixed-height options
  bar under the title bar that never resizes the canvas — each tool
  declares its options in priority order and whatever doesn't fit at the
  current window width folds into a `More` popover instead of wrapping.
  Numeric fields carry a chevron menu of quick-pick presets (a 1–64 px
  spread for sizes, tens for percentages, doublings for radii) alongside
  typed entry. Options persist per tool across documents and launches
- **Re-editable text layers**: committing text adds its own layer that
  remembers the string, font, size, color, alignment and typography —
  weight, italic, tracking, leading, baseline shift, underline,
  strikethrough — it was rendered from, plus the width it wraps at:
  paragraph text remembers its box, point text (from the agent's
  `wrap_width: 0`) never wraps, and a layer saved before widths were
  stored is given one the first time something rewrites it, remembered
  from then on: the on-canvas editor re-wraps it from its origin to the
  right edge (at most 600 px) as it always did; a Free Transform, a
  document rotate/flip or Image Size recovers the width from the layer's
  own raster, so its existing line breaks are kept; and the agent's
  `edit_text_layer` keeps its canvas-edge default (no 600 px cap). Click
  it again with the text tool to reopen the editor pre-filled, with
  everything restored into the options bar, and the layers panel badges
  it with a "T". Double-clicking the layer's row in the panel reopens it
  the same way from anywhere: it switches to the text tool and selects
  the whole string, so typing replaces it. A transformed layer opens
  upright at its block's origin and the commit re-renders it through its
  transform. A destructive edit
  (filter, adjustment, fill, gradient, brush, eraser) asks "Rasterize text
  layer?" first and drops the description on confirm, keeping the pixels.
  The native `.rz` format stores the description alongside the pixels, so
  text stays editable across save and open (layers with default typography
  and no transform are written in the original version-1 form, so older
  builds still open them as text)
- **Live Photo layers**: open either half of an Apple Live Photo — the photo
  (`IMG_0001.HEIC`) or its clip (`IMG_0001.MOV`), which Photos exports as a
  pair sharing one name — and the layer shows the key frame, the
  full-resolution photo itself, while remembering the whole clip behind it.
  Layer > Place Live Photo… adds one to the document you already have.
  Right-click the layer's row (or double-click it, or Layer > Select Live
  Photo Frame…) for a timeline slider that scrubs the clip with a live
  preview on the canvas: pick any moment, and Apply re-renders the layer
  from that frame as one undo step, keeping its name, position, opacity,
  blend mode, mask, layer style and transform — a rotated or scaled Live
  Photo re-frames in place. Video frames are scaled to the photo's size so
  the layer's geometry never shifts, and a Key Frame button walks back to
  the full-resolution still. The layers panel badges these layers "▶". A
  destructive edit (filter, adjustment, fill, gradient, brush, eraser) asks
  before cutting the layer loose from its Live Photo, exactly as it does for
  text; the description is stored in `.rz` files, so the frame stays
  changeable across save and open as long as the original files are where
  they were
- **Copy** (⌘C) puts the active layer's own pixels within the selection on
  the clipboard — raw, so layer opacity, blend mode and the layer mask stay
  out of it and the copy round-trips through Paste as New Layer unchanged —
  while **Copy Merged** (⇧⌘C) takes the same region of the flattened
  composite, every visible layer with its opacity, blend modes, masks,
  clipping and adjustment layers applied. Both copy only the SELECTED pixels:
  the clipboard image spans the selection's bounds (the whole canvas with
  nothing selected), but anything inside those bounds and outside the shape
  comes out transparent, and a feathered or anti-aliased edge fades out
  proportionally — a lasso or Select Subject outline copies exactly what it
  encloses. Written as TIFF and PNG. **Cut** (⌘X) is Copy then Clear in one
  step: it needs a selection, puts the same pixels on the clipboard, and
  clears the selected region of the active layer to transparency as a single
  undo step
- Full undo/redo, recent files
- Drag image files onto a window to open them; File > New from Clipboard (⌘N)
- Checkerboard backdrop for transparency

Known limits: PSD support is 8-bit RGB/grayscale (16-bit and CMYK files are
rejected with a clear error), and PSD layer masks and clipping flags do not
import; animated GIFs and multi-page TIFFs
load their first frame/page only, so ⌘S on a GIF deliberately routes through
Save As instead of overwriting the animation in place. Document-level rotate,
flip and resize compose into every text, shape and Live Photo description,
so a re-edit after one lands in place; the Crop tool's straighten angle
still rasterizes them. A layer an earlier version's Image Size resampled
while its description kept its original size is left as it is by those
ops — the pixels turn with the document and the description follows, but
nothing re-renders it — and Free Transform asks to rasterize it as it does
for any raster; its next re-edit renders the description at its own size,
as it always did. A Live Photo's files are referenced by path, not
copied into the document: move or delete them and the layer keeps its
pixels but can no longer change frame. EXIF, XMP and IPTC are captured and
re-spliced for JPEG and PNG only — and IPTC for JPEG alone, since a PNG has
nowhere to put an 8BIM run — while TIFF carries the ICC profile alone, WebP
the profile and the EXIF packet, BMP and GIF carry neither, HEIC/HEIF
contributes its profile and dpi but no packets, and PSD contributes neither;
an export from a document opened from any of those says its capture data was
never read in rather than implying the file had none. A TIFF written here states
no print resolution — it carries the encoder's own 1/1 default, which some
applications read as 1 dpi — and the export notice says so.
Convert to Profile transforms
layer pixels only: layer masks and alpha channels are coverage rather than
colour and are left alone, and so are layer-style and text-layer colours —
those are authored in sRGB like every other colour you type, and they convert
into the document's space where they are used (a style's when it composites,
a text layer's when it re-renders), so an effect's colour matches a fill of
the same hex on any document and survives a convert unchanged. An adjustment
layer's parameters are left alone too, but for a different reason: a curve
point or a saturation amount is not a colour and there is nothing to convert
it into. That is also why a convert keeps each LAYER looking the same without
keeping every composite the same — a non-Normal blend mode, an adjustment
layer and a style effect that blends are all computed from the numbers the
convert changes, so on such a document the picture visibly moves (correctly,
and as it does in Photoshop). The sheet and `convert_profile` say which case
the document is in rather than promising it will look identical. LUT-based (A2B/B2A)
profiles are kept and re-embedded but cannot be converted from, and a
document tagged with one is painted in "the numbers are the numbers" mode:
every authored colour lands as the sRGB number you typed, from the brush, a
fill and a layer-style effect alike, so one hex is one colour throughout.
Display, relabelling and re-embedding stay exact. Gray, CMYK and Lab
profiles are refused outright, as are device-link, abstract and
named-colour profiles, which describe a transform rather than a space to
read pixels in. Missing EXIF resolution and
orientation tags are patched only where they already exist, never inserted
— inserting one would shift every out-of-line datum and corrupt a
MakerNote. When an EXIF resolution cannot be patched in place (both axes
sharing one stored value on a document whose two axes now differ, say), the
whole EXIF block is dropped and reported dropped rather than written
contradicting the density beside it: a packet is in authority for as long as
it exists — `sips` and ImageMagick answer with its numbers and ignore the
JFIF header even when its unit says "none" — so handing the density back its
authority means not writing the packet. In the
XMP packet only the `tiff:` orientation, resolution and resolution-unit
properties are rewritten, and only where the packet already carries them
under that conventional prefix. With the working space set to Display P3, an untagged file is
converted on open (it is assumed sRGB first), so opening and immediately
re-saving it does not reproduce the input bytes; under the default sRGB
working space that never happens.

## Built-in assistant

The Assistant tab of the right panel (View > Assistant, ⌃⌘A) is a chat
agent built into the app: it edits the window's document by calling the
same tools the MCP server exposes, sees the canvas by rendering it, and
verifies its own work. The agent loop lives in the Rust core
(`core/src/assistant.rs`): a tool-use loop over the Anthropic Messages
API (non-streaming v1; `api_base` is the provider seam), with per-turn
events driving the panel UI, cancellation at tool/API boundaries, and
automatic pruning of older canvas renders from the conversation so
history stays small. Every assistant edit is a normal undo step.

Bring your own API key: the panel asks once and stores it user-only
(0600) in `~/Library/Application Support/Rasterize/anthropic_api_key`;
launching with `ANTHROPIC_API_KEY` set also works, and wins. A key an
earlier build kept in the keychain migrates into that file on the next
launch — one final keychain prompt, then never again (keychain ACLs are
tied to the code signature, so every rebuild used to re-prompt). The
model defaults to `claude-sonnet-5`; override with
`defaults write com.kgalligan.Rasterize AssistantModel <model-id>`.

## AI agent access (MCP)

Tools > Allow Agent Connections hosts an MCP server (streamable HTTP) inside
the app at `http://127.0.0.1:4816/mcp` (`RZ_AGENT_PORT` overrides; falls back
to an ephemeral port). Any MCP client can drive the editor — 75 tools cover
opening documents, inspecting and rendering the canvas (the agent *sees* the
image as PNG — `render`'s `channel` shows ONE plane as a grayscale PNG
instead — and `sample_color` reads single pixels off the flattened
composite — the eyedropper; `sample_pixel` is its Info-panel twin, adding
HSB, Lab through the document's own profile, and the closest sRGB spelling
to paint it back with, and `histogram` counts the tones of the composite or
one layer), layer operations, blend modes, layer masks (add
revealing, hiding or from the selection; enable, apply, or delete), clipping
masks (`set_layer_clipped` confines a layer to the alpha of the first
unclipped layer below it; `get_document` reports the flag), layer styles
(`set_layer_style` replaces a layer's whole effect stack and blending
options — the same JSON `get_document` reports — and `set_global_light` the
shared light; `render` shows the effects), non-destructive
adjustment layers (`add_adjustment_layer` / `edit_adjustment_layer` over all
twenty-one ops with the same mask-on-creation rule as the UI's;
`get_document` reports each one's op and params, eliding only a Color
Lookup's table), filters — every adjustment op but `curves` also runs
destructively through `apply_filter`, and `auto_tone` / `auto_contrast` / `auto_color`
mirror the three menu commands — geometry —
including `transform_layer`, the Free Transform pipeline with named parameters
(rotate in degrees, positive is clockwise; scale, translate, pivot, sampler)
and `distort_layer`, its perspective twin (four explicit corner destinations,
the ⌘-corner drag as a tool), both reporting the layer's new bounds; on a
text, shape or Live Photo layer `transform_layer` — and a parallelogram
`distort_layer` — composes into the description instead of rasterizing,
and `rotate` / `flip` / `image_size` keep every description honest — brush
and eraser strokes (polyline points
with size/color/opacity and the full tip — hardness, flow, spacing, angle,
roundness, the same stamped pipeline as the options bar's tip, shared with
`clone_stamp` and `dodge_burn` — a `blend_mode` compositing brush and clone
paint through the layer blend-mode set, and a
`target` choosing the layer's pixels, its mask, one of its colour planes or
an alpha channel — `apply_filter`, `fill` and `gradient` take the same
`target` minus `mask`, filters and fills on a layer mask not being part of
this build), shape layers
(`add_shape_layer` / `edit_shape_layer`, the parametric rect / ellipse /
line layers the shape tools drag out and reopen, with an optional
`transform`), text — `add_text_layer` and `edit_text_layer` for re-editable
text layers with alignment, the typography (`weight`, `italic`, `tracking`,
`leading`, `baseline_shift`, `underline`, `strikethrough`), `wrap_width` (0
for point text) and `transform` parameters (`get_document` reports each
described layer's full description, its `transform` and its exact
`origin`) and `add_text` for the rasterizing variant —
Live Photos (`add_live_photo_layer` places one as a layer and
`set_live_photo_frame` re-renders it at another moment of its clip;
`get_document` reports each layer's clip, key frame and the moment it is
showing) —
selections (rect/ellipse/polygon/magic wand with add/subtract/intersect
modes, plus `select_subject` for Vision's subject segmentation — it goes
past the menu command in giving the agent the subjects individually, since
`instance` picks one of them and every result reports how many were found,
plus `modify_selection`'s invert, feather, grow, shrink, border, and
smooth — shared with the UI and
honored by every paint tool), `clear_selection` to clear the window's
current selection on a layer (partial coverage clears proportionally),
alpha channels (`list_channels`, `add_channel` from the selection, a layer's
transparency or mask, a colour plane or nothing at all, plus
`duplicate_channel` / `delete_channel` / `rename_channel` /
`set_channel_options` / `invert_channel`; `get_document` reports the list)
and the selections that
flow through them (`save_selection` into a new or existing channel,
`load_selection` back out — an all-zero source deselects rather than
erroring), channel arithmetic (`apply_image` and `calculations` over the
separable blend modes — the four HSL modes need an RGB triple, so only
`apply_image` onto a whole layer takes them — plus `add_luminosity_masks`
for the nine tone masks),
bucket fill and gradients (either on the layer or, through the same
`target`, straight into a colour plane or an alpha channel), colour
management and metadata (`get_color_profile` reports the document's profile,
whether Rasterize can convert with it, what the open did, and the print
size; `assign_profile` relabels and `convert_profile` transforms, each from
a built-in or an `.icc` file on disk; `set_resolution` changes the ppi
without resampling a pixel; `get_metadata` reports which EXIF/XMP/IPTC
packets the document carries and how big they are; `get_document` reports
all three, and `save_copy` takes `embed_profile` and `strip_metadata` and
names what the chosen format actually wrote),
undo/redo, and exporting. Agent edits run on the main thread through the same edit path
as the UI: each tool call is one undo step, marks the document edited, and
updates the open window live. With [goose](https://github.com/aaif-goose/goose):

```sh
goose session --with-streamable-http-extension "http://127.0.0.1:4816/mcp"
```

The protocol layer lives in the Rust core (`core/src/agent.rs`, tools-only,
stateless, single JSON responses); the Swift side registers the tool catalog
and executes calls against the live documents (`app/Sources/AgentServer.swift`).
The endpoint is unauthenticated and off by default — any local process can
connect while it is enabled.

## Design

The UI takes its structure from the Balopy design handoff in
`designs/design_handoff_rasterize_desktop` — sticker-shadow pill controls,
an IBM Plex Mono voice for machine numbers, the welcome window and overlap
motif — but the chrome uses the standard semantic system colors
(`windowBackgroundColor`, `labelColor`, the user's accent color, …) so it
stays neutral around the image and follows light/dark automatically. The
brand palette survives only in the app icon, the welcome motif, and the
coral selection marquee. Fonts (Source Sans 3, IBM Plex Mono, Darker
Grotesque — all OFL) are vendored in `app/Resources/Fonts` and registered
via `ATSApplicationFontsPath`. Launching with nothing open shows the
welcome window instead of a bare open panel.

## Layout

```
core/           Rust crate (staticlib) — all pixel work happens here
  include/      Hand-maintained C header: the FFI contract
app/
  Sources/      Swift AppKit application (programmatic UI, no storyboards)
  Bridging/     Bridging header importing the Rust FFI header
project.yml     xcodegen definition — source of truth for the Xcode project
Makefile        Build orchestration
```

## Building

Requires Xcode, Rust (cargo), and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
make app        # cargo build + xcodegen + xcodebuild → build/Build/Products/Release/Rasterize.app
make run        # build and launch
make test       # Rust core tests
make typecheck  # fast swiftc -typecheck of the app sources
```

`Rasterize.xcodeproj` is generated — run `xcodegen generate` (or `make project`)
after editing `project.yml`, and don't commit the project file.

## Architecture notes

- The FFI surface (`core/include/rasterize_core.h`) is an opaque `RzImage`
  handle holding non-premultiplied RGBA8. All operations are pure — they
  return a new image and never mutate the input — which makes undo/redo a
  simple stack of handles (bounded by `NSUndoManager.levelsOfUndo`).
- Swift wraps the handle in a `RasterImage` class whose `deinit` frees the
  Rust allocation; error strings cross the boundary as malloc'd C strings
  released with `rz_string_free`.
- PSD files are detected by their `8BPS` signature and decoded with the `psd`
  crate (layered import, falling back to the flattened composite when a
  file's layers cannot be decoded); everything else goes through the `image`
  crate.
