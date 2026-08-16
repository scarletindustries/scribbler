//// `scribbler/porffor/host` — the Porffor runtime intrinsics (WASM module `""`), supplied to a
//// guest as a carder `link.Namespace` provider.
////
//// A Porffor-emitted `.wasm` imports its whole runtime environment from the EMPTY module name
//// `""`, under single-letter idents assigned in `createImport` creation order (Porffor 0.61.13,
//// `compiler/builtins.js`: `const ident = String.fromCharCode(97 + importedFuncs.length)`):
//// `a`=print, `b`=printChar, `c`=time, `d`=timeOrigin. The LETTER is the stable identity — the
//// assembler tree-shakes and re-orders the func *index* but emits each survivor's original ident
//// verbatim (`assemble.js:184`).
////
//// ## Why this lives in scribbler
////
//// These four handlers used to be hard-coded arms of carder's `rt_host.resolve_handler` (plus a
//// `profiles.porffor()` whitelist). carder is now the BACKEND and knows nothing about any wasm
//// PRODUCER toolchain, so the Porffor host environment is scribbler's: it is handed to carder as
//// an ordinary `link.Provider` (`provider/0`) at link time. carder's `link` resolver reads
//// `#(module, name)` only to SELECT among the providers it was given (D3a — no ambient
//// authority); the dispatch target is always a first-class closure written HERE and applied
//// directly, never `apply/3` on a data-derived module/function atom.
////
//// ## The two literal cases are kept in lock-step
////
//// `func_type/1` (the SIGNATURE face, used for fail-closed link matching) and `handler/1` (the
//// DISPATCH face) are both literal `case`s over the same four letters. A letter outside
//// `{a,b,c,d}` — e.g. the PGO `""."e"` `profileLocalSet` — resolves to `Error(Nil)` in BOTH,
//// which carder turns into the spec's `UnknownImport` ("unknown import"): fail-closed, never an
//// ambient default (spec §4.5.4).
////
//// ## Determinism
////
//// `print`/`printChar` are SIDE-EFFECTING: they append to THIS instance's process-local host
//// output buffer through carder's `rt_host.append_output` (drained by
//// `carder/pipeline.host_output`, §E). `time`/`timeOrigin` return a fixed `0.0` rather than the
//// real BEAM clock, so a conformance run is reproducible (§B.2) — a program whose output depends
//// on the clock is a categorized non-judgeable edge, never a false green. All four are TOTAL and
//// node-safe (tier-P/O): a host handler that could crash the node would be a sandbox hole.

import carder/ir.{type FuncType, FuncType, TF64}
import carder/runtime/instance.{type Binding, Binding, HostWhitelist}
import carder/runtime/link
import carder/runtime/profiles
import carder/runtime/rt_host
import gleam/dynamic.{type Dynamic}
import scribbler/porffor/abi

// ───────────────────────────── the Dynamic ⇄ Int coercions (D5) ─────────────────────────────

/// Identity coercion of one raw WASM argument (`Dynamic`) to `Int`.
///
/// SOUND because a `CallImport` argument crossing carder's function-import ABI is always a raw
/// i32/i64/f32/f64 **bit pattern rendered as an Erlang integer** (D5 — never a BEAM double), so
/// the runtime term already IS an integer and the coercion changes no representation. Both
/// Porffor argument-taking intrinsics (`print`, `printChar`) declare a single `f64` parameter, so
/// the term handed here is that f64's raw IEEE-754 64-bit pattern. This is exactly the coercion
/// carder's own pre-split `link.host_func_closure` performed on the way into `rt_host.call_host`.
@external(erlang, "gleam_stdlib", "identity")
fn dyn_to_int(x: Dynamic) -> Int

/// Identity coercion of a raw result bit pattern (`Int`) back to the closure ABI's `Dynamic`.
/// Sound for the same reason as `dyn_to_int` — an `Int` bit pattern IS the term carder's
/// `link.call_import` hands back to the call site (D5).
@external(erlang, "gleam_stdlib", "identity")
fn int_to_dyn(x: Int) -> Dynamic

// ───────────────────────────── the build-fixed intrinsic table (§A.3) ─────────────────────────────

/// The build-fixed Porffor-0.61.13 intrinsic ident letters (module `""`), in `createImport`
/// creation order (§A.3): `print → "a"`, `printChar → "b"`, `time → "c"`, `timeOrigin → "d"`.
/// Each element is `#(letter, builtin_name)`.
///
/// Named so the version pin is legible: a Porffor version bump is a conscious one-line re-measure
/// against `compiler/builtins.js`, never a silent mis-dispatch. Diagnostic/documentation value —
/// `func_type/1` and `handler/1` are the load-bearing literal cases, and this list MUST stay in
/// lock-step with them (same four letters).
pub const intrinsics: List(#(String, String)) = [
  #("a", "print"),
  #("b", "printChar"),
  #("c", "time"),
  #("d", "timeOrigin"),
]

/// The build-fixed `FuncType` of a Porffor intrinsic, keyed on its ident letter (§A.3) — the
/// SIGNATURE face of the four builtins, used for carder's fail-closed function-import matching
/// (spec §3.2.7 — function types are matched by EQUALITY). A literal `case` (D3a): `letter`
/// selects among build-controlled results, it never constructs one.
///
/// - `letter`: the imported function name under module `""` (`"a"`/`"b"`/`"c"`/`"d"`).
/// - Returns `Ok(FuncType([f64], []))` for `a`/`b` (print/printChar — consume one number, return
///   nothing), `Ok(FuncType([], [f64]))` for `c`/`d` (time/timeOrigin — take nothing, return one
///   number), or `Error(Nil)` for ANY other name. `Error(Nil)` is FAIL-CLOSED: the provider
///   answers "I do not export that", which carder renders as the spec's `UnknownImport`
///   ("unknown import"), so an unprovided `""` intrinsic can never be silently assumed callable.
/// - Total; never raises.
pub fn func_type(letter: String) -> Result(FuncType, Nil) {
  case letter {
    "a" | "b" -> Ok(FuncType(params: [TF64], results: []))
    "c" | "d" -> Ok(FuncType(params: [], results: [TF64]))
    _ -> Error(Nil)
  }
}

// ───────────────────────────── the four handlers (§E/§B.2) ─────────────────────────────

/// `print` (Porffor `""."a"`, `i => print(i.toString())`). Appends the number's ECMAScript
/// decimal string (`Number::toString(x, 10)`, §F — see `abi.number_to_string_bytes`) to THIS
/// instance's host output buffer.
///
/// - `args`: `[raw_f64_bits]` — the f64 argument as its raw IEEE-754 64-bit pattern (D5).
/// - Returns `[]` (the WASM result type `[]`).
/// - Total; node-safe; NaN/±Inf/±0 are handled from the bits by `abi`. A defensive empty-argument
///   call (impossible post-validation, since the declared type has one parameter) is a no-op.
fn print(args: List(Dynamic)) -> List(Dynamic) {
  case args {
    [bits, ..] -> {
      rt_host.append_output(abi.number_to_string_bytes(dyn_to_int(bits)))
      []
    }
    [] -> []
  }
}

/// `printChar` (Porffor `""."b"`, `i => print(String.fromCharCode(i))`). Appends the single UTF-16
/// code unit `truncate(f64) & 0xFFFF`, UTF-8-encoded to match the bytes Node's `stdout.write`
/// would emit (§E.2 — see `abi.char_code_to_utf8`), to the output buffer.
///
/// ALL Porffor static console text (string literals, the trailing `\n`, ANSI colour escapes)
/// flows through `printChar`, so capturing `print` + `printChar` captures the COMPLETE console
/// byte stream.
///
/// - `args`: `[raw_f64_bits]` (D5). Returns `[]`. Total; node-safe; an empty argument list is a
///   no-op (defensive — unreachable post-validation).
fn print_char(args: List(Dynamic)) -> List(Dynamic) {
  case args {
    [bits, ..] -> {
      rt_host.append_output(abi.char_code_to_utf8(dyn_to_int(bits)))
      []
    }
    [] -> []
  }
}

/// `time` (Porffor `""."c"`, `() => performance.now()`). Returns `[raw_f64_bits]` of a
/// DETERMINISTIC `0.0` ms — a fixed value, NOT the real BEAM clock, so a conformance run is
/// reproducible (§B.2). `0.0`'s raw IEEE-754 pattern is the integer `0`.
///
/// - `_args`: ignored (the declared type takes no parameters). Total; node-safe; pure.
fn time(_args: List(Dynamic)) -> List(Dynamic) {
  [int_to_dyn(0)]
}

/// `timeOrigin` (Porffor `""."d"`, `() => performance.timeOrigin`). Returns `[raw_f64_bits]` of a
/// DETERMINISTIC `0.0`, same reproducibility rationale as `time`. Total; node-safe; pure.
fn time_origin(_args: List(Dynamic)) -> List(Dynamic) {
  [int_to_dyn(0)]
}

/// Resolve the build-fixed dispatch closure for a Porffor intrinsic letter — the DISPATCH face of
/// `func_type/1`, kept in lock-step with it (identical letter set). A literal `case` (D3a): the
/// only input is the static import name, and the result is a closure written in THIS module,
/// applied directly by carder's `link.call_import`.
///
/// - `letter`: the imported function name under module `""`.
/// - Returns `Ok(closure)` for `a`/`b`/`c`/`d`, `Error(Nil)` otherwise (fail-closed — an
///   unimplemented intrinsic is never assumed callable, spec §4.5.4). Total.
fn handler(letter: String) -> Result(fn(List(Dynamic)) -> List(Dynamic), Nil) {
  case letter {
    "a" -> Ok(print)
    "b" -> Ok(print_char)
    "c" -> Ok(time)
    "d" -> Ok(time_origin)
    _ -> Error(Nil)
  }
}

// ───────────────────────────── the carder-facing provider + posture ─────────────────────────────

/// Answer a FUNCTION import of module `""` — the `func` half of `provider/0`'s `link.Namespace`.
///
/// carder hands this resolver the import's DECLARED `FuncType` and then matches the returned
/// `ProvidedFunc(sig, closure)`'s `sig == declared_ty` fail-closed. We deliberately return our
/// OWN signature from `func_type/1` (not the declared one), so a Porffor build whose `""."a"` is
/// declared with anything other than `[f64] -> []` is rejected as `IncompatibleImportType`
/// ("incompatible import type") rather than silently mis-dispatched. This is a TIGHTENING over
/// the pre-split behaviour, where `""` fell through carder's "genuine host capability" branch and
/// was gated only at the call site.
///
/// - `name`: the imported function name under `""` (the ident letter).
/// - `_declared_ty`: the guest's declared signature — intentionally unused; carder performs the
///   equality match itself against what we return.
/// - Returns `Ok(link.ProvidedFunc(ty, closure))` for a known letter, or `Error(Nil)` for any
///   other name → carder's `UnknownImport` ("unknown import"). Total; never raises.
fn resolve_func(
  name: String,
  _declared_ty: FuncType,
) -> Result(link.Provided, Nil) {
  case func_type(name), handler(name) {
    Ok(ty), Ok(call) -> Ok(link.provided_func(ty, call))
    _, _ -> Error(Nil)
  }
}

/// Answer a STATE (global/table/memory) import of module `""` — the `state` half of `provider/0`'s
/// `link.Namespace`. Porffor imports **only functions** from `""`, so this ALWAYS returns
/// `Error(Nil)`: no name, ever, resolves to a state externval, and carder renders that as the
/// spec's `UnknownImport` ("unknown import"). Fail-closed by construction. Total.
fn resolve_state(_name: String) -> Result(link.Provided, Nil) {
  Error(Nil)
}

/// The Porffor host environment as a carder `link.Provider` — the whole `""` namespace answered
/// by the two resolvers above. Hand it to `link.link_imports` / `link.link_func_imports` (see
/// `scribbler/porffor/run`) to link a Porffor-emitted guest.
///
/// - Returns `link.Namespace("", resolve_func, resolve_state)`. Pure and cheap (it allocates two
///   closures); call it per link rather than caching. Total — never fails.
///
/// D3a: the resolvers are first-class closures carder applies directly, never `apply/3` on a
/// module/function atom built from guest data. The authority they grant is BOUNDED — append bytes
/// to a process-local buffer that is GC'd with the instance, and read a constant clock — so this
/// namespace introduces no file, socket, or node authority.
pub fn provider() -> link.Provider {
  link.Namespace(link_name: "", func: resolve_func, state: resolve_state)
}

/// The build-fixed allow-set for Porffor's runtime intrinsics (§A/§G) — exactly the four
/// `#("", letter)` capability/name pairs Porffor imports from module `""` (`a`=print,
/// `b`=printChar, `c`=time, `d`=timeOrigin), nothing more. A LITERAL list (D3a — never a
/// data-driven allow-set).
///
/// - Returns the four pairs, in creation order. Total — never fails.
pub fn allow() -> List(#(String, String)) {
  [#("", "a"), #("", "b"), #("", "c"), #("", "d")]
}

/// The **Safe** `Binding` that admits Porffor's `""` runtime intrinsics — the JS-on-BEAM posture
/// (the pre-split `profiles.porffor()` / `profiles.js()`, rebuilt here now that carder knows
/// nothing about Porffor).
///
/// Identical to `profiles.safe()` except `host_policy: HostWhitelist(allow())`. It is a
/// `HostWhitelist`, **never** `HostOpen`: every non-Porffor capability stays denied (the
/// fail-closed whitelist conjunction), and an `""` name outside the four (`""."e"`, the PGO
/// `profileLocalSet`, …) is denied too.
///
/// It stays a genuinely **Safe** posture (`mode: Safe`), not an Unsafe opt-out — the four
/// intrinsics are explicit, auditable host functions with BOUNDED authority (append to a
/// process-local output buffer / read a deterministic clock), so carder's fail-closed posture
/// enumeration is unperturbed (`profiles.unsafe()`/`profiles.ceiling()` remain the only
/// `mode: Unsafe` constructors). Changing only `host_policy` means it composes with
/// `profiles.link/1` exactly as `profiles.safe()` does.
///
/// - Returns the Safe + Porffor-whitelisted `Binding`. Total — never fails.
pub fn binding() -> Binding {
  Binding(..profiles.safe(), host_policy: HostWhitelist(allow()))
}
