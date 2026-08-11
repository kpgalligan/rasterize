# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
make app        # cargo build --release + xcodegen + xcodebuild → build/Build/Products/Release/Rasterize.app
make test       # Rust core tests (cd core && cargo test --release)
make typecheck  # fast swiftc -typecheck of app sources — the ONLY authoritative Swift check
make project    # regenerate Rasterize.xcodeproj from project.yml
make run        # build and launch
```

- Single Rust test: `cd core && cargo test --release --test doc_tests magic_wand` (test-file name, then a name filter). Run `cargo fmt` in `core/` before finishing Rust work.
- There are no Swift unit tests; app-side verification is `make typecheck` plus driving a built app (see below).
- SourceKit/IDE per-file Swift diagnostics are **noise** — they lack the bridging-header context and report false errors. Trust only `make typecheck` (must end with 0 errors).
- `Rasterize.xcodeproj` is generated; `project.yml` (xcodegen) is the source of truth. Never commit the project file. Target is arm64, macOS 13 — avoid macOS 14+ APIs (e.g. `NSBezierPath.cgPath`; use the `cgPathCompat` bridge in `app/Sources/Selection.swift`).

## Architecture

Swift/AppKit UI (programmatic, no storyboards) over a Rust staticlib core. All pixel work happens in Rust; Swift owns windows, tools, undo, and agent tool dispatch.

### FFI contract

`core/include/rasterize_core.h` is a **hand-maintained** C header — the single contract between the worlds (imported via `app/Bridging/Rasterize-Bridging-Header.h`). Changing any `rz_*` signature means editing the Rust `ffi_*.rs` file, the header, and the Swift wrapper (`app/Sources/RasterCore.swift`) in lockstep. Conventions, uniform across the surface:

- Opaque handles: `RzImage` (one image) and `RzDocument` (canvas + bottom-first layer stack). Pixels are straight (non-premultiplied) RGBA8, row 0 = top.
- **All operations are pure** — they return a new handle and never mutate the input. Undo/redo on the Swift side is therefore just a stack of handles (bounded by `NSUndoManager.levelsOfUndo`).
- Every FFI function wraps its body in `catch_unwind`, tolerates NULL inputs, and reports errors through an `err_out` heap CString freed with `rz_string_free`. Strings returned to the host come from `rz_agent_string_create`-style `CString::into_raw` and are freed by the matching free function.

### Rust core (`core/src/`)

- `doc.rs` / `doc_select.rs` / `ops.rs` / `ops_filters.rs` — document model, selections/fill/gradient, image ops, filters. `ffi*.rs` files are thin FFI shims over these. Layer `meta` is an opaque blob the core stores/copies/serializes without interpreting, EXCEPT that the compositor recognizes `{"type":"adjust", …}` (`core/src/adjust.rs`) as an adjustment layer at composite time.
- `agent.rs` — embedded MCP server (streamable HTTP, tools-only, stateless, single JSON responses). It is **generic**: the host registers a JSON tool catalog and a C callback; the protocol layer knows nothing about images.
- `assistant.rs` — the built-in chat agent: a tool-use loop over the Anthropic Messages API (`ureq`, non-streaming; `api_base` is the provider seam) emitting JSON events per turn, with cancellation at tool/API boundaries and pruning of old canvas renders from history.

### Swift app (`app/Sources/`)

- `RasterCore.swift` — Swift wrappers over the handles; `deinit` frees the Rust allocation.
- `ImageDocument.swift` — NSDocument subclass. It **overrides `updateChangeCount` to drop AppKit's automatic undo-based counting** (which fires inconsistently for off-event edits) and counts deterministically via `countEditChange()` in the edit paths. Any new edit path must call `countEditChange()` or the dirty flag breaks.
- `EditorViewController.swift` + `ImageCanvasView.swift` — tools, options bar, canvas drawing. `AppDelegate.swift` menus mirror the tool set.
- `Selection.swift` — the shared selection model: geometric shapes keep an exact `NSBezierPath` for marquee/clipping; the magic wand uses a canvas-sized u8 coverage mask (0 outside, 255 inside, intermediate = anti-aliased edge). The same convention (canvas-sized mask) is what the core's fill/gradient FFI accepts.
- `AgentServer.swift` — registers the MCP tool catalog and executes calls against live documents, trampolining to the main thread (`DispatchQueue.main.sync`). Tool failures return in-band (`isError: true`) so models can self-correct. The UI and the agent share one selection: agent-set selections show the marquee; user selections confine agent strokes.
- Painting strokes (brush/eraser/text, UI and agent alike) rasterize into a canvas-sized **premultiplied** RGBA8 overlay handed to `rz_doc_painting_layer` — the one place premultiplied alpha crosses the FFI.

### Pitfall: programmatic undo grouping

Undo registrations made outside an AppKit event (agent edits, async callbacks) land in an implicit event group that never closes, silently merging consecutive edits into one undo step. The fix — explicit `beginUndoGrouping`/`endUndoGrouping` plus flushing (`while groupingLevel > 0 { endUndoGrouping() }`) — lives in `AgentServer.performEdit`; follow that pattern for any new off-event edit path.

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
