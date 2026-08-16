//// `scribbler/host/spectest` — the WebAssembly spec test suite's reference host module,
//// `spectest`, as a carder `link.Provider.Namespace`.
////
//// Every `.wast` script in the official test suite is run against a fixed *reference host
//// module* named `spectest` (defined by the spec's
//// [`imports.wast`](https://github.com/WebAssembly/spec/blob/main/test/core/imports.wast)
//// harness): four immutable globals, one funcref table, one memory, and seven `print*`
//// functions. A conformance run cannot link the suite without it.
////
//// ## No longer ambient — a harness MUST pass `provider()`
////
//// Before the frontend/backend split, carder hard-coded the module name `"spectest"` in its
//// linker and consulted a built-in export table directly, so `spectest` was AMBIENT: every
//// instantiation saw it whether it wanted it or not. carder now ships **no built-in host
//// module at all** — it only resolves the namespaces its caller hands it. So a harness that
//// wants the reference module must pass `spectest.provider()` in the `providers` list it gives
//// `carder/runtime/link.link_imports` / `link_func_imports` (and, at instantiation,
//// `carder/pipeline.instantiate_with_provided` / `carder/embed.instantiate_with_providers`):
////
//// ```gleam
//// let providers = [spectest.provider(), ..registered_instances]
//// use state <- result.try(link.link_imports(module, providers))
//// use funcs <- result.try(link.link_func_imports(module, providers))
//// ```
////
//// Omit it and every `(import "spectest" …)` becomes an unowned namespace: its STATE imports
//// fail `UnknownImport` and its FUNCTION imports silently degrade to call-site-gated host
//// capabilities. That is a harness bug, not a spec outcome.
////
//// ## Fail-closed resolution — preserving the `assert_unlinkable` phrases
////
//// The suite asserts on the spec's *link-error phrases*, so the two failure modes must be
//// preserved exactly (see `func_type` and `export` for the per-resolver contract):
////
//// - An **unknown name** under `spectest` → both resolvers return `Error(Nil)`, which carder
////   turns into `link.UnknownImport` → the phrase `"unknown import"`.
//// - A **known name with the wrong signature/type** → the `func` resolver returns the module's
////   OWN spec signature (never the declared one), so carder's `sig == ty` equality check fails
////   → `link.IncompatibleImportType` → the phrase `"incompatible import type"`.
////
//// The state resolver gets the second property for free: carder type/limits-matches whatever
//// `export` returns against the declaration (spec §3.2), so a `(import "spectest" "table"
//// (table 100 funcref))` is rejected on limits without this module doing anything.
////
//// ## Values are spec-sourced, not chosen here
////
//// Every constant below is copied from the reference host module; none is a scribbler policy
//// choice. Changing one changes what the suite means. Floats are carried as their raw IEEE-754
//// bit pattern (D5 — never a BEAM double), matching the pipeline-wide numeric convention.

import carder/ir.{
  type FuncType, type ValType, FuncRef, FuncType, Idx32, TF32, TF64, TI32, TI64,
}
import carder/runtime/link
import carder/runtime/rt_mem
import carder/runtime/rt_table
import gleam/dynamic.{type Dynamic}
import gleam/option.{Some}

// ───────────────────────────── the spec-sourced constants ─────────────────────────────

/// The link name the reference host module is imported under: the literal `"spectest"`. Named
/// so the one string that must match the suite's `(import "spectest" …)` appears exactly once.
const link_name = "spectest"

/// The value of `spectest.global_i32 : i32` and `spectest.global_i64 : i64` — `666` in both
/// cases (raw bit pattern; for a non-negative integer the pattern IS the value). Spec-sourced.
const global_int = 666

/// The raw IEEE-754 bit pattern of `spectest.global_f32 : f32 = 666.6` — `0x4426A666` =
/// `1143383654`, the f32 nearest the double `666.6`. Stored as raw bits, NEVER a BEAM double: a
/// double cannot round-trip the f32 rounding, and the whole pipeline marshals floats as bits
/// (D5). Spec-sourced.
const global_f32_bits = 0x4426A666

/// The raw IEEE-754 bit pattern of `spectest.global_f64 : f64 = 666.6` — `0x4084D4CCCCCCCCCD` =
/// `4649074691427585229`. Raw bits, never a BEAM double, same rationale as `global_f32_bits`.
/// Spec-sourced.
const global_f64_bits = 0x4084D4CCCCCCCCCD

/// `spectest.table`'s declared minimum entry count (`10`) and maximum (`20`), of element type
/// `funcref`. Every slot starts null, so a `call_indirect` through an unfilled in-range slot
/// traps `UninitializedElement` — which is what the suite's uninitialised-element cases assert.
/// Spec-sourced.
const table_min = 10

/// `spectest.table`'s declared maximum entry count (`20`). See `table_min`. Spec-sourced.
const table_max = 20

/// `spectest.memory`'s declared minimum size in 64 KiB pages (`1`). Spec-sourced.
const memory_min_pages = 1

/// `spectest.memory`'s declared maximum size in 64 KiB pages (`2`). Spec-sourced.
const memory_max_pages = 2

/// The Safe max-pages cap baked into `spectest.memory`'s `rt_mem.fresh` — `65536` = 2¹⁶ pages,
/// the i32 4 GiB address-space cap (spec §2.5.4). The spectest memory declares max 2, so its
/// EFFECTIVE cap is `min(2, 65536) = 2`; this value only ever bounds a `memory.grow` past the
/// declared max, never below it. Not a spec constant — an engine ceiling that cannot be observed
/// here, kept explicit so the memory is built through the same constructor a guest memory is.
const mem_safe_cap = 65_536

// ───────────────────────────── the provider ─────────────────────────────

/// The reference `spectest` module as a carder link provider — a
/// `link.Namespace("spectest", func_resolver, export)` pairing the seven `print*` signatures
/// with the six state externvals.
///
/// - Returns a `link.Provider` to place in the `providers` list handed to
///   `link.link_imports` / `link.link_func_imports` (and thence to
///   `carder/pipeline.instantiate_with_provided`). Total — never fails, never raises.
///
/// **Freshness:** the provider itself is a pair of resolver closures, so it is cheap and may be
/// rebuilt per instantiation. Its STATE externvals, however, are constructed ON EACH
/// `export`/resolver CALL (see `export`) — one `provider()` value handed to two instantiations
/// gives each its OWN table and memory, never a shared one. That matches the suite's
/// expectation that `spectest` state is not carried between modules.
///
/// **D3a — no ambient authority.** Both resolvers are literal `case`s over a build-fixed set of
/// names: the name SELECTS among results written here at build time, it never CONSTRUCTS a
/// dispatch target. Nothing is derived from guest data.
pub fn provider() -> link.Provider {
  link.Namespace(link_name: link_name, func: func_resolver, state: export)
}

// ───────────────────────────── the seven `print*` functions ─────────────────────────────

/// The declared `FuncType` of a `spectest` host FUNCTION — the LINKING face of the seven
/// `print*` functions, used for spec §3.2.7 function matching (function types match by
/// EQUALITY, so this is what a mismatched import is compared against).
///
/// The reference module's signatures, verbatim:
/// `print : [] -> []`, `print_i32 : [i32] -> []`, `print_i64 : [i64] -> []`,
/// `print_f32 : [f32] -> []`, `print_f64 : [f64] -> []`, `print_i32_f32 : [i32 f32] -> []`,
/// `print_f64_f64 : [f64 f64] -> []`.
///
/// - `name`: the imported function name under module `"spectest"`.
/// - Returns `Ok(ty)` — that function's spec signature — for one of the seven names, or
///   `Error(Nil)` for ANY other name. `Error(Nil)` is what makes an unknown `spectest` function
///   import fail as `link.UnknownImport` → the `assert_unlinkable` phrase `"unknown import"`;
///   it is never a fallback to a permissive default.
/// - Total; never raises.
pub fn func_type(name: String) -> Result(FuncType, Nil) {
  case name {
    "print" -> Ok(FuncType(params: [], results: []))
    "print_i32" -> Ok(FuncType(params: [TI32], results: []))
    "print_i64" -> Ok(FuncType(params: [TI64], results: []))
    "print_f32" -> Ok(FuncType(params: [TF32], results: []))
    "print_f64" -> Ok(FuncType(params: [TF64], results: []))
    "print_i32_f32" -> Ok(FuncType(params: [TI32, TF32], results: []))
    "print_f64_f64" -> Ok(FuncType(params: [TF64, TF64], results: []))
    _ -> Error(Nil)
  }
}

/// Resolve a FUNCTION import under `spectest` to its `link.ProvidedFunc` — the `func` half of
/// `provider()`.
///
/// **The declared type is deliberately IGNORED.** carder hands a `Namespace` resolver the
/// import's DECLARED `FuncType` and then matches the returned `ProvidedFunc(sig, _)` with
/// `sig == ty`, fail-closed. A resolver for a reference-typed ABI would echo the declared type
/// back so the equality holds by construction — but `spectest` must do the OPPOSITE: it returns
/// its OWN spec signature from `func_type`, so an import that declares
/// `(func (param i32))` for `print_f32` mismatches and carder raises
/// `link.IncompatibleImportType` → the phrase `"incompatible import type"`, which is exactly
/// what the suite's `assert_unlinkable` cases assert on. Echoing `declared` here would silently
/// accept every mismatched `spectest` import and turn those cases green for the wrong reason.
///
/// - `name`: the imported function name. `_declared`: the guest's declared signature —
///   deliberately unused (see above); echoing it back would defeat the check.
/// - Returns `Ok(link.ProvidedFunc(spec_sig, no_op))` for one of the seven `print*` names, or
///   `Error(Nil)` for any other name (→ carder's `UnknownImport`, phrase `"unknown import"`).
/// - Total; never raises.
fn func_resolver(
  name: String,
  _declared: FuncType,
) -> Result(link.Provided, Nil) {
  case func_type(name) {
    Ok(sig) -> Ok(link.provided_func(sig, print_noop))
    Error(Nil) -> Error(Nil)
  }
}

/// The shared body of all seven `print*` functions: consume the arguments, return the empty
/// result list.
///
/// Every `spectest` print has WASM result type `[]`, and the suite NEVER asserts on print output
/// — the reference host module's printing is a debugging convenience, not observable behaviour.
/// So a no-op body is spec-adequate, and it is also the only *deterministic* choice: writing to
/// a shared sink would make a conformance run order-dependent. (A frontend that DOES want the
/// bytes has `carder/runtime/rt_host.append_output` as a sink; `spectest` deliberately does not
/// use it.)
///
/// - `_args`: the call's argument value list under the `link.ProvidedFunc` ABI — one `Dynamic`
///   per WASM argument (each a raw i32/i64/f32/f64 bit pattern, D5). Discarded.
/// - Returns `[]`, the empty value list. Total; node-safe; cannot trap.
fn print_noop(_args: List(Dynamic)) -> List(Dynamic) {
  []
}

// ───────────────────────────── the six state externvals ─────────────────────────────

/// The reference `spectest` module's exported STATE externvals — the `state` half of
/// `provider()`, and the direct analogue of the export table carder used to hold internally.
///
/// The reference module's state, verbatim:
///
/// - `global_i32 : i32 = 666` and `global_i64 : i64 = 666` — IMMUTABLE, raw bits.
/// - `global_f32 : f32 = 666.6` and `global_f64 : f64 = 666.6` — IMMUTABLE, carried as their
///   raw IEEE-754 bit pattern (D5), never a BEAM double.
/// - `table : funcref (min 10, max 20)` — a FRESH `rt_table.new` table, every slot null.
/// - `memory : (min 1, max 2)` pages — a FRESH `Idx32` `rt_mem.fresh` memory, zero-filled.
///
/// The table and memory are built through the SAME `rt_table.new` / `rt_mem.fresh` constructors
/// a module-defined table/memory uses, so once installed `rt_table`/`rt_mem` operate on them
/// uniformly — there is no special "imported externval" representation.
///
/// **Freshness is per call.** Each call ALLOCATES a new table and memory, so two instances
/// importing `spectest.memory` never alias; a `memory.store` in one is invisible to the other.
/// A caller that deliberately wants shared state must capture one `Provided` and hand the SAME
/// value to both instantiations (e.g. via a `link.Registered` provider), not call this twice.
///
/// - `name`: the imported state name under module `"spectest"`.
/// - Returns `Ok(link.Provided)` for one of the six names above, or `Error(Nil)` for ANY other
///   name — including a `print*` name, which is a FUNCTION and is resolved by the `func`
///   resolver instead. `Error(Nil)` becomes carder's `link.UnknownImport` → the phrase
///   `"unknown import"`; it is never an ambient zero global / empty table / default memory.
/// - The returned externval is NOT self-checked against the declaration: carder type- and
///   limits-matches it (spec §3.2), so a wrong-typed or over-large declared import fails with
///   `link.IncompatibleImportType` → `"incompatible import type"`.
/// - Total; never raises.
pub fn export(name: String) -> Result(link.Provided, Nil) {
  case name {
    "global_i32" -> Ok(immutable_global(global_int, TI32))
    "global_i64" -> Ok(immutable_global(global_int, TI64))
    "global_f32" -> Ok(immutable_global(global_f32_bits, TF32))
    "global_f64" -> Ok(immutable_global(global_f64_bits, TF64))
    "table" ->
      Ok(link.ProvidedTable(
        value: rt_table.new(table_min, Some(table_max)),
        ref_ty: FuncRef,
        min: table_min,
        max: Some(table_max),
      ))
    "memory" ->
      Ok(link.ProvidedMemory(
        value: rt_mem.fresh(
          memory_min_pages,
          Some(memory_max_pages),
          mem_safe_cap,
        ),
        min_pages: memory_min_pages,
        max_pages: Some(memory_max_pages),
        idx_type: Idx32,
      ))
    _ -> Error(Nil)
  }
}

/// Build an IMMUTABLE numeric global externval from its raw bit pattern and value type — the
/// shape all four `spectest` globals share (they are `(global i32 (i32.const 666))` style
/// constants, never `(mut …)`).
///
/// - `bits`: the value as a raw bit pattern (D5) — for `TI32`/`TI64` the integer itself, for
///   `TF32`/`TF64` the IEEE-754 pattern, never a BEAM double.
/// - `ty`: the global's value type. Together with `mutable: False` this drives carder's global
///   matching (spec §3.2.4): an import declaring `(mut i32)` for `global_i32` mismatches.
/// - Returns the `link.ProvidedGlobal` externval. Total.
fn immutable_global(bits: Int, ty: ValType) -> link.Provided {
  link.ProvidedGlobal(value: bits, ty: ty, mutable: False)
}
