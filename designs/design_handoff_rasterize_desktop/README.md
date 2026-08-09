# Handoff: Rasterize desktop app — Balopy visual system

## Overview

Rasterize is the native macOS raster image editor at `github.com/kpgalligan/balopy-app` — a Swift/AppKit UI over a Rust core. The app is functionally complete and entirely unstyled: it uses stock AppKit chrome throughout.

This handoff covers a visual design for that app in the **Balopy design system** — warm paper surfaces, ink-black outlines, forest primary, coral reserved for the (not-yet-built) agent. It re-skins the existing structure rather than reorganising it: the menus, toolbar, layers panel, sheets and status bar all keep the shape they have in the Swift sources today.

Two screens are **proposals, not recreations**, and are marked as such throughout: the no-document window and the Settings window. Neither exists in the repo.

## About the design files

The files in this bundle are **design references written in HTML** — prototypes showing intended look and behaviour. They are not production code and nothing in them should be ported directly.

The implementation target is the existing **Swift / AppKit** app. The work is to reproduce these designs there using AppKit's own facilities: `NSVisualEffectView`, custom `NSView` drawing, `NSAppearance`, asset catalogue colours, `NSToolbar`, `NSTableView` row views, and view-controller-presented sheets. Where AppKit's stock control cannot reach the design (the sticker shadow, the pill toolbar segment), draw it — do not fight the control.

Two AppKit-specific notes that override anything in the HTML:

- The HTML draws its own traffic lights, title bar and menu bar so the design can be seen in a browser. In the app these are **system-owned** — the window title bar stays native (`window.title` / `window.subtitle` are already set in `EditorWindowController`), and the menu bar is the real `NSMenu` built in `AppDelegate`. Style only what AppKit lets you style.
- Colours must go in an **asset catalogue with Any/Dark appearances**, not hard-coded. The ink theme in the HTML is exactly the dark appearance.

## Fidelity

**High-fidelity.** Colours, type, spacing, radii and states below are final values, taken from the Balopy token files. Recreate them precisely. Layout metrics that already exist in the Swift sources (236px panel, 52px title bar, 27px status bar, 48px row height) are called out where the design changes them.

## Screens / views

All five live in one file, `Rasterize Desktop.dc.html`, behind the screen switcher at the top of the page. The switcher, the page background and the Paper/Ink control are **presentation scaffolding** — not part of the app.

### 1. Editing window

**Purpose.** The single document window. Everything the app does happens here.

**Layout.** Fixed window, rows `38px title bar / 58px toolbar / 1fr body / 30px status bar`. Body is a two-column grid: `1fr` canvas, `304px` panel.

> Repo delta: the panel is 236px today (`LayersPanelViewController.loadView`, and the `+237` in `EditorWindowController`'s initial content size). 304px is needed for the blend-mode row, the opacity row and the 34px thumbnails to sit at comfortable density. If you widen it, update the content-size arithmetic to `+305`.

**Title bar** — 38px, `--surface-card`, 1px `--border-subtle` bottom. Traffic lights left (system). Centred two-line stack: document name at 13px/600 `--text-strong`, subtitle at 10px IBM Plex Mono `--text-faint` reading `2048 × 1365 px`. Native; the subtitle is already wired up.

**Toolbar** — 58px, `--surface-card`, 1px `--border-subtle` bottom, 14px horizontal padding, 14px gap.

- *Tool group* (left). One pill-shaped container: 1.5px `--ink-0` border, `999px` radius, `overflow:hidden`, sticker shadow `2px 2px 0 var(--ink-0)`. Five segments, each 56px wide, 6px vertical padding, icon over label, 3px gap, separated by 1px `--border-subtle`. Icon 17px, label 10px. Selected segment: `--surface-brand-soft` background, `--text-brand` text, weight 600, **no border change**. Order and identity match `EditorWindowController`: Select, Move, Brush, Eraser, Text.
- *Zoom group*. Four borderless 52px buttons — Zoom Out, Zoom In, Fit, Actual — icon 17px over 10px label, 8px radius, hover `--surface-sunken`.
- *Crop* pinned right, same borderless treatment.
- Hidden entirely when no document is open.

**Canvas well** — `--canvas-void` `#0B120F`, 36px padding, content centred. The image sits on a 20px checkerboard built from `--canvas-checker-a` / `--canvas-checker-b`, with `0 18px 48px rgba(0,0,0,.5)` beneath it. The selection marquee is a 2px dashed `rgba(244,101,63,.9)` rectangle — **this is one of only two coral elements in the whole app**.

- *Zoom pill*, bottom-left, 16px inset: `rgba(11,18,15,.72)` + `blur(8px)`, `999px` radius, mono percentage plus two 24px round steppers. This and the site header are the only sanctioned uses of blur in the system.

**Right panel** — `--surface-card`, 1px `--border-subtle` left edge. Rows: `tabs / header / scrolling list / footer`.

- *Tabs*: Layers, Adjust, Ask. Pill tabs, 6px × 11px padding, 13px. Active tab gets `--paper-0` fill, 1.5px `--ink-0` border, `2px 2px 0` sticker shadow, weight 600. Inactive is transparent with no border.
- *Blend mode button*: full width, 7px radius (a field, not a pill — it opens something), 1.5px `--ink-0` border, 13px label left, `chevron-down` right. Opens the grouped popup below.
- *Opacity row*: 10px uppercase mono label at `0.09em`, range input with `accent-color: var(--coral-500)`, mono readout right-aligned in a 40px column.
- *Layer rows*: 8px radius, 6px × 8px padding, 9px gap. Eye button 22px, thumbnail 34px at 5px radius with a 1px `--border-subtle` frame, then a two-line stack — name at 13px, meta at 10px mono `--text-faint` reading `Soft Light · 62%`. Selected row: `--surface-brand-soft` fill, `--text-brand` name, weight 600. Hidden layer: thumbnail at 35% opacity, name in `--text-faint`, eye glyph swaps to `eye-off`.
- *Footer*: four 30 × 26px borderless icon buttons — new, delete, duplicate, merge down — then a mono layer count right-aligned. These already send the same nil-target actions as the Layer menu; keep that.

> Repo delta: row height is 48px today with a 40px thumbnail. The design uses 34px thumbnails and the two-line name/meta stack, which lands at roughly the same height. The meta line is new — it surfaces blend mode and opacity per row instead of only for the active layer.

**Status bar** — 30px, `--surface-card`, 1px `--border-subtle` top, 11px IBM Plex Mono `--text-faint`, 14px padding and gap. Segments are separated by a 1px `--border-subtle` left border with 14px padding, not by bullets. Left: dimensions, active layer, blend/opacity. Right: current tool, zoom. With no document: `No document open` … `Drop a file, or ⌘O`.

> Repo delta: 27px today. 30px lets the mono line breathe.

### 2. Menus + toolbar

**Purpose.** Specifies the menu bar. Titles, item order, separator placement and key equivalents are lifted verbatim from `AppDelegate.buildMainMenu()` and should not be changed by this design work.

The menu bar itself is system-drawn — the HTML strip exists only so the spec is legible. What is designable is the **dropdown**: `--surface-card`, 1.5px `--ink-0` border, 10px radius, `0 18px 44px rgba(16,25,21,.4)` shadow, 6px padding. Items are 5px × 12px, 6px radius, 13px label left, key equivalent right in 12px mono `--text-faint`. Highlight is `--forest-700` fill with `--paper-0` text — forest, not the system accent. Separators are 1px `--border-subtle` with 5px × 10px margins.

Menus, in order: File, Edit, Image, Layer, Filters, Tools, View, Window, Help.

### 3. Dialogs

Four sheets, all attached to the window's top edge: 420px wide, `--surface-card`, 1.5px `--ink-0` border, `0 0 14px 14px` radius, `0 24px 60px rgba(16,25,21,.45)` shadow, over a flat `rgba(16,25,21,.56)` scrim with **no blur**. Title 15px/700, hint 12px `--text-muted` at 1.45. Label column is 106px, right-aligned, 13px. Fields are 7px radius, 1px `--border-medium`, 13px mono. Buttons bottom-right: Cancel is paper, the primary is `--forest-700` with `--paper-0` text; both are pills with 1.5px ink border and the `2px 2px 0` sticker shadow. Bottom-left carries a 10px mono footnote (`max 100 MP`, `⌥⌘C`, `one undo step`).

- **Image Size** — current size, width, height, lock-aspect checkbox, filter popup (Nearest / Bilinear / Catmull-Rom / Lanczos3, default Lanczos3). Mirrors `ResizeSheetController`.
- **Canvas Size** — current size, width, height, and the 3 × 3 anchor grid. Cells are 32 × 28px, 4px radius, 1px `--border-medium`; the anchor cell is `--forest-700` filled with `●`, neighbours show arrows radiating outward, distant cells are blank. Mirrors `CanvasSizeSheetController.AnchorGridView` exactly, including the arrow glyphs.
- **Levels** — black / white / gamma. Represents the whole `SliderSheetController` family (Hue Rotate, Threshold, Posterize, Pixelate, Add Noise, Gaussian Blur, Adjust Colors) — one layout, different rows.
- **Export** — save-as name, destination, format popup, JPEG quality slider. Quality is disabled unless the format is JPEG.

> Repo delta: Export is drawn as a sheet. Today it is an `NSSavePanel` with `ExportAccessoryController` as its accessory view. Keep the save panel — apply the field and slider styling to the accessory view only, and treat this sheet as a spec for those controls rather than a replacement for the panel.

### 4. No document

**Purpose.** The window state when the app is frontmost with nothing open. `applicationShouldOpenUntitledFile` currently opens the file panel and returns false, so this window does not exist yet. **This is a proposal.**

Body is `--surface-sunken` with the content centred, max 520px. From the top: the overlap motif at 132 × 96px (three 68px circles at `mix-blend-mode: multiply`, the only decorative use of the motif in the app), a display headline in Darker Grotesque 900 at 42px/0.92/−0.03em, a 15px/1.5 paragraph in `--text-muted` capped at 44ch, then two buttons — `Open…` primary with `folder-open`, `New from Clipboard` secondary with `copy` — and an 11px mono format list.

In this state the panel is hidden entirely (the same result as View ▸ Hide Layers), the zoom and crop toolbar items are gone, and the tool group is at 42% opacity with pointer events off.

### 5. Settings

**Purpose.** A preferences window. **Proposal — none exists in the repo.** 660px window, native title bar, a pill tab row (General / Editing / Export), then label/value rows on a 190px right-aligned label column with a 12px `--text-faint` explanation under each value and a 1px `--border-subtle` rule between rows. The content is a starting inventory, not a settled feature list; every row maps to something already in the code (undo levels, resample filter, brush defaults, JPEG quality, the GIF Save-As routing).

## Interactions & behaviour

Implemented in the prototype:

- Tool selection updates the toolbar segment and the status bar. In the app this already round-trips through `EditorWindowController.reflectSelectedTool`.
- Layer row click sets the active layer (no undo, no dirty flag — matches `tableViewSelectionDidChange`). Eye button toggles visibility independently of selection.
- Opacity slider updates the readout and the active row's meta line live. Keep the existing live-edit contract: continuous ticks swap the document without undo, and the tick delivered with mouse-up commits the whole scrub as one undo step.
- Blend-mode button opens a 230px grouped popup, max height 440px, scrolling. All 27 modes in six groups with 1px separators, matching `RzBlendMode.blendModeGroups` — Normal/Dissolve, the Darken family, the Lighten family, the Overlay family, Difference family, and the non-separable Hue/Saturation/Color/Luminosity. Selected mode is `--forest-700` filled. A full-window transparent layer behind the popup dismisses it.
- Menu title click opens its dropdown anchored to that title's left edge.
- Zoom steppers move in 25% increments, clamped 12–800%; Fit and Actual jump to 46% and 100%.
- Sheets open over the window and dismiss on either button.

**Motion.** 140ms hover, 220ms state change, 380ms entrance, all on `cubic-bezier(.2,.7,.3,1)`. Sheet entry may use the spring easing. Nothing loops. Gate decorative motion on `prefers-reduced-motion` — in AppKit, `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.

**States.**
- Hover on a sticker control: lift 1px up-left, shadow grows to 4px. Ghost controls take `--surface-sunken` instead.
- Press: translate 3px down-right, shadow to zero. Ghost controls scale to 0.97.
- Focus: 2px coral outline at 2px offset, or a 3px coral ring on fields. Always visible.
- Disabled: 42% opacity, no shadow, no pointer events.
- Selected in the toolbar: forest tint fill, forest text, no border.

**Coral discipline.** Two coral elements in the entire app: the selection marquee and the reserved agent tab. Coral belongs to the agent; if it appears elsewhere the agent stops reading as special. Focus rings are the one systemic exception.

## State

Nothing here needs new application state — every value already exists in the document model. What the design adds is presentation:

- `activeLayerIndex`, layer `visible` / `opacity` / `blendMode` — already on `RasterDocument.LayerInfo`; the design just surfaces blend and opacity per row instead of only for the active layer.
- Current tool — already `EditorTool` on the view controller.
- Zoom — already on `ImageCanvasView`.
- Panel tab (Layers / Adjust / Ask) — **new**. One enum on the panel controller. The Adjust tab is a docked home for what are currently the Filters sheets; if you keep the sheets, the tab can be dropped without affecting anything else.
- Appearance — read from `NSApp.effectiveAppearance`; do not add an in-app theme switch.

## Design tokens

All values come from `_ds/balopy-design-system-.../tokens/`. Put them in an asset catalogue with Any/Dark appearance pairs.

**Paper** `--paper-0 #FBF8F1` · `--paper-1 #F4EFE4` · `--paper-2 #EAE3D4` · `--paper-3 #DCD3C0`. Pure white is never used.

**Ink** `--ink-0 #101915` · `#1B2721` · `#39493F` · `#61736A` · `#93A29A` · `#BFC9C2`. A green-black, not neutral.

**Forest** (primary) `--forest-700 #11533D` · `600 #186B51` · `500 #1F8564` · `100 #E7F3EC`.

**Coral** (agent only) `--coral-500 #F4653F` · `600 #D14D2B` · `300 #FFB49B` · `100 #FFEDE6`.

**Butter** `--butter-500 #F2C14E`. **Danger** `#B4301A`, deliberately deeper than coral.

**Canvas** `--canvas-void #0B120F` · checker `#E7E1D5` / `#F4EFE4`.

**Light appearance:** page `--paper-1`, card `--paper-0`, sunken `--paper-2`, subtle border `#DCD3C0`, medium border `#C4B9A2`, text `#1B2721`, muted `#61736A`, faint `#93A29A`.

**Dark appearance:** page `#101915`, card `#1B2721`, sunken `#0A120E`, subtle border `#2A3830`, medium border `#3B4B43`, text `#E4DDCE`, muted `#93A29A`, faint `#61736A`, brand `--forest-500`, accent `--coral-400`. The canvas well stays `--canvas-void` in both.

**Type.** Darker Grotesque 800/900 for display only, tracking −0.02 to −0.035em, line-height 0.92, never below 28px. Source Sans 3 for all UI: 15px secondary, 13px controls and body, 12px hints, 11px micro-labels at 0.09em uppercase. IBM Plex Mono for every machine-produced number — dimensions, percentages, zoom, key equivalents, file names. All three are Google Fonts and none ship as binaries; vendor `.woff2` files before shipping, or substitute the system faces and say so.

**Spacing.** 4px scale. Window insets 14px; panel padding 12–14px; sheet padding 20–22px.

**Radii.** `999px` every control — buttons, tabs, badges, segments. `18px` cards. `14px` window and sheet. `11px` media. `10px` popovers. `7px` fields and the blend button. `4–5px` checkboxes and thumbnails. A 7px rectangle means "type here"; a pill means "press me".

**Elevation.** Sticker shadow is the house style: `2px 2px 0 var(--ink-0)` on controls (3px on marketing), never blurred, always with a 1.5–2px ink border. Soft warm-tinted shadows only for dense product surfaces — popovers `0 18px 44px rgba(16,25,21,.4)`, sheets `0 24px 60px rgba(16,25,21,.45)`, canvas image `0 18px 48px rgba(0,0,0,.5)`.

## Copy

Sentence case everywhere — headlines, buttons, dialog titles, labels. No full stops on headlines, buttons or labels; full stops in body copy. No emoji, anywhere. Real numbers in mono. `×` for dimensions, `·` as a separator, `⌘`/`⇧`/`⌥` for shortcuts.

Exact strings used: `No document open`, `Drop a file, or ⌘O`, `Rasterize does not create blank canvases — every document starts from pixels you already have.`, `Live preview on «layer». Apply commits one undo step.`, `Grows or trims the canvas without scaling. Layers keep their pixels and can be revealed again later.`, `The original file is untouched. A failed save never truncates the destination.`

If the agent ever ships: it works first and reports after, and every step it took is its own undo. Never write "estimate", "approve", or "nothing runs until you say go".

## Assets

- **Icons.** Lucide, 2px stroke, from `unpkg.com/lucide-static`. A flagged substitution — no icon set came with the brief. The app currently uses SF Symbols, which is the right native choice; if you keep SF Symbols the design is unaffected, since both are geometric 2px-ish line sets. Glyphs used: `lasso`, `mouse-pointer-2`, `paintbrush`, `eraser`, `type`, `zoom-in`, `zoom-out`, `maximize`, `square`, `crop`, `eye`, `eye-off`, `plus`, `minus`, `copy`, `chevrons-down`, `chevron-down`, `folder-open`.
- **App icon.** Three directions in `Rasterize App Icon.dc.html`, all built from the Balopy overlap motif. The mark's geometry is taken from the design system's `assets/logo.svg` and `components/brand/Logo.jsx`: a 120 × 120 box with `rx=30`, paper ground, three `r=31` circles at `mix-blend-mode: multiply` — forest at (45, 48) upper left, butter at (75, 48) upper right, coral at (60, 76) hanging below centre. Corner radius is 26% of the side per `.blp-logo__mark`. `1a` is that mark in the squircle unchanged; `1b` quantises it to an 18 × 18 grid; `1c` is a Darker Grotesque `R` on ink with the three inks as a status row. **Not yet chosen.** Each is pure geometry, so whichever wins exports straight to SVG and the full `.icns` ladder (16 through 1024). The `1b` grid coarsens at small sizes — 18 cells at 48px and up, 12 at 32px, 8 at 16px.
- **Lockup.** Mark plus wordmark follows the `Logo` component's metrics: wordmark at 1.18× the mark's side, `0.5em` gap, Darker Grotesque 900 at −0.035em, `0.06em` bottom padding on the word. The balopy wordmark stays lowercase; Rasterize is capitalised because it is a proper app name.
- **Photography.** Every image in the prototypes is a labelled placeholder gradient. Replace before any external use.

## Files

- `Rasterize Desktop.dc.html` — all five screens, with the switcher at the top.
- `Rasterize App Icon.dc.html` — the three app-icon directions and the lockup.
- `github.md` — the repo association and a screen-to-source map.

Both HTML files load the Balopy design system from `_ds/balopy-design-system-70aa0e4a-f872-425d-aa58-70c7282184ba/`, which is not included in this bundle. Open them from the project to see them rendered; read them as reference either way.

## Source files this design was built from

| Design area | Swift source |
| --- | --- |
| Menu bar, key equivalents, launch behaviour | `app/Sources/AppDelegate.swift` |
| Toolbar items, window sizing, title/subtitle | `app/Sources/EditorWindowController.swift` |
| Body layout, status bar, zoom | `app/Sources/EditorViewController.swift` |
| Layers panel, rows, drag reorder, opacity scrub | `app/Sources/LayersPanelViewController.swift` |
| Blend-mode groups, export formats | `app/Sources/RasterCore.swift` |
| Image Size, Canvas Size, filter sheets | `app/Sources/Sheets.swift` |
| Export format and quality controls | `app/Sources/ExportAccessoryController.swift` |
