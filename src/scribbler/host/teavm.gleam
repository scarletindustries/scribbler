//// `scribbler/host/teavm` — the TeaVM WASM GC host runtime, as carder link providers
//// (experimental).
////
//// TeaVM's WebAssembly-GC backend compiles Java to a `.wasm` that imports a small, stable set of
//// host functions from five namespaces — `teavmJso` (a generic Java↔JS object bridge),
//// `wasm:js-string` (the standard W3C JS String Builtins), `teavmMemory`/`teavmDate`/`teavm`
//// (heap, time, stack-trace hooks) — plus an imported linear `memory` (`env.memory`) and two
//// `teavmMemory` layout globals. In a browser those come from the generated
//// `<module>.wasm-runtime.js`; on the BEAM they come from HERE.
////
//// ## Why a `link.Provider.Namespace` and not an `rt_host` capability
////
//// TeaVM's function imports are REFERENCE-typed (`externref`/`funcref`/GC refs = BEAM terms),
//// but carder's `rt_host.call_host`/`HostHandler` seam is a NUMERIC ABI (`List(Int) ->
//// List(Int)`), which cannot carry a term. So these imports are supplied instead as
//// `link.Provider.Namespace` values whose `func` resolver returns a TERM-native
//// `link.ProvidedFunc(ty, closure)` — the same `fn(List(Dynamic)) -> List(Dynamic)` closure ABI
//// the cross-module register seam uses. carder matches a namespace-supplied `ProvidedFunc(sig,
//// _)` against the declared type by EQUALITY (`sig == ty`, spec §3.2.7), so every resolver here
//// returns `ProvidedFunc(declared_ty, …)` built from the type it is handed: the match holds by
//// construction and the handler's fate is the handler, not the linker. These imports are
//// therefore NOT `HostPolicy`-gated — installing `providers()` IS the grant.
////
//// `dispatch/2` is a build-fixed literal `case` (D3a): the target closure is written HERE and
//// selected by the static capability/name strings, never `apply/3` on program data.
////
//// ## The `env` namespace is name-scoped, and the whole provider set is opt-in
////
//// Pre-split, carder resolved TeaVM's state imports by intercepting the ENTIRE `"env"` namespace
//// as a built-in — but `"env"` is ALSO the generic host namespace every other guest imports
//// from, so a non-TeaVM guest declaring e.g. `(import "env" "config" (global i32))` was answered
//// by TeaVM's table (a spurious `"unknown import"`) instead of by its own embedder. Two changes
//// fix that here:
////
//// 1. **Name-scoped.** The `env` namespace's STATE resolver answers ONLY `"memory"` and returns
////    `Error(Nil)` — carder's spec-exact `"unknown import"` — for every other name.
//// 2. **Opt-in.** carder ships no built-in host module at all: `providers()` is installed by the
////    CALLER, and only for a guest it has identified as a TeaVM module (see
////    `is_teavm_capability/1`). A guest that imports nothing from `teavmJso` &co. never sees
////    this table.
////
//// Claiming `"env"` also claims its FUNCTION imports (carder routes a function import to the
//// provider that owns its namespace), so the `env` namespace's `func` resolver answers
//// `Error(Nil)` for EVERY name. Nothing real is intercepted: TeaVM's WASM GC backend emits
//// `env.memory` and no `env` function import at all — a guest's embedder-facing functions come
//// from the embedder's OWN namespace (the Dance Java SDK's guests import theirs from `dance`),
//// which no provider here owns and which therefore still falls through to carder's ordinary
//// host path. A guest that DID import an `env` function while these providers are installed
//// fails loudly at link time with the spec's `"unknown import"` rather than silently bypassing
//// the embedder's numeric dispatcher.
////
//// ## Scope (v0 — enough to instantiate + run a pure-compute Java method)
////
//// The `(start)` bootstrap calls only four `teavmJso` functions (`createClass`/`createFunction1`/
//// `defineFunction`/`defineStaticMethod`) to wire the module's export table; `compute()`-style
//// methods allocate GC objects and dispatch via `call_ref` without touching any import. So every
//// handler here is a TYPE-CORRECT stub — an `externref`/`(ref extern)` result is a real non-null
//// externref (`{ref_extern, 0}`), a GC-ref result is the shared null sentinel, a numeric result is
//// `0`, a `()`-typed result is the empty list. `stringBuiltinsSupported → 0` steers TeaVM onto its
//// WASM-internal string path so the `wasm:js-string` handlers stay unreached. Real behaviour (JS
//// interop, host strings over binaries) is a follow-up; these stubs make the bootstrap survive.

import carder/ir.{type FuncType, Idx32, TI32}
import carder/runtime/link
import carder/runtime/rt_mem
import carder/runtime/rt_ref
import gleam/dynamic.{type Dynamic}
import gleam/option.{Some}

// ─────────────────────────────── the runtime's fixed layout ───────────────────────────────

/// Minimum size of TeaVM's imported linear memory, in 64 KiB pages — the `env.memory` import's
/// declared `min`. 33 pages ≈ 2.1 MiB: TeaVM's static data plus its initial malloc heap.
const mem_min_pages = 33

/// Maximum size of TeaVM's imported linear memory, in 64 KiB pages (2 GiB) — the `env.memory`
/// import's declared `max`, and the ceiling a `memory.grow` may reach.
const mem_max_pages = 32_768

/// Deployment safety cap handed to `rt_mem.fresh` for the imported memory, in pages — the paged
/// tier's hard allocation ceiling (65 536 pages = the full 32-bit 4 GiB address space), so it
/// never binds before `mem_max_pages` does.
const mem_safe_cap = 65_536

/// Value of the immutable `teavmMemory.heapOffset` i32 global — the linear-memory byte offset at
/// which TeaVM's malloc heap begins. 216 is aligned past the module's ~211 B of static data;
/// lowering it would let the heap scribble over the guest's own data segment.
const heap_offset = 216

/// Value of the immutable `teavmMemory.maxSize` i32 global — the byte ceiling TeaVM's allocator
/// believes it may grow its heap to (`2^31 - 1`, i.e. the largest positive signed i32).
const max_size = 2_147_483_647

// ─────────────────────────────── the provider set ───────────────────────────────

/// The complete set of carder link providers a TeaVM WASM GC guest needs — one
/// `link.Provider.Namespace` per namespace it imports from. Hand this (or it appended to any
/// `(register)`ed providers) to `carder/runtime/link.link_imports` /
/// `link_func_imports` / `carder/pipeline.instantiate_with_provided`.
///
/// Seven namespaces across six providers:
///
/// - `teavmJso`, `wasm:js-string`, `teavmDate`, `teavm` — FUNCTION imports only; each resolves
///   to the term-native stub from `dispatch/2`. Their `state` resolver always answers
///   `Error(Nil)` (a global/table/memory import from these namespaces is `"unknown import"`).
/// - `teavmMemory` — BOTH: the `notifyHeapResized` function import AND the `heapOffset`/
///   `maxSize` globals, so its single `Namespace` carries both resolvers.
/// - `env` — the imported linear `memory` only (see the module doc): its `state` resolver
///   answers `"memory"` and nothing else, and its `func` resolver answers nothing at all (TeaVM
///   emits no `env` function import).
///
/// **Install this ONLY for a guest identified as a TeaVM module** (`is_teavm_capability/1` over
/// its import namespaces). It is a grant, not a default: the function handlers here are stubs
/// that bypass the `HostPolicy`, and `env.memory` would otherwise be a foreign guest's own
/// embedder's business.
///
/// - Returns a fresh list of providers. Each call is independent; the `env.memory` externval is
///   minted per RESOLUTION (see `export/1`), so re-using one `providers()` list across two
///   instantiations still gives each instance its own memory. Total — never fails.
pub fn providers() -> List(link.Provider) {
  [
    func_namespace("teavmJso"),
    func_namespace("wasm:js-string"),
    // `teavmMemory` is the one namespace with BOTH function and state imports.
    link.Namespace(
      link_name: "teavmMemory",
      func: fn(name, ty) { teavm_func("teavmMemory", name, ty) },
      state: teavm_memory_state,
    ),
    func_namespace("teavmDate"),
    func_namespace("teavm"),
    // `env` is the GENERIC host namespace: claim `memory` and nothing else.
    link.Namespace(link_name: "env", func: no_func, state: env_state),
  ]
}

/// Whether `capability` is one of the five TeaVM host FUNCTION namespaces. This is the caller's
/// gate: a guest whose imports mention any of them is a TeaVM module and should be instantiated
/// with `providers()`; a guest that mentions none must NOT be, or it inherits `env.memory` and
/// the stub handlers it never asked for.
///
/// - `capability`: an import's module (namespace) string, e.g. `ir.ImportFn`'s first field.
/// - Returns `True` for `teavmJso` / `wasm:js-string` / `teavmMemory` / `teavmDate` / `teavm`,
///   `False` otherwise. `"env"` is deliberately NOT a member — it is the generic host namespace
///   and proves nothing about the guest. Total.
pub fn is_teavm_capability(capability: String) -> Bool {
  case capability {
    "teavmJso" | "wasm:js-string" | "teavmMemory" | "teavmDate" | "teavm" ->
      True
    _ -> False
  }
}

/// Build a FUNCTION-only namespace provider for `capability`: every function import is answered
/// by `dispatch/2`'s stub, every state import is `Error(Nil)` (`"unknown import"`).
fn func_namespace(capability: String) -> link.Provider {
  link.Namespace(
    link_name: capability,
    func: fn(name, ty) { teavm_func(capability, name, ty) },
    state: no_state,
  )
}

/// Resolve one TeaVM function import to a term-native `ProvidedFunc` built from the DECLARED
/// type. Returning the declared `ty` (rather than a signature of our own) is what makes carder's
/// fail-closed `sig == ty` equality match hold by construction — required, because these imports
/// are reference-typed and scribbler has no independent table of their signatures. Never fails:
/// an unmodelled name still gets `dispatch/2`'s fail-soft empty-result stub.
fn teavm_func(
  capability: String,
  name: String,
  ty: FuncType,
) -> Result(link.Provided, Nil) {
  Ok(link.provided_func(ty, dispatch(capability, name)))
}

/// The state resolver of a function-only namespace: no globals, tables or memories at all, so
/// every name is `Error(Nil)` — carder's spec phrase `"unknown import"`.
fn no_state(_name: String) -> Result(link.Provided, Nil) {
  Error(Nil)
}

/// The function resolver of a STATE-only namespace (`env`): no function at all, so every name is
/// `Error(Nil)` — `"unknown import"`. Deliberate, not an oversight: see the module doc §"The
/// `env` namespace is name-scoped" — TeaVM emits no `env` function import, and failing loudly
/// beats silently intercepting one from the embedder.
fn no_func(_name: String, _ty: FuncType) -> Result(link.Provided, Nil) {
  Error(Nil)
}

/// The `teavmMemory` namespace's STATE resolver: the two immutable layout globals, and nothing
/// else. Delegates the values to `export/1` so the externval table has ONE definition.
fn teavm_memory_state(name: String) -> Result(link.Provided, Nil) {
  case name {
    "heapOffset" | "maxSize" -> export(name)
    _ -> Error(Nil)
  }
}

/// The `env` namespace's STATE resolver — NAME-SCOPED to `"memory"` (module doc §"The `env`
/// namespace is name-scoped"). Every other name is `Error(Nil)`, so a guest's own `env` globals/
/// tables/memories are left to its embedder rather than being answered by TeaVM's table.
fn env_state(name: String) -> Result(link.Provided, Nil) {
  case name {
    "memory" -> export("memory")
    _ -> Error(Nil)
  }
}

// ─────────────────────────────── function imports (term-native) ───────────────────────────────

/// Coerce a Gleam `Int` to `Dynamic` (identity at runtime) — a numeric result value (`i32`/`i64`
/// as its raw bit pattern, `f32`/`f64` as `0`-bits = `0.0`).
@external(erlang, "gleam_stdlib", "identity")
fn int_dyn(n: Int) -> Dynamic

/// A non-null externref stand-in for a JS handle the BEAM host does not model — `{ref_extern, 0}`
/// (via `rt_ref`, so it is a genuine, forge-proof externref term). Satisfies both `externref` and
/// the non-nullable `(ref extern)` result types.
fn ext0() -> Dynamic {
  rt_ref.extern_of(0)
}

/// The shared null sentinel `{ref_null}` — used for a GC object-reference (`(ref null $t)`) result
/// a stub does not produce.
fn null0() -> Dynamic {
  rt_ref.null_ref()
}

/// Resolve one TeaVM host import `#(capability, name)` to its BEAM handler — a TERM-native closure
/// `fn(List(Dynamic)) -> List(Dynamic)` (the `link.ProvidedFunc` ABI). Build-fixed literal `case`
/// (D3a): the returned closure is written here, never constructed from `capability`/`name`/`args`.
///
/// Every arm's RESULT arity + shape matches the import's declared `FuncType`: `externref`/`(ref
/// extern)` → `[ext0()]`; a GC object ref → `[null0()]`; `i32`/`f64` → `[int_dyn(0)]`; `()` → `[]`.
/// An unrecognised pair returns the empty result (a `()`-typed import scribbler does not model),
/// never a crash. The `args` are ignored by every stub (the compute path never reads a stub's
/// effect).
///
/// - `capability` / `name`: the import's `#(module, name)` identity, verbatim from the guest's
///   import section.
/// - Returns the handler closure. Total — every input has an arm, and applying the result cannot
///   fail.
pub fn dispatch(
  capability: String,
  name: String,
) -> fn(List(Dynamic)) -> List(Dynamic) {
  case capability, name {
    // ── teavmJso — the generic Java↔JS object bridge. The FOUR the `(start)` bootstrap calls
    //    to build the module's JS-facing export table (each returns a JS handle we stub):
    "teavmJso", "createClass" -> fn(_args) { [ext0()] }
    "teavmJso", "createFunction1" -> fn(_args) { [ext0()] }
    "teavmJso", "defineFunction" -> fn(_args) { [ext0()] }
    "teavmJso", "defineStaticMethod" -> fn(_args) { [] }
    // ── teavmJso — the rest (unreached on the pure-compute path; type-correct stubs):
    "teavmJso", "getProperty" -> fn(_args) { [ext0()] }
    "teavmJso", "callFunction1" -> fn(_args) { [ext0()] }
    "teavmJso", "wrapInt" -> fn(_args) { [ext0()] }
    "teavmJso", "unwrapInt" -> fn(_args) { [int_dyn(0)] }
    "teavmJso", "wrapObject" -> fn(_args) { [null0()] }
    "teavmJso", "unwrapJavaObject" -> fn(_args) { [null0()] }
    "teavmJso", "javaObjectToJS" -> fn(_args) { [ext0()] }
    "teavmJso", "isUndefined" -> fn(_args) { [int_dyn(0)] }
    // Steer TeaVM off the host js-string path (0 = builtins unsupported) so the string handlers
    // below stay unreached; a pure-compute method needs no string ops.
    "teavmJso", "stringBuiltinsSupported" -> fn(_args) { [int_dyn(0)] }
    // ── wasm:js-string — the standard W3C JS String Builtins (unreached while builtins→0):
    "wasm:js-string", "fromCharCode" -> fn(_args) { [ext0()] }
    "wasm:js-string", "fromCharCodeArray" -> fn(_args) { [ext0()] }
    "wasm:js-string", "substring" -> fn(_args) { [ext0()] }
    "wasm:js-string", "concat" -> fn(_args) { [ext0()] }
    "wasm:js-string", "length" -> fn(_args) { [int_dyn(0)] }
    "wasm:js-string", "charCodeAt" -> fn(_args) { [int_dyn(0)] }
    "wasm:js-string", "intoCharCodeArray" -> fn(_args) { [int_dyn(0)] }
    // ── teavmMemory / teavmDate / teavm — heap, time, stack-trace hooks:
    "teavmMemory", "notifyHeapResized" -> fn(_args) { [] }
    "teavmDate", "currentTimeMillis" -> fn(_args) { [int_dyn(0)] }
    "teavm", "takeStackTrace" -> fn(_args) { [ext0()] }
    "teavm", "decorateException" -> fn(_args) { [] }
    // Any TeaVM host import scribbler does not (yet) model: a `()`-result no-op, fail-soft.
    _, _ -> fn(_args) { [] }
  }
}

// ─────────────────────────────── state imports (externvals) ───────────────────────────────

/// The TeaVM WASM GC runtime's imported STATE externvals (experimental) — the single table the
/// namespace resolvers above read, exposed for a caller that wants one directly.
///
/// - `"memory"` (imported as `env.memory`) — a FRESH `rt_mem` paged memory of
///   `mem_min_pages` (33) zero-filled pages, capped at `mem_max_pages` (32 768) with the
///   `mem_safe_cap` deployment ceiling, `Idx32`. The guest's own active data segments fill it at
///   instantiate. **Each call mints a NEW memory** (never a shared one), so two instances never
///   alias — call it once per instantiation.
/// - `"heapOffset"` (imported as `teavmMemory.heapOffset`) — the immutable i32 global `216`, the
///   byte offset where TeaVM's malloc heap starts.
/// - `"maxSize"` (imported as `teavmMemory.maxSize`) — the immutable i32 global `2_147_483_647`,
///   the heap's byte ceiling.
///
/// A literal `case` — no ambient authority (D3a).
///
/// - `name`: the imported name (NOT the namespace — the two namespaces' names are disjoint, and
///   each namespace resolver narrows to its own before calling here).
/// - Returns `Ok(link.Provided)` for the three names above; `Error(Nil)` for anything else, which
///   carder turns into the spec's `"unknown import"` link failure. Total — never panics.
pub fn export(name: String) -> Result(link.Provided, Nil) {
  case name {
    "memory" ->
      Ok(link.ProvidedMemory(
        value: rt_mem.fresh(mem_min_pages, Some(mem_max_pages), mem_safe_cap),
        min_pages: mem_min_pages,
        max_pages: Some(mem_max_pages),
        idx_type: Idx32,
      ))
    "heapOffset" ->
      Ok(link.ProvidedGlobal(value: heap_offset, ty: TI32, mutable: False))
    "maxSize" ->
      Ok(link.ProvidedGlobal(value: max_size, ty: TI32, mutable: False))
    _ -> Error(Nil)
  }
}
