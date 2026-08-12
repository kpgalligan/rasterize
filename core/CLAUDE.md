# core/CLAUDE.md — Rust core rules

Applies to everything under `core/`. Build commands, the FFI three-file lockstep, and cross-boundary pixel conventions are in the root CLAUDE.md.

## Module map

- `lib.rs` — module declarations and re-exports only. No implementation code.
- `rz_image.rs` — flat `RzImage`, format sniffing, file open/save/encode, and `from_rgba` (the in-memory twin of `open`, for pixels only the host can decode). (Named `rz_image`, not `image`, to avoid ambiguity with the `image` crate.)
- `doc.rs` — layer model, compositing/projection, document ops, layer masks. **Full — no new concerns.** A new feature area gets a new module.
- `blend.rs` — `BlendMode` + all blend math, the shared source-over/erase pixel primitives, `LUMA_*` constants.
- `rzdc.rs` — the native `.rz` file format. The doc comment on `encode_native` **is** the format spec.
- `psd.rs` — PSD import.
- `doc_select.rs` / `doc_transform.rs` — selections/fill/gradient and mask morphology; free transform.
- `ops.rs` / `ops_filters.rs` — flat-image ops and filters (`pub(crate)`, pure, clone-then-mutate).
- `adjust.rs` — the adjustment-layer interpreter; its module doc holds the JSON schema table for every recognized `meta` op. Layer `meta` is otherwise an opaque blob the core never interprets.
- `agent.rs` — embedded MCP server (streamable HTTP, tools-only, stateless). **Generic** — knows nothing about images; the host registers the catalog and a callback.
- `assistant.rs` — Anthropic Messages API tool loop (`ureq`, non-streaming; `api_base` is the provider seam), cancellation at tool/API boundaries, image pruning of old canvas renders.
- `ffi.rs` / `ffi_doc.rs` / `ffi_filters.rs` / `ffi_agent.rs` / `ffi_assistant.rs` — thin shims only; shared plumbing lives in `ffi_util.rs`, never copy-pasted.

## Rules

**Modules and size.** New feature area = new module with its own `impl RzDocument` block (the `doc_select`/`doc_transform` pattern). Soft cap ~600 lines; needing a new `// ---- name --` banner section is the signal to split into a module instead. Every module keeps a `//!` doc; numeric/algorithmic choices get prose "why" comments (see `EXACT_EPSILON` in `doc_transform.rs` for the bar).

**One implementation per algorithm.** Before writing pixel math, find the existing implementation and route through it. If a duplicate is genuinely required (e.g. an offset-mapped variant), its comment must name the master copy. Shared constants have exactly one home (`LUMA_*` in `blend.rs`; `MAX_PIXELS` in `doc.rs`; RZDC caps in `rzdc.rs`).

**Purity.** Document/image ops take `&self` and return a new value — internally clone-then-mutate; `Arc`-shared pixels make it cheap. In-place mutation is allowed only for caller-owned mask buffers (the `rz_selection_*` family) and must be called out in the doc comment. An op that would change nothing returns `None`, never an identical copy — an identical copy registers a phantom undo step in the app.

**Errors.** Two tiers, no error enum: `Option<T>` = domain refusal, with the reason documented in the doc comment; `Result<T, String>` = I/O/decode/parse, lowercase message embedding the path (`format!("failed to read {path}: {e}")`). No input may panic — corrupt files return `Err`. FFI mapping: `None` → NULL/0/false; `Err` → `set_err(err_out, …)`; caught panic → `"internal error: <what>"` (long form, everywhere).

**FFI exports.** Every export: `#[no_mangle] pub unsafe extern "C"`, a `///` comment restating the header contract, a `/// # Safety` paragraph, NULL tolerance first, narrow `unsafe {}` blocks. Route through the shared helpers (`pure_op` / `doc_op` / `doc_get` / `ffi_util`) — a freshly hand-rolled `catch_unwind` is a review flag. Slice lengths are always recomputed from the core's own dimensions before `from_raw_parts`, never trusted from the caller. Export names mirror the Rust method exactly (`rz_doc_add_mask` ↔ `add_mask`); new ops use imperative names (`crop`, `add_mask`), not the older participial style. Don't rename existing exports.

**Format changes.** Any change to persisted layer/document state bumps `RZDC_VERSION`; the reader must keep accepting every prior version; the writer enforces the reader's caps so every file it produces can be read back. New recognized `meta` shapes update the schema table in `adjust.rs`'s module doc.

**Tests.** All tests are black-box in `core/tests/` (no `#[cfg(test)]` in `src/`), exercised **through the FFI** wherever possible, and verified against independently written oracles (e.g. the W3C reference blend) — never golden images. Shared helpers live in `tests/common/`; new feature area = new test file (don't grow an existing one past ~1500 lines). Every new export gets at least one test plus inclusion in the null-safety sweep. ImageMagick-dependent fixtures must skip gracefully when it's absent. Finish Rust work with `cargo fmt` and a clean `make lint`.
