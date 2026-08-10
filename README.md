# Rasterize

A native macOS raster image editor. Swift/AppKit UI with a Rust core for image
decoding, encoding, and manipulation.

## Features

- **Layers**: full layer stack with per-layer opacity, visibility, offsets,
  and the full 27-mode Photoshop blend set — the separable W3C modes plus
  Dissolve, Vivid/Linear/Pin Light, Hard Mix, Divide, Darker/Lighter Color,
  and the non-separable Hue/Saturation/Color/Luminosity — grouped in the
  panel exactly like Photoshop's menu;
  layers panel with thumbnails, inline rename, drag-reorder, and
  new/delete/duplicate/merge-down/flatten; Move tool (V) with arrow-key
  nudges; Paste as New Layer; PSD files import with their real layers; the
  native `.rz` format saves the full layer stack losslessly
- Open PNG, JPEG, Photoshop (PSD, layered), TIFF, BMP, GIF, WebP
  — EXIF orientation is applied on open, so camera photos display upright
- Export a copy to PNG, JPEG (with quality control), TIFF, BMP, GIF, WebP;
  failed saves never truncate or delete an existing destination file
- Smooth zoom (pinch, ⌘+/⌘-, fit, actual size) and pan
- Rotate 90°/180°, flip horizontal/vertical
- Selection-based crop, Image Size (scale with filter choice, up to 100 MP),
  and Canvas Size with the Photoshop-style 3×3 anchor selector — grow or
  trim the canvas without scaling; layers keep their pixels and can be
  revealed again later
- Brightness / contrast / saturation, Levels, Hue Rotate, Threshold, and
  Posterize adjustments with live in-context preview on the active layer
- Grayscale, invert, sepia, Gaussian blur, sharpen, Pixelate, Add Noise,
  Edge Detect, Emboss
- Brush and eraser (size, opacity, color; `[`/`]` resize; 1 px pixel-snapped
  mode; strokes confine to an active selection) and on-canvas text
  (font/size/color, ⌘Return commits, Escape cancels) — tools switch via
  toolbar, Tools menu, or V/B/E/T
- Full undo/redo, copy to clipboard, recent files
- Drag image files onto a window to open them; File > New from Clipboard (⌘N)
- Checkerboard backdrop for transparency

Known limits: PSD support is 8-bit RGB/grayscale composites (16-bit and CMYK
files are rejected with a clear error); animated GIFs and multi-page TIFFs
load their first frame/page only, so ⌘S on a GIF deliberately routes through
Save As instead of overwriting the animation in place.

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

Bring your own API key: the panel asks once and stores it in the
keychain (launching with `ANTHROPIC_API_KEY` set also works). The model
defaults to `claude-sonnet-5`; override with
`defaults write com.kgalligan.Rasterize AssistantModel <model-id>`.

## AI agent access (MCP)

Tools > Allow Agent Connections hosts an MCP server (streamable HTTP) inside
the app at `http://127.0.0.1:4816/mcp` (`RZ_AGENT_PORT` overrides; falls back
to an ephemeral port). Any MCP client can drive the editor — 24 tools cover
opening documents, inspecting and rendering the canvas (the agent *sees* the
image as PNG), layer operations, blend modes, filters, geometry, brush and
eraser strokes (polyline points with size/color/opacity), rasterized text,
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
  crate (composite image only); everything else goes through the `image` crate.
