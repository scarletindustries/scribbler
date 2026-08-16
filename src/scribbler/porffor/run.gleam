//// `scribbler/porffor/run` — the JS-on-BEAM run path (P7-08 §C/§E): a Porffor-emitted `.wasm`
//// in, its console output + decoded completion value out.
////
//// Porffor compiles JavaScript to WebAssembly; scribbler compiles that WebAssembly to the BEAM.
//// This module is the seam that joins them, written entirely against carder's PUBLIC API — the
//// backend knows nothing about Porffor, so everything Porffor-specific (the `""` host namespace,
//// the `(f64, i32)` value model, the whitelisted posture) is supplied from here:
////
//// ```
//// .wasm ─ scribbler/pipeline.source_to_ir ─▶ carder ir.Module
////                                              │
////            link.link_imports / link_func_imports ([host.provider()])
////                                              │
////            carder/pipeline.compile_ir(m, host.binding())  ─▶ .beam
////                                              │
////            carder/pipeline.instantiate_with_provided      ─▶ owned process
////                                              │
////            invoke_instance_pair(main, [])  ▸  host_output  ▸  abi.porf_decode
////                                              │
////                                    carder/pipeline.stop_instance
//// ```
////
//// ## The multi-value entry
////
//// A Porffor program's top-level `#main` is exported as `m : () → (result f64 i32)` (T10) — its
//// completion value as a "typed value" pair. carder packages a `r >= 2` multi-value return as an
//// Erlang 2-tuple (R17), which `carder/pipeline.invoke_instance_pair` receives directly as
//// `Ok(#(f64_bits, type_tag))`; `abi.porf_decode` turns that into a judgeable `abi.PorfValue`.
////
//// ## CRITICAL ORDERING — drain the output buffer BEFORE stopping the instance
////
//// `print`/`printChar` write a **process-local** buffer inside the instance's owned process, and
//// that process (with its buffer) is GC'd by `stop_instance`. So the sequence is, strictly:
//// **invoke → `host_output` → `stop_instance`**. Draining after the invoke (rather than only on
//// success) is what preserves the partial output a program wrote *before* it trapped; draining
//// before `stop_instance` is what preserves it at all. Reordering either step silently loses
//// console bytes, which are the PRIMARY observable for a JS conformance judgement (T12).
////
//// ## Conformance-neutral
////
//// A non-Porffor module never reaches this path: the `""` provider, the output buffer and the
//// whitelisted binding are all inert for a guest that imports none of them.

import carder/backend/emit_core
import carder/ir
import carder/pipeline as backend
import carder/runtime/link
import gleam/list
import gleam/option.{type Option, None, Some}
import scribbler/pipeline.{type WasmError, Backend}
import scribbler/porffor/abi
import scribbler/porffor/host

// ─────────────────────────────── the outcome ───────────────────────────────

/// The outcome of running a Porffor-compiled JS program on the BEAM under `host.binding()`
/// (P7-08 §C/§E). The **console output is the primary observable** (T12).
///
/// - `output`: the captured `console.log` byte stream (§E) — the exact bytes `print`/`printChar`
///   produced, ANSI escapes in-band; compared byte-for-byte against `porf run` (T13). `<<>>` if
///   the program never printed, or if it failed before an instance existed.
/// - `result`: the decoded completion value of the exported entry (§D) — a scalar
///   (`PNumber`/`PBool`/`PUndefined`/`PNull`) for the common case; a heap-typed result
///   (string/object/array) is `POpaque` here, because this driver hands `porf_decode` a
///   fail-closed memory reader (see `no_mem_reader`). A `console.log` of a string still appears
///   in `output`. `PUndefined` whenever `trapped` is `Some(_)` (there is no completion value).
/// - `trapped`: `Some(reason)` if the program did not complete — a link failure (prefixed
///   `"link: "`), an instantiation-time trap, a WASM trap, a denied intrinsic, or an uncaught JS
///   throw surfaced as a BEAM exception — carrying the rendered BEAM reason (diagnostic text;
///   match on `Some`/`None`, do not parse it). `None` on a clean completion.
pub type PorfforRun {
  PorfforRun(output: BitArray, result: abi.PorfValue, trapped: Option(String))
}

/// A fail-closed `abi.MemReader` for `run`: EVERY read is denied (`Error(Nil)`), so a heap-typed
/// (pointer) completion value decodes to `POpaque` rather than to a value read from memory the
/// driver was never given a capability over (T12 — scalar + console only in this unit; the routed
/// instance-memory reader that lets pointer results decode is P7-09's, §H.2). Scalars
/// (number/boolean/undefined/null) need no memory at all, so they still decode precisely. Total.
fn no_mem_reader(_addr: Int, _len: Int) -> Result(BitArray, Nil) {
  Error(Nil)
}

// ─────────────────────────────── the driver ───────────────────────────────

/// Compile + run a Porffor-emitted `.wasm` on the BEAM under the Safe JS-on-BEAM posture and
/// collect its console output + decoded completion value (P7-08 §C/§E). The headline seam — see
/// the module doc for the stage diagram and the load-bearing drain ordering.
///
/// - `wasm`: the Porffor-emitted `.wasm` bytes. Untrusted: it goes through scribbler's full
///   decode → validate → lower frontend, so a malformed or invalid module is a stage `Error`,
///   never a crash.
/// - `main`: the entry export name to invoke with no arguments. Porffor's top-level `#main` is
///   always `"m"` (T10). It must be exported with a 2-result signature (`(f64 i32)`); any other
///   arity surfaces as a `trapped` run rather than a typed error.
/// - Returns `Ok(PorfforRun)` for anything that got as far as a runtime outcome — INCLUDING a
///   link failure, an instantiation trap, a WASM trap and an uncaught JS throw, all of which are
///   `Ok` with `trapped: Some(_)`, so a thrown program stays judgeable distinctly from a clean
///   one and its partial console output is still returned. Returns `Error(WasmError)` only for a
///   COMPILE-stage failure — `DecodeFailed`/`ValidateFailed`/`LowerFailed` from scribbler's
///   frontend, or `Backend(_)` wrapping carder's `ir-lower`/`emit`/`build`.
/// - Total — never panics. The instance's owned process is always stopped before returning on
///   every path that started one.
pub fn run(wasm: BitArray, main: String) -> Result(PorfforRun, WasmError) {
  case pipeline.source_to_ir(wasm) {
    Error(e) -> Error(e)
    Ok(m) ->
      // Resolve the import vector (state + function-import closures) against the Porffor `""`
      // namespace. A link failure is a RUNTIME outcome here (a reported `trapped` run), not a
      // compile error — the same shape the `.wast` `assert_unlinkable` case takes.
      case link_porffor_imports(m) {
        Error(reason) ->
          Ok(PorfforRun(<<>>, abi.PUndefined, Some("link: " <> reason)))
        Ok(provided) ->
          case backend.compile_ir(m, host.binding()) {
            Error(e) -> Error(Backend(e))
            Ok(beam) ->
              case backend.instantiate_with_provided(beam, m.name, provided) {
                Error(reason) ->
                  Ok(PorfforRun(<<>>, abi.PUndefined, Some(reason)))
                Ok(proc) -> {
                  let outcome = backend.invoke_instance_pair(proc, main, [])
                  // Drain AFTER the invoke and BEFORE stop_instance: print/printChar wrote the
                  // instance's process-local buffer during the call, and that process (buffer
                  // included) dies with `stop_instance` — so this is the ONE window in which
                  // partial output written before a trap can still be captured.
                  let output = backend.host_output(proc)
                  let run = case outcome {
                    Ok(#(f64_bits, type_tag)) ->
                      PorfforRun(
                        output,
                        abi.porf_decode(f64_bits, type_tag, no_mem_reader),
                        None,
                      )
                    Error(reason) ->
                      PorfforRun(output, abi.PUndefined, Some(reason))
                  }
                  backend.stop_instance(proc)
                  Ok(run)
                }
              }
          }
      }
  }
}

/// Resolve the full positional import vector for a Porffor module: the STATE imports
/// (`link.link_imports` — empty for a typical Porffor module, which imports only functions)
/// followed by the function-import dispatch closures (`link.link_func_imports`), appended in the
/// order carder's `emit_core` seeds them.
///
/// The function vector is appended ONLY when `emit_core.needs_func_imports(m)` says the module
/// actually USES an imported function (a `CallImport`/`ReturnCallImport` in a body, or a
/// `RefFuncImport` in a body or an element-segment init). That is the exact predicate `emit_core`
/// uses to decide the generated `instantiate/…` arity, so calling the SAME public function — not
/// a local copy of it — is what keeps the woven `Imports` arity matching the emitted module
/// byte-for-byte.
///
/// - `m`: the lowered IR module whose `imports` order drives the vector.
/// - Returns `Ok(state ++ funcs)` when every import is provided AND matches, or `Error(phrase)`
///   for the FIRST unsatisfied/mismatched import — the spec §4.5.4 phrase from
///   `link.import_error_phrase` (`"unknown import"` / `"incompatible import type"`), which `run`
///   reports as a `"link: "`-prefixed `trapped` outcome. Fail-closed: no instance is created.
/// - Total — never panics.
fn link_porffor_imports(m: ir.Module) -> Result(List(link.Provided), String) {
  case link.link_imports(m, [host.provider()]) {
    Error(e) -> Error(link.import_error_phrase(e))
    Ok(state) ->
      case emit_core.needs_func_imports(m) {
        False -> Ok(state)
        True ->
          case link.link_func_imports(m, [host.provider()]) {
            Error(e) -> Error(link.import_error_phrase(e))
            Ok(funcs) -> Ok(list.append(state, funcs))
          }
      }
  }
}
