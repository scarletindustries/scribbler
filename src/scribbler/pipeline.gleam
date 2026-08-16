//// `scribbler/pipeline` — the WebAssembly-entry driver: `.wasm` bytes in, a BEAM result out.
////
//// scribbler is a **frontend**. It owns the WebAssembly binary/text format (`scribbler/wasm/*`
//// — decode, validate, canon, lower, wat) and nothing below the IR; everything downstream —
//// the policy pass, the optimizer, Core Erlang codegen, the BEAM runtime, the run-ABI — lives
//// in the `carder` package and is consumed from here as an ordinary Gleam dependency.
////
//// ```
//// .wasm ──decode──▶ AST ──validate──▶ TypedModule ──lower──▶ carder/ir.Module
////                                                                    │
////     ┌───────────────────────── scribbler ends here ────────────────┘
////     ▼
//// carder: ir_lower ──▶ ir_opt ──▶ emit_core ──▶ build_beam ──▶ BEAM
//// ```
////
//// ## Error composition (D4)
////
//// Each stage owns its own error type; they compose at exactly ONE seam. scribbler's three
//// frontend stages become `DecodeFailed`/`ValidateFailed`/`LowerFailed`, and every backend
//// failure arrives already-composed as `carder/pipeline.PipelineError`, wrapped here as
//// `Backend`. `describe/1` renders all four with the same stage prefixes the single-repo CLI
//// printed (`"decode: "`, `"validate: "`, `"lower: "`, then carder's `"ir-lower: "`/`"emit: "`/
//// `"build: "`), so a diagnostic is byte-identical to before the split.
////
//// ## The run/invoke ABI (FIXED CONTRACT)
////
//// Arguments and results are **raw unsigned bit patterns as Erlang integers** — an i32 in
//// `[0, 2^32)`, an i64 in `[0, 2^64)`; floats marshal as their raw IEEE-754 bit pattern, also
//// an integer (D5 — never a BEAM double). A **trap** surfaces as `carder/pipeline.Trapped`, an
//// uncaught WebAssembly exception as `UncaughtException` — a DISTINCT outcome (T8:
//// `assert_exception` ≠ `assert_trap`). Both are runtime outcomes, never compile errors.
////
//// ## Posture threading
////
//// No stage here branches on a `Binding` axis. `binding.narrow_carried` is the ONE build-time
//// field the frontend reads (it selects the liveness narrowing in `lower.lower_with`); every
//// other field is threaded unchanged into carder, which consumes them at codegen and run time.
//// A tier/strategy mismatch is a *linker* rejection surfaced by `carder/cli.resolve_binding`
//// before any stage runs — never a pipeline-stage error.

import carder/ir
import carder/pipeline as backend
import carder/runtime/instance.{type Binding}
import gleam/string
import scribbler/wasm/ast
import scribbler/wasm/decode
import scribbler/wasm/lower
import scribbler/wasm/validate

/// The union of every stage's error, assembled at the driver boundary (D4). Each variant WRAPS
/// the failing stage's OWN error type — there is no shared `StageError`. A
/// `Result(_, WasmError)` is `Error(variant)` iff that named stage rejected the input
/// (fail-closed) — never a panic.
///
/// - `DecodeFailed`: the WebAssembly binary decoder rejected the bytes.
/// - `ValidateFailed`: the `full` validator rejected the module.
/// - `LowerFailed`: WASM-AST → carder IR lowering failed.
/// - `Backend(_)`: every stage BELOW the IR, already composed by carder
///   (`ir-lower` / `emit` / `build`). scribbler never inspects it — it only renders it.
pub type WasmError {
  DecodeFailed(ast.DecodeError)
  ValidateFailed(validate.ValidateError)
  LowerFailed(lower.LowerError)
  Backend(backend.PipelineError)
}

/// A short, human-readable rendering of a `WasmError` (which stage + the wrapped error) for CLI
/// stderr. The backend arm DELEGATES to `carder/pipeline.describe`, so carder owns the wording
/// of its own stages and this can never drift from them. Total — never panics. The text is
/// diagnostic only; programmatic callers should match the variant, not parse this string.
pub fn describe(error: WasmError) -> String {
  case error {
    DecodeFailed(e) -> "decode: " <> string.inspect(e)
    ValidateFailed(e) -> "validate: " <> string.inspect(e)
    LowerFailed(e) -> "lower: " <> string.inspect(e)
    Backend(e) -> backend.describe(e)
  }
}

// ─────────────────────────────── the frontend stage driver ───────────────────────────────

/// Decode → validate → frontend-lower a `.wasm` binary into carder's shared IR. Each stage's
/// typed error is mapped to its `WasmError` variant.
///
/// - `wasm`: untrusted `.wasm` bytes.
/// - Return: `Ok(ir.Module)` or the first failing stage's `Error(WasmError)`. No policy pass or
///   codegen is run here (that is carder's half — see `compile`). Total — never panics.
pub fn source_to_ir(wasm: BitArray) -> Result(ir.Module, WasmError) {
  source_to_ir_with(wasm, False)
}

/// As `source_to_ir`, but `narrow_carried` selects the frontend liveness narrowing (lever 5).
/// Pass `binding.narrow_carried` from a binding-carrying compile path (e.g. `run`); `False` (the
/// `source_to_ir/1` default) reproduces the byte-identical no-narrowing lowering. The narrowing
/// only ever removes a carried local it can PROVE dead at its construct's exit, so `True` is
/// behaviour-preserving.
pub fn source_to_ir_with(
  wasm: BitArray,
  narrow_carried: Bool,
) -> Result(ir.Module, WasmError) {
  case decode.decode(wasm) {
    Error(e) -> Error(DecodeFailed(e))
    Ok(m) ->
      case validate.validate(m) {
        Error(e) -> Error(ValidateFailed(e))
        Ok(tm) ->
          case lower.lower_with(tm, narrow_carried) {
            Error(e) -> Error(LowerFailed(e))
            Ok(irmod) -> Ok(irmod)
          }
      }
  }
}

// ─────────────────────────────── end-to-end (frontend + carder) ───────────────────────────────

/// Compile `.wasm` bytes all the way to a loadable `.beam` under `binding`:
/// `source_to_ir_with` here, then carder's `compile_ir` (ir_lower → optimize → emit_core →
/// `compile:forms`).
///
/// - `wasm`: the `.wasm` bytes. `binding`: the build-time runtime binding (compose it with
///   `carder/cli.resolve_binding`, which validates it fail-closed through `profiles.link/1`).
/// - Return: `Ok(beam_bytes)` or the first failing stage's `Error(WasmError)`. Total.
pub fn compile(
  wasm: BitArray,
  binding: Binding,
) -> Result(BitArray, WasmError) {
  case source_to_ir_with(wasm, binding.narrow_carried) {
    Error(e) -> Error(e)
    Ok(m) ->
      backend.compile_ir(m, binding)
      |> map_backend
  }
}

/// End-to-end: `.wasm` bytes → result on the BEAM, through carder's run-ABI
/// `load → instantiate → invoke` with one-instance-one-process isolation.
///
/// Composes `source_to_ir_with` → `carder/pipeline.run_ir`. This is the CLI `run` subcommand's
/// engine and the shape the acceptance corpus proves green. The raw-bit-pattern
/// argument/result ABI (D5) is unchanged.
///
/// **Posture-agnostic:** `binding` carries the chosen `state_strategy` and tiers UNCHANGED
/// through every stage, so a `Threaded`/`atomics` binding runs the SAME driver code as
/// `Cell`/`paged` and returns byte-identical results — the difference is confined to the loaded
/// `.beam` and the linked runtime module.
///
/// - `wasm`: the `.wasm` bytes. `binding`: the resolved build binding.
/// - `export`: the exported function name to invoke. `args`: raw unsigned bit-pattern integers.
/// - Return: `Ok(Returned(_))` on a normal return; `Ok(Trapped(_))` /
///   `Ok(UncaughtException(_,_))` for an INSTANTIATION-time or RUNTIME trap/throw — both are
///   runtime outcomes, classified identically by carder (T8); or the first compile-stage
///   `Error(WasmError)`. Total — never panics.
pub fn run_source(
  wasm: BitArray,
  binding: Binding,
  export: String,
  args: List(Int),
) -> Result(backend.RunResult, WasmError) {
  case source_to_ir_with(wasm, binding.narrow_carried) {
    Error(e) -> Error(e)
    Ok(m) ->
      backend.run_ir(m, binding, export, args)
      |> map_backend
  }
}

/// Like `run_source`, but compiles the guest as N balanced CHUNKS (carder's `ir_to_chunks`),
/// loads every chunk beam, then instantiates + invokes the entry (chunk 0). Used to prove
/// chunked compilation is behaviour-identical to the whole-module path (a chunked guest must
/// return byte-identical results / traps), and it is the shape the memory-bounded server path
/// uses.
///
/// - `wasm`/`binding`/`export`/`args`: as `run_source`. `target`/`min_split_defs`: chunk
///   controls (a small `min_split_defs` forces a split even on a small guest, for testing).
/// - Return: identical to `run_source`. Total — never panics.
pub fn run_source_chunked(
  wasm: BitArray,
  binding: Binding,
  export: String,
  args: List(Int),
  target: Int,
  min_split_defs: Int,
) -> Result(backend.RunResult, WasmError) {
  case source_to_ir_with(wasm, binding.narrow_carried) {
    Error(e) -> Error(e)
    Ok(m) ->
      backend.run_ir_chunked(m, binding, export, args, target, min_split_defs)
      |> map_backend
  }
}

/// Wrap a carder-side `Result(a, PipelineError)` as a `Result(a, WasmError)`. The single place
/// the backend's error type crosses into the frontend's, so no other function has to know that
/// `Backend` exists. Total.
fn map_backend(r: Result(a, backend.PipelineError)) -> Result(a, WasmError) {
  case r {
    Ok(v) -> Ok(v)
    Error(e) -> Error(Backend(e))
  }
}
