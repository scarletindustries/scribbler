//// The scribbler **CLI** — the WebAssembly frontend's own binary. `gleam run -- <subcommand> …`
//// dispatches here.
////
//// scribbler is a compiler FRONTEND. It owns the WebAssembly binary format (`scribbler/wasm/*` —
//// decode, validate, canon, lower, wat) and nothing below the IR: every stage past
//// `carder/ir.Module` — the policy pass, the optimizer, Core Erlang codegen, the BEAM runtime,
//// the run-ABI — lives in the `carder` package and is consumed from here as an ordinary Gleam
//// dependency. So every verb below takes a `.wasm` and stops at, or drives straight through, that
//// one seam. carder's own `.ir`-level verbs (`ir-lower`, `opt`, `emit`, `to-erl`, `exec`) are in
//// the **carder** binary, not this one.
////
//// The stage wiring and per-stage error mapping (D4) live in `scribbler/pipeline`, and the shared
//// axis-flag / value-convention / file-IO vocabulary in `carder/cli` (which carder's own CLI
//// imports too, so the posture flags can never drift between binaries). This module only does
//// argument parsing, file IO, and printing. Every subcommand is total: bad input prints its typed
//// error to **stderr** and the process halts **non-zero** (`halt(1)`) — it never panics.
////
//// ## Subcommands
////
//// | Subcommand                                     | Pipeline                                  |
//// |------------------------------------------------|-------------------------------------------|
//// | `decode   <in.wasm>`                           | decode → dump the WASM AST                |
//// | `validate <in.wasm>`                           | decode → validate → print `valid`         |
//// | `to-ir    <in.wasm>` (= `lower`, `ir`)         | decode → validate → lower → print `.ir`   |
//// | `to-core  [axes] <in.wasm>`                    | … → ir_lower → optimize → emit → `.core`  |
//// | `run      [axes] <in.wasm> <export> <args…>`   | … → load → instantiate → invoke → print   |
//// | `build    [axes] <in.wasm> [<out.beam>]`       | … → `compile:forms` → write `.beam`       |
//// | `help`                                         | print the usage text                      |
////
//// ## Axis flags (`carder/cli`)
////
//// The compile verbs accept the orthogonal axis flags documented by `cli.axes_usage()`; the
//// default is the fail-closed **Safe / `Cell` / `Paged`** posture (leaving it requires NAMING a
//// flag). `cli.resolve_binding` composes them into one coherent `Binding` and validates it
//// through `profiles.link/1` (the sole `Binding → Instance` seam), so an incoherent posture
//// (`Safe` + `nif` memory, or an uncapped `atomics`/`ceiling` build) is rejected fail-closed
//// (exit non-zero), never silently downgraded. That parser is IMPORTED, never forked: a copy here
//// could drift into admitting a posture the gate exists to refuse.
////
//// `build`/`to-beam` additionally honor `--link` (merge the runtime closure into one
//// self-contained `.beam`) and `--bindings <langs> --out <dir>` (emit typed host-language
//// companion sources next to the `.beam`); every other verb refuses those fail-closed.
////
//// ## Value convention (the run/invoke ABI — `carder/cli`)
////
//// `run` arguments and results are **raw UNSIGNED bit patterns in decimal**: an i32 in
//// `[0, 2^32)`, an i64 in `[0, 2^64)`, a float as its raw IEEE-754 bits (D5). So
//// `gleam run -- run add.wasm add 2 3` prints `5`, and an i32 `-1` argument is written
//// `4294967295`. A trap prints `trap: <reason>` to stderr and halts non-zero — a trap is a runtime
//// outcome, surfaced as a CLI failure; an uncaught WebAssembly exception is reported distinctly
//// (T8).

import argv
import carder/backend/beam_link
import carder/backend/bindings
import carder/backend/build_beam
import carder/backend/core_erlang
import carder/cli
import carder/ir
import carder/ir/printer as ir_printer
import carder/pipeline as backend
import carder/runtime/instance.{type Binding}
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import scribbler/pipeline
import scribbler/wasm/decode
import scribbler/wasm/validate

/// CLI entry point. Reads the subcommand + operands from `argv`, runs the matching stage, and
/// prints the result to stdout (exit 0) or the typed error to stderr (exit non-zero). Never
/// panics on bad input.
pub fn main() -> Nil {
  case run(argv.load().arguments) {
    Ok(out) -> io.println(out)
    Error(msg) -> {
      io.println_error(msg)
      halt(1)
    }
  }
}

/// `erlang:halt/1` — stop the VM with exit status `code`. Used to make a failing subcommand exit
/// non-zero. Never returns (typed generically so the caller's `case` arms unify).
@external(erlang, "erlang", "halt")
fn halt(code: Int) -> a

/// Dispatch a parsed argument vector to its subcommand, returning the text to print on success or
/// the diagnostic to print to stderr on failure. Pure of IO except the file reads/writes each
/// subcommand performs; total — an unrecognised command yields the usage text as `Error`.
///
/// - `args`: the argument vector AFTER the binary name (exactly what `argv.load().arguments`
///   yields), e.g. `["run", "add.wasm", "add", "2", "3"]`.
/// - Returns `Ok(text)` — what `main` prints to stdout before exiting 0 — or `Error(diagnostic)` —
///   what `main` prints to stderr before `halt(1)`. `help`/`--help`/`-h` return the usage text as
///   `Ok` (exit 0); an unknown verb or a wrong operand arity returns it as `Error` (exit non-zero).
///
/// Public so CLI behaviour is unit-testable without spawning a process.
pub fn run(args: List(String)) -> Result(String, String) {
  case args {
    ["help"] | ["--help"] | ["-h"] -> Ok(usage())
    ["decode", path] -> cmd_decode(path)
    ["validate", path] -> cmd_validate(path)
    ["to-ir", path] | ["lower", path] | ["ir", path] -> cmd_to_ir(path)
    ["to-core", ..rest] ->
      cli.with_binding(rest, fn(binding, axes, pos) {
        use <- cli.reject_link(axes.link, "to-core")
        use <- cli.reject_output_flags(axes, "to-core")
        case pos {
          [path] -> cmd_to_core(path, binding)
          _ -> Error(usage())
        }
      })
    ["run", ..rest] ->
      cli.with_binding(rest, fn(binding, axes, pos) {
        use <- cli.reject_link(axes.link, "run")
        use <- cli.reject_output_flags(axes, "run")
        case pos {
          [path, export, ..arg_strs] -> cmd_run(path, export, arg_strs, binding)
          _ -> Error(usage())
        }
      })
    ["build", ..rest] | ["to-beam", ..rest] ->
      cli.with_binding(rest, fn(binding, axes, pos) {
        cmd_build(binding, axes.link, axes.bindings, axes.out, pos)
      })
    ["exec", "-n", n, path, export, ..arg_strs]
    | ["exec", "--repeat", n, path, export, ..arg_strs] ->
      cmd_exec(path, export, arg_strs, n)
    ["exec", path, export, ..arg_strs] -> cmd_exec(path, export, arg_strs, "1")
    _ -> Error(usage())
  }
}

// ─────────────────────────────── inspection verbs (frontend only) ───────────────────────────────

/// `decode <in.wasm>` — decode the binary and dump the WASM AST (`string.inspect`). The
/// coarsest inspection surface: no validation, no lowering, nothing below the IR runs.
///
/// - `path`: the `.wasm` file to read.
/// - Returns `Ok(ast_dump)`, or `Error` — an unreadable path (`cli.read_bits`' wording) or the
///   decoder's typed rejection, rendered by `pipeline.describe` so the `"decode: "` prefix matches
///   every other verb's. Total.
fn cmd_decode(path: String) -> Result(String, String) {
  use bytes <- result.try(cli.read_bits(path))
  case decode.decode(bytes) {
    Ok(m) -> Ok(string.inspect(m))
    Error(e) -> Error(pipeline.describe(pipeline.DecodeFailed(e)))
  }
}

/// `validate <in.wasm>` — decode then `full`-validate. The typed-module gate, driven on its own.
///
/// - `path`: the `.wasm` file to read.
/// - Returns `Ok("valid")` when the module type-checks, else `Error` — the read error, the
///   decoder's rejection, or the validator's typed rejection (rendered by `pipeline.describe`).
///   The typed module itself is discarded; use `to-ir` to see what it lowers to. Total.
fn cmd_validate(path: String) -> Result(String, String) {
  use bytes <- result.try(cli.read_bits(path))
  case decode.decode(bytes) {
    Error(e) -> Error(pipeline.describe(pipeline.DecodeFailed(e)))
    Ok(m) ->
      case validate.validate(m) {
        Error(e) -> Error(pipeline.describe(pipeline.ValidateFailed(e)))
        Ok(_typed) -> Ok("valid")
      }
  }
}

/// `to-ir`/`lower`/`ir <in.wasm>` — decode → validate → frontend-lower → print the `.ir`
/// (`carder/ir/printer`). The whole scribbler half of the compiler, end to end: everything this
/// prints is carder's input.
///
/// Runs the NO-narrowing lowering (`pipeline.source_to_ir`), so the printed `.ir` is the
/// posture-independent module; the compile verbs re-lower under their binding's
/// `narrow_carried`.
///
/// - `path`: the `.wasm` file to read.
/// - Returns `Ok(ir_text)` — valid `.ir` that re-parses — or `Error` (read / decode / validate /
///   lower), rendered by `pipeline.describe`. Total.
fn cmd_to_ir(path: String) -> Result(String, String) {
  use bytes <- result.try(cli.read_bits(path))
  case pipeline.source_to_ir(bytes) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(m) -> Ok(ir_printer.print_module(m))
  }
}

// ─────────────────────────────── compile verbs (frontend + carder) ───────────────────────────────

/// `to-core [axes] <in.wasm>` — the full source→Core path (frontend lower → carder's `ir_lower` →
/// `optimize` → `emit_core`), printed as `.core` text. This is exactly what `build` compiles, in
/// inspectable form: same binding, same stages, same lowered bodies.
///
/// - `path`: the `.wasm` file to read.
/// - `binding`: the resolved build binding (`cli.with_binding` has already validated it through
///   the fail-closed `profiles.link/1` gate).
/// - Returns `Ok(core_text)` or the first failing stage's rendered diagnostic. Total.
fn cmd_to_core(path: String, binding: Binding) -> Result(String, String) {
  use m <- result.try(read_source_ir(path, binding))
  backend.ir_to_core(m, binding)
  |> result.map_error(backend_error)
}

/// `run [axes] <in.wasm> <export> <args…>` — compile the module through the selected posture's
/// pipeline and invoke `export` on the BEAM (`pipeline.run_source`: frontend lower → carder's
/// compile → load → instantiate → invoke, one instance per process).
///
/// - `path`: the `.wasm` file to read. `export`: the exported function name to invoke.
/// - `arg_strs`: the arguments as decimal raw-unsigned-bit-pattern tokens (D5 — an i32 `-1` is
///   `4294967295`); parsed by `cli.parse_args`.
/// - `binding`: the resolved build binding.
/// - Returns `Ok(values)` — the result values as space-separated decimals (`""` for a void
///   export) — or `Error`: a compile-stage diagnostic, `"not an integer argument: …"`, or a
///   RUNTIME outcome surfaced as a failure — `"trap: <reason>"` for a trap, and
///   `cli.format_uncaught`'s tag+payload line for an uncaught WebAssembly exception, which is a
///   DISTINCT outcome from a trap (T8). Total — never panics.
fn cmd_run(
  path: String,
  export: String,
  arg_strs: List(String),
  binding: Binding,
) -> Result(String, String) {
  use bytes <- result.try(cli.read_bits(path))
  use args <- result.try(cli.parse_args(arg_strs))
  case pipeline.run_source(bytes, binding, export, args) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(backend.Returned(values)) -> Ok(cli.format_values(values))
    Ok(backend.Trapped(reason)) -> Error("trap: " <> reason)
    Ok(backend.UncaughtException(tag_id, payload)) ->
      Error(cli.format_uncaught(tag_id, payload))
  }
}

/// `build|to-beam [axes] [--link] [--bindings <langs> --out <dir>] <in.wasm> [<out.beam>]` —
/// compile a `.wasm` to a `.beam` under the selected posture, optionally merging the runtime
/// closure into a self-contained artifact (`--link`) and/or emitting typed companion
/// host-language bindings (`--bindings` + `--out`). Prints a confirmation line.
///
/// Branches on `#(out, positionals)` — the two positional forms are mutually exclusive:
/// - **FILE** (`out == None`): `<in.wasm>` alone (the `.beam` path is derived by swapping the
///   extension) or `<in.wasm> <out.beam>`. `--bindings` here is an error (it needs the `--out`
///   folder to write the companions into).
/// - **FOLDER** (`out == Some(dir)`, one positional `<in.wasm>`): compile+emit into `dir` — lower
///   ONCE (R17), write `<dir>/<module-atom>.beam` + one companion file per requested language.
///   Two-or-more positionals is an error (the `.beam` name derives from the module atom
///   `carder@wasm@<base>`, not from a positional).
///
/// `--bindings` requires `--threaded` (the default `Cell` binding has no typed-binding surface —
/// `describe` rejects it with the R12 "re-run with `--threaded`" hint). Composes with `--link` on
/// both paths.
///
/// - `binding`: the resolved build binding.
/// - `link`: the `--link` bit — merge the runtime closure into one self-contained `.beam`.
/// - `langs`: the `--bindings` selection (canonical/deduped; `[]` = none).
/// - `out`: the `--out <dir>` folder (`None` = the FILE form).
/// - `positionals`: the verb's positional operands.
/// - Returns `Ok("wrote …")` or a rendered diagnostic; a wrong positional arity yields the usage
///   text as `Error`. Total.
fn cmd_build(
  binding: Binding,
  link: Bool,
  langs: List(bindings.BindingLang),
  out: Option(String),
  positionals: List(String),
) -> Result(String, String) {
  case out, positionals {
    None, [input] ->
      case langs {
        [] -> file_to_beam(input, default_beam(input), binding, link)
        _ -> Error(bindings_needs_out())
      }
    None, [input, output] ->
      case langs {
        [] -> file_to_beam(input, output, binding, link)
        _ -> Error(bindings_needs_out())
      }
    None, _ -> Error(usage())
    Some(dir), [input] -> folder_to_beam(input, dir, binding, link, langs)
    Some(_), _ ->
      Error(
        "with --out, pass only <in.wasm>; the .beam name derives from the module atom (carder@wasm@<base>.beam)",
      )
  }
}

/// The diagnostic for `--bindings` without `--out` — the companion binding files need a folder to
/// be written into, so the flag pair is only meaningful together (fail-closed: `--bindings` can
/// never silently no-op).
fn bindings_needs_out() -> String {
  "--bindings requires --out <dir> (the companion binding files are written into a folder alongside the .beam)"
}

/// The FILE `build` path — `read → source_to_ir_with → ir_to_cmod → cmod_to_beam → write` (or,
/// under `--link`, the fail-closed `cli.link_gate` then `build_beam.link_beam` merge).
///
/// - `input`: the `.wasm` source path. `output`: the `.beam` path to write.
/// - `binding`: the resolved build binding. `link`: the `--link` bit.
/// - Returns `Ok("wrote <output>")`, or the rendered diagnostic of the first failing stage — a
///   read/write IO error, a frontend/backend stage error, or (under `--link`) the link gate's
///   refusal (tier-N / import-bearing) or the linker's typed error. Fail-closed: a refused
///   `--link` build writes NOTHING. Total.
fn file_to_beam(
  input: String,
  output: String,
  binding: Binding,
  link: Bool,
) -> Result(String, String) {
  use m <- result.try(read_source_ir(input, binding))
  case link {
    False ->
      case backend.ir_to_cmod(m, binding) {
        Error(e) -> Error(backend_error(e))
        Ok(cmod) ->
          case backend.cmod_to_beam(cmod) {
            Error(e) -> Error(backend_error(e))
            Ok(beam) -> cli.write_beam(output, beam)
          }
      }
    True ->
      case cli.link_gate(binding, m) {
        Error(ge) -> Error(cli.describe_link_gate_error(ge))
        Ok(Nil) ->
          case backend.ir_to_cmod(m, binding) {
            Error(e) -> Error(backend_error(e))
            Ok(cmod) ->
              case build_beam.link_beam(cmod) {
                Error(le) -> Error(beam_link.describe_error(le))
                Ok(#(_atom, beam)) -> cli.write_beam(output, beam)
              }
          }
      }
  }
}

/// The FOLDER `build` path (P12-05): compile `<input>` into `<dir>`, emitting the `.beam` + one
/// typed companion binding per requested language. The R17 lower-ONCE seam is the crux —
/// `backend.ir_to_lowered_cmod` lowers+optimizes ONCE and returns BOTH the module and its
/// `CModule`; the SAME lowered module is handed to `bindings.emit_bindings` (which runs
/// `iface.describe` over it) while its `CModule` becomes the `.beam`. So `describe` and the
/// `.beam` ABI see identical bodies — a mutation-carrying export cannot be misclassified pure
/// (dropping `St'`). Fail-closed: a rejected module (Cell / import-bearing / mutable-tier) writes
/// NOTHING (describe runs before any IO); a link-gate/link failure surfaces before emit.
///
/// - `input`: the `.wasm` source path.
/// - `dir`: the `--out` output folder (created if absent).
/// - `binding`: the resolved build binding (must be Threaded + Paged/TablePaged for `--bindings`).
/// - `link`: the `--link` bit — merge the runtime closure into the emitted `.beam`.
/// - `langs`: the requested target languages (`[]` = write only the `.beam`, no describe/emit).
/// - Returns `Ok("wrote <paths…>")` — the `.beam` first, then each binding file — or the first
///   failing stage's rendered diagnostic. Total.
fn folder_to_beam(
  input: String,
  dir: String,
  binding: Binding,
  link: Bool,
  langs: List(bindings.BindingLang),
) -> Result(String, String) {
  use m <- result.try(read_source_ir(input, binding))
  // R17: lower + optimize ONCE; the returned `lowered` module is exactly what the `CModule` (hence
  // the `.beam`) is generated from, and it is what `emit_bindings` runs `describe` over.
  use #(lowered, cmod) <- result.try(
    backend.ir_to_lowered_cmod(m, binding)
    |> result.map_error(backend_error),
  )
  use beam <- result.try(beam_of_lowered(cmod, lowered, binding, link))
  case bindings.emit_bindings(lowered, binding, beam, dir, langs) {
    Error(be) -> Error(bindings.describe_error(be))
    Ok(paths) -> Ok("wrote " <> string.join(paths, ", "))
  }
}

/// Compile the lowered `CModule` into the `.beam` bytes for the FOLDER path, honoring `--link`.
/// With `link == False` it is a plain `cmod_to_beam`; with `link == True` it runs the fail-closed
/// `cli.link_gate` (tier-N / import-bearing) then merges the runtime closure via
/// `build_beam.link_beam`.
///
/// - `cmod`: the emitted Core module (its `.name` is the atom baked into the `.beam`).
/// - `mod`: the SAME lowered module `describe` sees — its `.imports` drive the link gate.
/// - `binding`: the resolved build binding (its `mem_tier` drives the link gate).
/// - `link`: the `--link` bit.
/// - Returns `Ok(beam_bytes)` (nothing is written here — the caller does the IO) or the rendered
///   CLI diagnostic. Total.
fn beam_of_lowered(
  cmod: core_erlang.CModule,
  mod: ir.Module,
  binding: Binding,
  link: Bool,
) -> Result(BitArray, String) {
  case link {
    False ->
      backend.cmod_to_beam(cmod)
      |> result.map_error(backend_error)
    True ->
      case cli.link_gate(binding, mod) {
        Error(ge) -> Error(cli.describe_link_gate_error(ge))
        Ok(Nil) ->
          case build_beam.link_beam(cmod) {
            Error(le) -> Error(beam_link.describe_error(le))
            Ok(#(_atom, beam)) -> Ok(beam)
          }
      }
  }
}

// ─────────────────────────────── helpers ───────────────────────────────

/// Read `<path>` and drive the frontend stages (decode → validate → lower) into carder's IR under
/// `binding` — the shared front half of every compile verb. `binding.narrow_carried` is the ONE
/// build-time field the frontend reads (it selects the liveness narrowing in `lower.lower_with`),
/// so the module handed to carder matches the posture the rest of the verb compiles under.
///
/// - `path`: the `.wasm` file to read. `binding`: the resolved build binding.
/// - Returns `Ok(module)` or the rendered read/decode/validate/lower diagnostic. Total.
fn read_source_ir(path: String, binding: Binding) -> Result(ir.Module, String) {
  use bytes <- result.try(cli.read_bits(path))
  pipeline.source_to_ir_with(bytes, binding.narrow_carried)
  |> result.map_error(pipeline.describe)
}

/// Render a carder-side `PipelineError` for stderr by routing it through the frontend's
/// `pipeline.describe` (whose `Backend` arm delegates straight to `carder/pipeline.describe`).
/// Going through the ONE describe keeps every diagnostic this binary prints — frontend stage or
/// backend stage — worded by a single function. Total; diagnostic text only.
fn backend_error(e: backend.PipelineError) -> String {
  pipeline.describe(pipeline.Backend(e))
}

/// Default `.beam` output path for the FILE `build` form: swap a trailing `.wasm` for `.beam`,
/// else append `.beam` (so a extensionless input still yields a distinct output path). Total.
fn default_beam(input: String) -> String {
  case string.ends_with(input, ".wasm") {
    True -> string.drop_end(input, 5) <> ".beam"
    False -> input <> ".beam"
  }
}

/// `exec [-n COUNT] <in.beam> <export> <args…>` — load a PREBUILT `.beam` (produced by `build`,
/// so NO compile step runs here) and invoke `export` on the BEAM `COUNT` times, timing only the
/// invocations. Prints the (last) result value(s) then a timing line; a trap prints
/// `trap: <reason>` (exit non-zero) and an uncaught exception its tag + payload, distinctly (T8).
///
/// carder exposes the same verb over the same `carder/pipeline.exec_beam` implementation — this
/// is not a fork, just the second front door, so scribbler can benchmark the artifacts it
/// produced (`smoke/bench.sh` drives `build` then `exec -n`) without a carder checkout on PATH.
///
/// - `path`: a `.beam` file. `export`/`arg_strs`: as `run` (raw unsigned bit patterns, D5).
/// - `count_str`: the repeat count; must parse as a positive integer, else `Error`.
fn cmd_exec(
  path: String,
  export: String,
  arg_strs: List(String),
  count_str: String,
) -> Result(String, String) {
  use beam <- result.try(cli.read_bits(path))
  use args <- result.try(cli.parse_args(arg_strs))
  use repeat <- result.try(parse_count(count_str))
  case backend.exec_beam(beam, export, args, repeat) {
    Error(e) -> Error(e)
    Ok(#(_micros, backend.Trapped(reason))) -> Error("trap: " <> reason)
    Ok(#(_micros, backend.UncaughtException(tag_id, payload))) ->
      Error(cli.format_uncaught(tag_id, payload))
    Ok(#(micros, backend.Returned(values))) ->
      Ok(cli.format_values(values) <> "\n" <> timing_line(repeat, micros))
  }
}

/// Render the `exec` benchmark timing: total microseconds and nanoseconds-per-call.
fn timing_line(repeat: Int, micros: Int) -> String {
  let ns_per = micros * 1000 / repeat
  int.to_string(repeat)
  <> " call(s) · "
  <> int.to_string(micros)
  <> " us total · "
  <> int.to_string(ns_per)
  <> " ns/call"
}

/// Parse the `exec -n` repeat count — a positive integer. `Error` names the bad token.
fn parse_count(s: String) -> Result(Int, String) {
  case int.parse(s) {
    Ok(n) if n >= 1 -> Ok(n)
    _ -> Error("-n expects a positive integer, got: " <> s)
  }
}

/// The usage text — printed by `help` (exit 0) and on an unrecognised invocation (stderr, exit
/// non-zero). The `[axes]` block comes from `cli.axes_usage()` so it can never drift from the one
/// flag parser carder and every frontend CLI share.
fn usage() -> String {
  string.join(
    [
      "scribbler — WebAssembly → carder IR → BEAM. Usage:",
      "  gleam run -- decode   <in.wasm>                 dump the WASM AST",
      "  gleam run -- validate <in.wasm>                 full-validate; print 'valid'",
      "  gleam run -- to-ir    <in.wasm>                 source → .ir (aliases: lower, ir)",
      "  gleam run -- to-core  [axes] <in.wasm>          source → ir_lower + optimize + emit_core → .core",
      "  gleam run -- run      [axes] <in.wasm> <export> <args…>  compile + invoke on the BEAM",
      "  gleam run -- build    [axes] [--link] <in.wasm> [<out.beam>]  compile → .beam (alias: to-beam)",
      "  gleam run -- build    [axes] --bindings <langs> --out <dir> <in.wasm>  + typed host bindings",
      "  gleam run -- exec     [-n N] <in.beam> <export> <args…>  invoke a prebuilt .beam (bench, no compile)",
      "  gleam run -- help                               print this text",
      "",
      "  scribbler is a FRONTEND for the carder compiler backend: it owns the WebAssembly binary",
      "  format and lowers it into carder's shared IR. Everything below the IR — the optimizer,",
      "  Core Erlang codegen, the BEAM runtime — is carder's, and carder's own .ir-level verbs",
      "  (ir-lower, opt, emit, to-erl) live in the carder binary, not this one.",
      "",
      cli.axes_usage(),
    ],
    "\n",
  )
}
