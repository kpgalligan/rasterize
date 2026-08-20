# Handoff: Rasterize UI redesign — tool rail + fixed options bar

## Overview

Rasterize's chrome grew feature-by-feature and the toolbar is now the bottleneck. This handoff replaces the horizontal pill toolbar with a **left icon rail** (grouped tools behind dropdowns) and a **fixed-height options bar** that never resizes the canvas viewport, plus an overflow popover so option sets can keep growing.

Three problems this solves, in the user's words:

1. The top tool pill takes significant horizontal space and its rounded corners read badly.
2. Tool options currently expand the header, so the canvas viewport changes size as you switch tools.
3. Tools are being added continuously and grouping has been applied inconsistently.

Target codebase: `kpgalligan/rasterize` @ `main` — AppKit (not SwiftUI) in `app/Sources/`, Rust core in `core/src/`.

## About the design files

The files in this bundle are **design references created in HTML** — prototypes of intended look and behavior, not production code to port. The task is to **recreate them in the existing AppKit codebase**, using its established patterns: `NSView` subclasses that draw themselves, `DS` tokens from `app/Sources/Theme.swift`, tool actions dispatched up the responder chain with `NSApp.sendAction(_:to:from:)`, and `EditorTool` as the single source of tool identity.

Specifically: do **not** introduce SwiftUI, do **not** hardcode the hex values in this document as literal `NSColor`s. Section *Design tokens* maps every mock color to the semantic AppKit color the app already uses, so the redesign works in both light and dark appearance as `Theme.swift` intends.

## Fidelity

- `Rasterize Editor.dc.html` — **high fidelity**. Final layout, metrics, type, and interaction model. Match measurements and hierarchy exactly; take colors from the token mapping rather than the hex values.
- `Rasterize Layout Wireframes.dc.html` — **low fidelity**, three competing layouts. Included for context only. Option **1a** was chosen and is the one built in the hi-fi file. 1b and 1c are rejected; do not implement them.

The mock uses **Material Symbols Outlined** as a stand-in icon font because SF Symbols are not available in a browser. Ship **SF Symbols** — the app already resolves them, with a `fallbackGlyph` per tool.

---

## Screens / views

There is one screen: the document editor window. It has four regions plus two transient popovers.

```
┌───────────────────────────────────────────────────────────────┐
│ title bar                                        30pt  (OS)   │
├───────────────────────────────────────────────────────────────┤
│ options bar — FIXED HEIGHT, ALWAYS PRESENT       36pt         │
├────┬─────────────────────────────────────────┬────────────────┤
│    │                                         │                │
│rail│  canvas well (flexible)                 │  panel  300pt  │
│48pt│                                         │                │
│    │                                         │                │
├────┴─────────────────────────────────────────┴────────────────┤
│ status bar                                       26pt         │
└───────────────────────────────────────────────────────────────┘
```

Window in the mock is 1440 × 880 content. Minimum usable width ≈ 1040pt (rail 48 + panel 300 + canvas 640 + borders); below that, collapse the panel first, never the rail or the options bar.

### 1. Tool rail (replaces `ToolPillControl`)

- **Width** 48pt, full height between options bar and status bar, `chromeBackground` fill, 1pt trailing border.
- **Slots** 34 × 34pt, 5pt corner radius, 3pt vertical gap, 8pt top/bottom padding, horizontally centered.
- **Icon** SF Symbol, 19pt point size, weight `.regular`/`.medium`. Icon only — **no labels** (the current `shortLabel` truncation problem disappears; keep `shortLabel` in the enum only if the Tools menu still uses it).
- **Idle** icon tint `textMuted`, no fill, no border. **Hover** fill `hoverFill`, tint `textStrong`. **Selected** fill `selectionFill`, 1pt border `accent` at ~60% alpha, tint `accent`.
- **Grouped slot** (more than one member) draws a small solid triangle in the bottom-right corner: 5pt legs, `textMuted`, inset 1pt, with a **10 × 10pt hit zone**. Clicking the icon selects the group's current member; clicking the triangle opens the group menu. This is the behavior `ToolPillControl` already implements — preserve `currentMember` per group so a group returns to the tool last used in it.
- **Tooltip** on hover: `"\(displayName) (\(keyCharacter.uppercased()))"`, standard `NSView.toolTip`.
- **Foreground / background swatches** at the bottom of the rail: two 28 × 28pt rounded (4pt) squares, offset so the background swatch sits 14pt down and 10pt right of the foreground one, 1pt `borderStrong` border. Click to open the color picker; a small reset/swap affordance is a follow-on, not required for v1.
- **Group dividers** are optional; the mock omits them and relies on the chevrons for grouping legibility.

#### Rail order and grouping

Ten slots. Group index is the rail position; every `EditorTool` appears exactly once (keep the existing assertion in the rail view).

| # | Group | Members (in menu order) | Key | SF Symbol | Status |
|---|---|---|---|---|---|
| 1 | Select | Rectangle Select, Ellipse Select, Lasso, Magic Wand, Subject Select | M, O, L, W, S | `highlight.rectangle` / `circle.dashed` / `lasso` / `wand.and.stars` / `person.and.background.dotted` | ships today |
| 2 | Crop | Crop | C | `crop` | **new tool case** — crop exists only as a selection-based menu command today |
| 3 | Move | Move | V | `arrow.up.and.down.and.arrow.left.and.right` | ships today |
| 4 | Paint | Brush, Eraser, Clone Stamp, Dodge / Burn | B, E, J, D | `paintbrush.pointed` / `eraser` / `stamp` / `circle.righthalf.filled` | Brush + Eraser ship; Clone and Dodge are **new** |
| 5 | Fill | Fill | K | `drop.fill` | ships today |
| 6 | Gradient | Gradient | G | `circle.lefthalf.filled` | ships today |
| 7 | Shape | Rectangle, Ellipse, Line | R (cycles) | `rectangle` / `circle` / `line.diagonal` | **new** — needs shape layers (`meta` parametric layers) in core |
| 8 | Text | Text | T | `textformat` | ships today |
| 9 | Sample | Eyedropper | I | `eyedropper` | ships today |
| 10 | View | Zoom, Hand | Z, H | `magnifyingglass` / `hand.raised` | **new** as tools (zoom exists only as toolbar buttons / menu today) |

Notes on the new cases:

- Verify each SF Symbol resolves on the deployment target (macOS 15). `Tools.swift` already has a `fallbackGlyph` path — give every new case a distinct letter (C, J, D, R, and for the view group Z / H).
- Menu items for tools whose core support isn't landed yet should be **disabled with a "Soon" affordance** (the mock renders a dashed `SOON` tag), not hidden. Standard AppKit validation via `validateUserInterfaceItem(_:)` handles the disabling; the tag is a custom menu-item view or an appended `NSAttributedString` suffix.
- The shape group cycles on repeated presses of `R`, following the same pattern as Photoshop and the same `currentMember` state the rail already keeps.

#### Group dropdown menu

`NSMenu.popUp(positioning:at:in:)` anchored to the slot's trailing edge, offset (52, slot top). Mock geometry: min width 206pt, 7pt radius, 5pt padding, 28pt rows, 16pt symbol, 12pt label, trailing 11pt mono key equivalent. Keep the existing trick from `ToolPillControl.showGroupMenu`: key equivalents carry an **empty modifier mask** so a transient menu cannot steal a keystroke from text editing.

### 2. Options bar (the core change)

- **Height 36pt, fixed, never hidden.** A tool with no options still shows the bar with just its identity block. Nothing in this bar may change the height of the canvas well; remove the `scrollTopToOptions` / `optionsBar.isHidden` toggling in `EditorViewController` that currently resizes the viewport.
- Fill `chromeBackground`, 1pt bottom border, 10pt horizontal padding, `overflow` clipped, 12pt gap between option clusters.
- **Identity block** at the left, min width 132pt: 17pt SF Symbol tinted `accent`, 7pt gap, tool `displayName` at 12pt semibold. Then a 1pt × 18pt `border` divider. This block is a fixed anchor — it never moves as tools change, which is what makes the switching read as calm.
- **Controls**: uniform 22pt height, 3pt radius, 1pt `border`, `controlBackgroundColor` fill, 7pt inner padding.
  - Numeric / text field: mono 11pt value, units included in the display (`24 px`, `0.0°`, `100%`).
  - Popup: mono 11pt value + 13pt `chevron.up.chevron.down` in `textMuted`, 8pt gap.
  - Micro-label preceding a field: mono 10pt uppercase, `textFaint`-to-`textMuted`, 6pt gap (use `DS.microLabel`).
  - Checkbox: 13 × 13pt, 3pt radius; checked = `selectionFill` fill + `accent` border + accent checkmark; label 11pt sans `textMuted`.
  - Segmented control: 26 × 22pt cells, shared borders, outer 3pt radius on end cells only; selected cell = `selectionFill` + `accent` border, 14pt symbol.
  - Color swatch: 22 × 22pt, 3pt radius, 1pt `borderStrong`.
- **`More` button** pinned to the trailing edge: 24pt tall, 4pt radius, 1pt border, label "More" 11pt + `ellipsis` 14pt. Always present.
- **Overflow rule.** Each tool declares its options as an **ordered priority list**. On layout (and on live window resize), lay out clusters left to right while they fit before the `More` button; the first cluster that doesn't fit and everything after it moves into the `More` popover. Never wrap, never scroll, never grow the bar. Because the list is ordered, growth is automatic: new options append to the tail and land in the popover until the window is wide enough to promote them.
- **Overflow popover**: `NSPopover` anchored to the `More` button, 268pt wide, 10pt padding, a mono 10pt uppercase section title, then label/value rows (12pt sans label left, 22pt control right, 9pt gaps). It contains real controls, not a menu.

#### Per-tool options — primary row, then overflow

Ordered by priority; the split shown is what a 1440pt window produces in the mock.

| Tool | Primary row (in order) | Overflow |
|---|---|---|
| Select group (all five) | mode segmented (New / Add / Subtract / Intersect) · Feather `0 px` · Anti-alias ☑ | Grow / Shrink · Border width · Smooth · Quick Mask · Save selection |
| Magic Wand (adds) | Tolerance `32` · Contiguous ☑ · Sample popup (Current layer / All layers) | as above |
| Crop | Ratio popup (Original) · W / H fields · Straighten `0.0°` · Delete cropped pixels ☐ | Grid overlay (Thirds) · Content-aware fill · Snap to guides |
| Move | Auto-select popup (Layer / Group) · Show transform controls ☑ · six align buttons | Distribute · Snap to layers · Nudge step |
| Brush / Eraser / Clone / Dodge | Preset popup (Soft Round, with a stamp preview) · Size `24 px` · Hardness `0%` · Opacity `100%` · Flow `100%` · Blend popup (Normal) | Spacing · Angle · Roundness · Smoothing · Pressure size · Airbrush |
| Fill | Contents popup (Foreground, with swatch) · Tolerance `32` · Contiguous ☑ · Opacity `100%` · Blend popup | Sample all layers · Anti-alias · Pattern |
| Gradient | Gradient preview popup · type segmented (Linear / Radial / Angle / Reflected / Diamond) · Opacity `100%` · Reverse ☐ · Dither ☑ | Stops · Midpoint · Method (Perceptual) · Transparency |
| Shape | Fill swatch · Stroke swatch + Weight `2 px` · Radius `8 px` · Path-op popup (New layer) | Corner style · Dash pattern · Align stroke |
| Text | Font popup · Weight popup · Size `48 pt` · Tracking `0` · align segmented (L / C / R) · color swatch | Leading · Baseline shift · Paragraph · Anti-alias · Warp |
| Eyedropper | Sample popup (Point / 3×3 / 5×5) · From popup (Current / All layers) · Show sampling ring ☑ · picked swatch + hex | Sample size · Copy on pick · Recent swatches |
| Zoom / Hand | Fit / 100% / Fill buttons · Zoom `66%` · Scrubby zoom ☐ | Rulers · Guides · Pixel grid |

Every option in the *overflow* column is a **new control** — the app ships Tolerance, Contiguous, and brush Size today. Add them behind the same model regardless of whether the core op supports them yet; gate with validation rather than by omitting them.

### 3. Canvas well

Unchanged behavior: `CenteringClipView`, `underPageBackgroundColor` void, checkerboard for transparency, 1pt document edge plus a soft drop shadow. The mock renders the document at 820 × 614 inside the well as a stand-in.

The **zoom pill** stays where it is (bottom-left, 16pt inset, 30pt tall, 15pt radius, `hudWindow` blur, mono 11pt percentage between two 22pt round steppers) — `ZoomPillView` needs no change.

### 4. Right panel

300pt wide (mock) — `DS.panelWidth` is 304pt today; either is fine, pick one and use the token.

- **Tabs** 32pt tall, two equal halves, 1pt divider between and 1pt bottom border. Active tab: slightly raised fill (`chromeBackground` one step lighter) + 2pt `accent` bottom rule + semibold label; inactive: 12pt regular, `textMuted`. Replace the current rounded-pill tabs — square tabs, consistent with the rest of the chrome.
- **Layers tab**: blend-mode popup (24pt, full width) and an opacity row (mono 10pt uppercase label · 3pt track with 11pt knob · mono 11pt value, min 32pt right-aligned), separated from the list by a 1pt border. Layer rows 44pt tall, 5pt radius, 3pt gap, 8pt padding: 15pt eye symbol · 30pt thumbnail (3pt radius, 1pt border) · name 12pt over a mono 10pt subtitle carrying the layer's *kind* (`adjustment`, `text`, `2016 × 1512`). Selected row = `selectionFill` + `accent` border. Footer 36pt: add / adjustment / duplicate / delete icon buttons (26 × 24pt, 4pt radius, hover fill), then a right-aligned mono 10pt `3 layers`.
  - The subtitle intentionally replaced the current `Normal · 100%` line — blend mode and opacity are already shown above for the selected layer, and repeating them per row is the duplication this redesign removes.
- **Assistant tab**: message thread, 12pt padding, 12pt gaps. User messages right-aligned, max 230pt, accent-tinted bubble, radius 10/10/3/10. Assistant messages left-aligned, max 246pt, `controlBackgroundColor` + 1pt border, radius 10/10/10/3, 12pt/1.45 text. Under a reply, the tool calls it made are listed as mono 10pt rows with a leading checkmark, in a muted green. Composer: 1pt top border, 10pt padding, ≥56pt input, then a row with a mono 10pt tool-count hint on the left and a 24pt accent Send button on the right.

### 5. Status bar

26pt, `chromeBackground`, 1pt top border, 12pt padding, mono 10pt `textMuted`, 16pt gaps. Segments, left to right: `2016 × 1512 px` · `RGB · 8-bit` · `Selection: none` (or `Selection: 812 × 604 px`), then flexible space, then the active tool and its key: `Brush · B`.

**Deliberately dropped** from the status bar: layer name, blend mode, layer opacity, and the zoom percentage — all four are visible in the Layers panel or the zoom pill. `StatusSegment` stays as-is; only the set of segments changes.

---

## Interactions & behavior

- **Tool selection** — rail slot click, group-menu item, bare key (`M`, `O`, `L`, `W`, `S`, `V`, `B`, `E`, `J`, `D`, `K`, `G`, `R`, `T`, `I`, `Z`, `H`), or the Tools menu. All four paths dispatch the same selector up the responder chain, as they do today. Repeating a group's key cycles its members.
- **Options swap is instant** — no animation, no crossfade. The bar's height is constant, so there is nothing to animate; a transition here would only draw attention to a non-event. Hover and selection state changes use `DS.hoverDuration` (0.14s) and `DS.stateDuration` (0.22s) respectively, and respect `DS.reduceMotion`.
- **Chevron vs icon** — the 10 × 10pt chevron zone takes the click before the slot does, exactly as `ToolPillControl.zone(at:)` resolves it now.
- **Popovers close** on outside click, `Escape`, tool change, and window deactivation. Only one of {group menu, overflow popover} can be open.
- **Live resize** — recompute the overflow split on `viewDidLayout`; the canvas viewport size must not depend on it.
- **Option edits apply immediately** to the active tool and persist per tool across documents and launches (`UserDefaults`), so returning to a tool restores the settings the user works with — matching the group-memory behavior already in the rail.

## State management

```
activeTool: EditorTool                      // exists
groupMembers: [Int: EditorTool]             // exists as ToolPillControl.currentMember — promote it
                                            // to the editor/state layer so the menus, keys and
                                            // rail agree on cycling
toolOptions: [EditorTool: ToolOptions]      // NEW — per-tool option values, persisted
overflowStartIndex: Int                     // NEW — derived from bar width each layout pass
panelTab: .layers | .assistant              // exists
openPopover: none | .group(Int) | .overflow // NEW
```

`ToolOptions` should be a value type per tool family (`SelectOptions`, `PaintOptions`, `FillOptions`, `GradientOptions`, `ShapeOptions`, `TextOptions`, `SampleOptions`, `ViewOptions`) with `Codable` conformance for persistence. The options bar builds itself from a declarative descriptor list — `[(id, label, control kind, binding, priority)]` — rather than the current hand-wired `NSStackView` of pre-built controls with `isHidden` juggling. That descriptor list is what makes the overflow rule and future option growth mechanical instead of manual.

## Design tokens

Colors are given as the mock's dark-mode hex **and** the semantic AppKit color to actually use. `Theme.swift` already declares most of them; ship the semantic side.

| Role | Mock (dark) | Use in code |
|---|---|---|
| Title bar | `#2C2C2C` | OS-drawn |
| Bars (options, rail, status) | `#262626` | `DS.chromeBackground` |
| Panel | `#242424` | `DS.chromeBackground` |
| Canvas void | `#171717` | `DS.canvasVoid` |
| Border | `#3A3A3A` | `DS.border` |
| Border, strong | `#55554F` | `DS.borderStrong` |
| Control fill | `#2B2B2B` | `.controlBackgroundColor` |
| Hover fill | `#333333` | `DS.hoverFill` |
| Text, strong | `#E6E6E4` | `DS.textStrong` |
| Text, secondary | `#B9B9B3` | `DS.textMuted` |
| Micro-label | `#8F8F8A` | `DS.textFaint` |
| Text, faint | `#6E6E68` | `DS.textFaint` |
| Selected fill | `rgba(10,132,255,0.26)` | `DS.selectionFill` |
| Selected border / accent rule | `#4A7FD0` / `#62B0FF` | `DS.accent` |
| Accent icon / label | `#8CC6FF` | `DS.accent` |

**Type** — as `Theme.swift` defines: Source Sans 3 for UI, IBM Plex Mono for machine-produced numbers and micro-labels.

| Use | Spec |
|---|---|
| Tool name (options bar) | sans 12pt semibold |
| Control label | sans 11pt regular |
| Panel tab | sans 12pt semibold / regular |
| Layer name | sans 12pt |
| Numeric value | mono 11pt |
| Micro-label | mono 10pt uppercase, 0.09em tracking (`DS.microLabel`) |
| Status bar | mono 10pt |

**Metrics** — add to `DS`, and delete `toolbarHeight` (58) with the pill:

```
railWidth        48    optionsBarHeight  36    statusBarHeight  26  (was 30)
railSlot         34    controlHeight     22    panelWidth      300
railSlotRadius    5    controlRadius      3    tabHeight        32
layerRow         44    popoverWidth     268    menuMinWidth    206
```

**Spacing scale** 3 / 6 / 8 / 10 / 12 / 16pt. **Radii** 3 (controls) / 4 (buttons) / 5 (rail slots, layer rows) / 7 (popovers) / 15 (zoom pill). Shadows: popovers `0 12 34 rgba(0,0,0,0.5)`; document edge `0 8 30 rgba(0,0,0,0.5)` + 1pt hairline. The sticker/offset-block shadow used by the old pill is retired.

## Assets

- `assets/canvas.png` — a brightened crop of the user's own screenshot, used in the mock as the document and as the Background layer thumbnail. **Placeholder only**; no need to carry it into the app.
- Icons: SF Symbols per the rail table. The Material Symbols font in the HTML is a browser stand-in only.
- Fonts: already vendored in `app/Resources/Fonts` (Source Sans 3, IBM Plex Mono, Darker Grotesque).

## Suggested implementation order

1. **`Tools.swift`** — add cases `crop`, `clone`, `dodge`, `shapeRect`, `shapeEllipse`, `shapeLine`, `zoom`, `hand`; give each `displayName`, `symbol`, `fallbackGlyph`, `keyCharacter`, `cursor`, `action`. Rewrite `toolbarGroups` to the ten groups above (rename it `railGroups`). Add a `planned: Bool` (or an availability check) for tools whose core support isn't landed.
2. **`ToolRailView.swift`** — new vertical view, lifted from `ToolPillControl`: keep the zone hit-testing, `currentMember` memory, and menu construction; drop the pill path, the sticker shadow, the labels, and the horizontal geometry.
3. **`ToolOptionsBar.swift`** — new: descriptor-driven, fixed height, priority-ordered overflow, `More` popover. Retire the ad-hoc option controls in `EditorViewController` (`toleranceSlider`, `contiguousCheck`, `sizeSlider`, `sizeField`, and the `updateOptionsBar()` visibility juggling).
4. **`EditorViewController.swift`** — recompose the layout: rail leading, options bar pinned under the title bar spanning full width, canvas well constrained to constants (delete `scrollTopToOptions`), status bar with the reduced segment set.
5. **`Theme.swift`** — metrics above; remove `toolbarHeight`.
6. **`LayersPanelViewController.swift`** — square tabs, layer-row subtitle change, footer row.
7. New tools' behavior last, one at a time, each with core support: crop → clone/dodge → shapes → zoom/hand. `designs/next-features.md` has the core-side plan for shape layers (parametric `meta` layers) and the retouch brushes.

Steps 1–6 are pure UI and can land before any new tool does real work; the rail and options bar should ship with the new tools present but validated-off.

## Files in this bundle

| File | What it is |
|---|---|
| `Rasterize Editor.dc.html` | Hi-fi interactive mock of the chosen layout. Click rail tools, open group dropdowns, switch panel tabs, open the `More` popover. |
| `Rasterize Layout Wireframes.dc.html` | The three low-fi layout options; **1a** is the one chosen. |
| `support.js` | Runtime the two HTML files need. Keep alongside them. |
| `assets/canvas.png` | Placeholder document image. |

Open either HTML file directly in a browser.
