# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Per-side rules live next to the code they govern and are loaded on demand — read them before writing code on that side:

- `core/CLAUDE.md` — Rust rules: module map, FFI export conventions, errors, purity, format versioning, tests.
- `app/CLAUDE.md` — Swift rules: file placement (which files are frozen), tools, undo/dirty tracking, agent parity, hygiene.

## Commands

```sh
make app        # cargo build --release + xcodegen + xcodebuild → build/Build/Products/Release/Rasterize.app
make test       # Rust core tests (cd core && cargo test --release)
make lint       # cargo clippy --all-targets -- -D warnings (core/)
make typecheck  # fast swiftc -typecheck of app sources — the ONLY authoritative Swift check
make project    # regenerate Rasterize.xcodeproj from project.yml
make run        # build and launch
```

- Single Rust test: `cd core && cargo test --release --test doc_tests magic_wand` (test-file name, then a name filter). Run `cargo fmt` in `core/` and keep `make lint` clean before finishing Rust work.
- There are no Swift unit tests; app-side verification is `make typecheck` plus driving a built app (see below).
- SourceKit/IDE per-file Swift diagnostics are **noise** — they lack the bridging-header context and report false errors. Trust only `make typecheck` (must end with 0 errors).
- `Rasterize.xcodeproj` is generated; `project.yml` (xcodegen) is the source of truth. Never commit the project file. Both xcodegen and `make typecheck` glob `app/Sources/`, so a new Swift file needs no registration anywhere. Target is arm64, macOS 13 — avoid macOS 14+ APIs (e.g. `NSBezierPath.cgPath`; use the `cgPathCompat` bridge in `app/Sources/Selection.swift`).

## Architecture

Swift/AppKit UI (programmatic, no storyboards) over a Rust staticlib core. All pixel work happens in Rust; Swift owns windows, tools, undo, and agent tool dispatch. Design studies and the feature roadmap live in `designs/` (`gimp-image-manipulation-capabilities.md`, `high-leverage-roadmap.md`, `next-features.md`) — check them before designing a feature from scratch.

### FFI contract

`core/include/rasterize_core.h` is a **hand-maintained** C header — the single contract between the worlds (imported via `app/Bridging/Rasterize-Bridging-Header.h`). Changing any `rz_*` signature means editing the Rust `ffi_*.rs` file, the header, and the Swift wrapper (`app/Sources/RasterCore.swift`) in lockstep. Conventions, uniform across the surface:

- Opaque handles: `RzImage` (one image) and `RzDocument` (canvas + bottom-first layer stack). Pixels are straight (non-premultiplied) RGBA8, row 0 = top.
- **All operations are pure** — they return a new handle and never mutate the input. Undo/redo on the Swift side is therefore just a stack of handles (bounded by `NSUndoManager.levelsOfUndo`).
- Every FFI function wraps its body in `catch_unwind`, tolerates NULL inputs, and reports errors through an `err_out` heap CString freed with `rz_string_free`. Strings returned to the host come from `rz_agent_string_create`-style `CString::into_raw` and are freed by the matching free function.
- Selections cross the boundary as canvas-sized u8 coverage masks (0 outside, 255 inside, intermediate = anti-aliased edge) — the same convention on both sides. Painting strokes (brush/eraser/text, UI and agent alike) rasterize into a canvas-sized **premultiplied** RGBA8 overlay handed to `rz_doc_painting_layer` — the one place premultiplied alpha crosses the FFI.

### Where a feature lands — the standard recipe

Every shipped feature follows the same shape (visible in each feature commit); putting a step's code anywhere else is what bloats files:

1. Pure model + ops in a **new Rust module** with its own `impl RzDocument` block (the `doc_select.rs` / `doc_transform.rs` pattern), plus per-area tests in a new `core/tests/*.rs` file.
2. FFI three-file lockstep: `ffi_*.rs` shim → header → `RasterCore.swift`.
3. Swift model/value types + `extension RasterDocument` in a **small dedicated file** (the `TextLayer.swift` / `LayerTransform.swift` / `AdjustmentLayer.swift` pattern).
4. Canvas gesture handling as a session struct plus `on*` closures in `ImageCanvasView` — wiring only, logic in the feature's file.
5. Controller logic in an `EditorViewController+<Feature>.swift` extension file; menu items in `AppDelegate` (nil-target selectors through the responder chain); validation cases in `validateUserInterfaceItem`.
6. MCP parity: `AgentServer` handler + catalog entry (see `app/CLAUDE.md`), with a comment naming the UI path it mirrors.
7. Dialogs as a `…SheetController` built on the shared `makeSheetView` builders in `Sheets.swift`.
8. Verify: `make test`, `make typecheck`, then drive the built app over MCP (below). Update README.

## Driving a built app for verification

The MCP server is the reliable way to exercise the app end-to-end (open documents, run tools, render the canvas as PNG, check undo):

```sh
(RZ_AGENT_PORT=4917 ANTHROPIC_API_KEY=dummy \
  ./build/Build/Products/Release/Rasterize.app/Contents/MacOS/Rasterize \
  -ApplePersistenceIgnoreState YES -AgentServerEnabled YES &)
# then POST MCP JSON-RPC to http://127.0.0.1:4917/mcp
```

A freshly built binary otherwise blocks on launch behind a keychain authorization prompt when the assistant panel looks for its API key — a dummy `ANTHROPIC_API_KEY` in the environment short-circuits that read.

Use a non-default port (default is 4816) and argv-style defaults so nothing leaks into the user's own instances. The user often has their own Xcode-launched Rasterize running — never signal or kill Rasterize processes you didn't launch; find your own with `pgrep -f '^\./build/.*MacOS/Rasterize'`. Prefer opening documents via the `open_document` MCP tool over launch-time argv paths.
