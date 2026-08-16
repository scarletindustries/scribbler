//// CLI integration tests for the **scribbler** binary — they drive the subcommand dispatcher
//// (`scribbler.run/1`) exactly as `main` does (it is `run(argv.load().arguments)`), proving that
//// every WebAssembly-entry stage is independently invokable and that bad input yields a typed
//// error (never a panic).
////
//// These exercise the REAL pipeline + file IO (reading the committed corpus `.wasm` fixtures), so
//// they are true end-to-end CLI tests, not arg-parsing unit tests.
////
//// **Scope (the split).** scribbler's CLI is `.wasm`-entry: `decode` / `validate` /
//// `to-ir`(`lower`/`ir`) / `to-core` / `run` / `build`(`to-beam`) / `help`. carder's `.ir`-entry
//// verbs (`ir-lower`, `opt`, `emit`, `to-erl`, `to-beam` on a `.ir`, `exec`) belong to the carder
//// binary and are proven by carder's own `cli_test` — nothing here re-asserts them.

import gleam/string
import scribbler
import simplifile

const corpus = "test/scribbler/conformance/corpus"

// ─────────────────────────────── end-to-end `run` ───────────────────────────────

/// `run add.wasm add 2 3` prints `5` (the documented arg convention: raw unsigned decimals).
/// This is the full Safe pipeline (decode→validate→lower→ir_lower→…→invoke) behind one command.
pub fn cli_run_add_test() {
  assert scribbler.run(["run", corpus <> "/add.wasm", "add", "2", "3"])
    == Ok("5")
}

/// `run sum_to.wasm sum_to 100` prints `5050` — the constant-space loop, through ir_lower.
pub fn cli_run_sum_to_test() {
  assert scribbler.run(["run", corpus <> "/sum_to.wasm", "sum_to", "100"])
    == Ok("5050")
}

/// `run --unsafe add.wasm add 2 3` prints `5` — the whole `.wasm` pipeline runs correctly under
/// the Unsafe posture too, returning the SAME spec-correct result as Safe (F2 — a posture axis
/// never changes an observable answer).
pub fn cli_run_unsafe_add_test() {
  assert scribbler.run([
      "run",
      "--unsafe",
      corpus <> "/add.wasm",
      "add",
      "2",
      "3",
    ])
    == Ok("5")
}

/// A divide-by-zero is reported as a trap (exit non-zero in `main`); the reason carries the
/// spec trap kind (`i32.div_u` by zero — WebAssembly spec §4.3.2 `idiv_u`).
pub fn cli_run_trap_test() {
  let assert Error(msg) =
    scribbler.run(["run", corpus <> "/intops.wasm", "divu", "10", "0"])
  assert string.contains(msg, "trap")
  assert string.contains(msg, "int_div_by_zero")
}

// ─────────────────────────────── per-stage subcommands ───────────────────────────────

/// `decode <in.wasm>` dumps the WASM AST — the coarsest inspection surface (no validation).
pub fn cli_decode_test() {
  let assert Ok(text) = scribbler.run(["decode", corpus <> "/add.wasm"])
  assert string.contains(text, "Module(")
}

/// `validate <in.wasm>` accepts a well-typed module.
pub fn cli_validate_test() {
  assert scribbler.run(["validate", corpus <> "/fib.wasm"]) == Ok("valid")
}

/// `to-ir <in.wasm>` prints carder's `.ir` — the whole scribbler half of the compiler, end to
/// end. Everything it prints is carder's input.
pub fn cli_to_ir_test() {
  let assert Ok(text) = scribbler.run(["to-ir", corpus <> "/add.wasm"])
  assert string.contains(text, "module @")
  assert string.contains(text, "i.add.32")
}

/// `lower` and `ir` are documented ALIASES of `to-ir`: the three spellings print the identical
/// `.ir` for the same input (the alias arm cannot drift into a different lowering).
pub fn cli_to_ir_aliases_test() {
  let wasm = corpus <> "/add.wasm"
  let assert Ok(canonical) = scribbler.run(["to-ir", wasm])
  assert scribbler.run(["lower", wasm]) == Ok(canonical)
  assert scribbler.run(["ir", wasm]) == Ok(canonical)
}

/// `to-core <in.wasm>` drives the full source→Core path (frontend lower → carder's `ir_lower` →
/// `optimize` → `emit_core`) and prints `.core` text for the compiled module.
pub fn cli_to_core_test() {
  let assert Ok(text) = scribbler.run(["to-core", corpus <> "/add.wasm"])
  assert string.contains(text, "module 'carder@wasm@add'")
}

// ─────────────────────────────── `build` (the .wasm → .beam verb) ───────────────────────────────

/// `build <in.wasm> <out.beam>` compiles a `.wasm` to a real `.beam` binary on disk.
pub fn cli_build_writes_beam_test() {
  let out = "build/scribbler_cli_add.beam"
  let assert Ok(msg) = scribbler.run(["build", corpus <> "/add.wasm", out])
  assert string.contains(msg, "wrote")
  let assert Ok(beam) = simplifile.read_bits(out)
  assert beam != <<>>
  let _ = simplifile.delete(out)
}

/// `to-beam` is the documented alias of `build`, and both accept a posture flag: a `.beam` is
/// written under EACH profile (the profile-selecting compile the benchmark path needs). The
/// two builds' spec-correctness is proven by `cli_run_add_test` / `cli_run_unsafe_add_test`,
/// which drive the same two postures end to end; running a prebuilt `.beam` (`exec`) is
/// carder's verb and carder's proof.
pub fn cli_build_both_profiles_test() {
  let wasm = corpus <> "/add.wasm"
  let safe_beam = "build/scribbler_cli_add_safe.beam"
  let unsafe_beam = "build/scribbler_cli_add_unsafe.beam"

  let assert Ok(m1) = scribbler.run(["to-beam", wasm, safe_beam])
  assert string.contains(m1, "wrote")
  let assert Ok(m2) = scribbler.run(["build", "--unsafe", wasm, unsafe_beam])
  assert string.contains(m2, "wrote")

  let assert Ok(safe) = simplifile.read_bits(safe_beam)
  let assert Ok(unsafe) = simplifile.read_bits(unsafe_beam)
  assert safe != <<>>
  assert unsafe != <<>>

  let _ = simplifile.delete(safe_beam)
  let _ = simplifile.delete(unsafe_beam)
}

// ─────────────────────────────── fail-closed dispatch (never panics) ───────────────────────────────

/// `help` (and `--help`/`-h`) print the usage text as `Ok` — exit 0, not an error.
pub fn cli_help_exits_zero_test() {
  let assert Ok(text) = scribbler.run(["help"])
  assert string.contains(text, "Usage")
  assert scribbler.run(["--help"]) == Ok(text)
  assert scribbler.run(["-h"]) == Ok(text)
}

/// No arguments → the usage text as an `Error` (exit non-zero), never a panic.
pub fn cli_usage_on_no_args_test() {
  let assert Error(msg) = scribbler.run([])
  assert string.contains(msg, "Usage")
}

/// An unrecognised subcommand → the usage text as an `Error`.
pub fn cli_usage_on_unknown_command_test() {
  let assert Error(msg) = scribbler.run(["frobnicate", "x"])
  assert string.contains(msg, "Usage")
}

/// A missing input file → a typed read error (`Error`), never a panic.
pub fn cli_missing_file_is_typed_error_test() {
  let assert Error(msg) =
    scribbler.run(["decode", corpus <> "/does_not_exist.wasm"])
  assert string.contains(msg, "read")
}

/// Undecodable input → the decoder's typed rejection under the `"decode: "` stage prefix, never
/// a panic. (`.expected` is a text fixture, not a WebAssembly binary.)
pub fn cli_undecodable_input_is_typed_error_test() {
  let assert Error(msg) = scribbler.run(["decode", corpus <> "/add.expected"])
  assert string.contains(msg, "decode:")
}

/// A non-integer `run` argument → a typed error, never a panic.
pub fn cli_bad_run_argument_test() {
  let assert Error(msg) =
    scribbler.run(["run", corpus <> "/add.wasm", "add", "two", "3"])
  assert string.contains(msg, "not an integer")
}
