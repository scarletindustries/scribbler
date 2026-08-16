//// `scribbler/embed` — the WASM-BYTES front door of the embedder API: `.wasm` in, a
//// `carder/embed.Compiled` out.
////
//// The embedder API is split across the two repos along the same seam as everything else in
//// the scribbler/carder split — the IR:
////
//// ```
//// .wasm ──▶ scribbler/embed.compile* ──▶ carder/ir.Module ──▶ carder/embed.compile_ir ──▶ Compiled
////                                                                                           │
////                        carder/embed.instantiate / invoke / stop / mem_read / mem_write ◀───┘
//// ```
////
//// Only the wasm→IR half lives here. EVERYTHING from the IR down — chunking, Core Erlang
//// codegen, `instantiate`/`instantiate_with_providers`/`invoke`/`stop`, `guest_pid`/`mem_size`,
//// `mem_read`/`mem_write`, and the compile-once artifact cache (`to_artifact`/`from_artifact`)
//// — lives in `carder/embed` and is used from there DIRECTLY. This module deliberately does not
//// wrap or re-export any of it: an embedder imports both modules, `scribbler/embed` to compile
//// bytes and `carder/embed` to run what came out.
////
//// The one type an embedder needs from both sides, `Compiled`, is re-exported here as an alias
//// of `carder/embed.Compiled` — it is the SAME type, so a value produced here is accepted by
//// `carder/embed.instantiate` unchanged.
////
//// ## Which `instantiate` to use
////
//// - Every import is an ordinary `(import "cap" "name" (func …))` over scalar WASM values →
////   `carder/embed.instantiate(compiled, host)` with the embedder's
////   `(capability, name, args) -> results` dispatcher.
//// - The guest is a **TeaVM/Java** module → `carder/embed.instantiate_with_providers(compiled,
////   host, scribbler/host/teavm.providers())`. TeaVM's `teavm.*` imports are REFERENCE-typed
////   (`externref` string handles), which the scalar `host` dispatcher cannot express; the
////   provider set supplies them as native closures and the `host` dispatcher still serves the
////   guest's own capability imports.
////
//// ## Contract for the `host` dispatcher
////
//// Unchanged from `carder/embed` — `host(capability, name, args) -> results` with raw WASM bit
//// patterns as `Int`s, running in the instance's own process, obliged to be total and node-safe.
//// See the `carder/embed` module doc for the full statement.

import carder/embed as backend
import carder/ir
import gleam/option.{type Option, None, Some}
import scribbler/pipeline

/// A compiled guest — an ALIAS of `carder/embed.Compiled`, not a new type. Re-exported so an
/// embedder can name the result of `compile`/`compile_named`/`compile_progress` without also
/// importing `carder/embed` for the type alone; the value is the identical term and is accepted
/// by `carder/embed.instantiate`, `to_artifact`, etc. See `carder/embed.Compiled` for the field
/// contract (`beam` = entry module, `module` = IR + entry atom, `extra` = helper chunks).
pub type Compiled =
  backend.Compiled

// ─────────────────────────────── compile: wasm bytes → Compiled ───────────────────────────────

/// **Compile** WASM guest bytes to a loadable module under the `Safe` profile: decode → validate
/// → lower here, then `carder/embed.compile_ir` for chunking and codegen.
///
/// - `wasm`: the guest's binary `.wasm` bytes.
/// - Returns `Ok(Compiled)` (entry beam + IR + helper chunks), or `Error(text)` describing the
///   failing pipeline stage — frontend failures rendered by `scribbler/pipeline.describe`
///   (`"decode: "` / `"validate: "` / `"lower: "`), backend failures by carder
///   (`"ir-lower: "` / `"emit: "` / `"build: "`). Total — never panics.
///
/// The generated BEAM module atom is derived from the guest's first exported function
/// (`carder@wasm@<firstexport>`). NOTE: two guests that share that first export name (e.g. any
/// two TeaVM/Java modules, which all export `teavm.stringToJs` first) compile to the SAME atom
/// and CANNOT be loaded into one node together — the second `code:load_binary` overwrites the
/// first. An embedder deploying MULTIPLE guests to one node (e.g. a Dance app with several WASM
/// modules) must give each a distinct atom via `compile_named`.
pub fn compile(wasm: BitArray) -> Result(Compiled, String) {
  compile_with_name(wasm, None, backend.no_progress)
}

/// **Compile** WASM guest bytes like `compile`, but OVERRIDE the generated BEAM module atom with
/// `name` verbatim (it becomes the `.core`/`.beam` module header AND every intra-module qualified
/// reference, so the override is fully self-consistent — indirect calls, funcref tables and the
/// `rt_table` seam all resolve against the same atom).
///
/// - `wasm`: the guest's binary `.wasm` bytes.
/// - `name`: the module atom to bake in. MUST be a valid Erlang atom string and UNIQUE across the
///   guests an embedder loads into one node (e.g. `"carder@wasm@" <> deployment <> "_" <> slug`).
///   Passing a colliding name reintroduces the load-overwrite hazard `compile` warns about.
/// - Returns `Ok(Compiled)` whose `module.name` is `name`, or `Error(text)` (same failure modes as
///   `compile`; an atom-invalid `name` surfaces as a codegen `Error` from the build stage). Total.
pub fn compile_named(wasm: BitArray, name: String) -> Result(Compiled, String) {
  compile_with_name(wasm, Some(name), backend.no_progress)
}

/// Like `compile_named`, but reports coarse build PROGRESS through `on_progress(percent, phase)` as
/// it enters each compiler phase — so an embedder (e.g. Dance) can drive a build progress bar.
///
/// - `wasm`/`name`: as `compile_named`.
/// - `percent` is the work COMPLETED before the phase begins: `0` → analyze (decode/validate/lower,
///   the frontend stage this module owns), `20` → generate (IR → Core Erlang), `45` → compile
///   (Core Erlang → BEAM). The last two are fired by `carder/embed.compile_ir`; the `45` phase is
///   the long pole (~half the wall time) and has no internal sub-progress, so the bar dwells at
///   `45` during it; the embedder owns the tail (its own caching → `100`).
/// - `phase` is a short EMBEDDER-FACING label ("analyzing"/"generating"/"compiling"); compiler
///   internals stay internal.
/// - The callback runs IN the compiling process — keep it cheap and node-safe (a crash there fails
///   the compile). Returns exactly as `compile_named`.
pub fn compile_progress(
  wasm: BitArray,
  name: String,
  on_progress: fn(Int, String) -> Nil,
) -> Result(Compiled, String) {
  compile_with_name(wasm, Some(name), on_progress)
}

/// Shared compile path for `compile`/`compile_named`/`compile_progress`, and the ONLY wasm-aware
/// step of the embedder API. When `name_override` is `Some`, the IR module's `name` (set by
/// `lower` to `carder@wasm@<firstexport>`) is replaced BEFORE handing the module to carder, so
/// codegen — which reads the emitted-module atom solely from `ir.Module.name`, every stage below
/// `lower` having no wasm left to re-derive it from — threads the override everywhere.
///
/// `on_progress(0, "analyzing")` is fired HERE, before the frontend stage; carder's `compile_ir`
/// fires the remaining `20`/`45` phases. Total — every stage error becomes `Error(text)`.
fn compile_with_name(
  wasm: BitArray,
  name_override: Option(String),
  on_progress: fn(Int, String) -> Nil,
) -> Result(Compiled, String) {
  on_progress(0, "analyzing")
  case pipeline.source_to_ir(wasm) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(m0) -> {
      let m = case name_override {
        Some(name) -> ir.Module(..m0, name: name)
        None -> m0
      }
      backend.compile_ir(m, on_progress)
    }
  }
}
