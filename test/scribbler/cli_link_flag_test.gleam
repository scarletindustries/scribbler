//// CLI tests for the `--link` flag on scribbler's `build` verb (P11-04, R13/O5).
////
//// They drive the subcommand dispatcher (`scribbler.run/1`) exactly as `main` does, proving the
//// two claims scribbler owns for `--link`:
////
////   - **scope (R13)** — `--link` is recognized ONLY on `build`/`to-beam`. On every other
////     scribbler verb it is rejected fail-closed, short-circuiting BEFORE any file IO, so the flag
////     can never silently no-op;
////   - **the positive path (O5)** — `build --link` on an import-free tier-P `.wasm` writes ONE
////     SELF-CONTAINED `.beam`, and loading + invoking that artifact (with no further compilation)
////     returns the spec-correct value.
////
//// The `--link` SEMANTICS themselves — `resolve_binding`'s composition, default-off byte-identity
//// with the non-linked pipeline, and the link gate's tier-N / import-bearing refusals — are
//// carder's, proven in carder's `cli_link_flag_test` / `link_gate_test` on `.ir` input. Nothing
//// here re-asserts them; this file only proves the flag reaches carder from a `.wasm`.

import carder/pipeline
import gleam/string
import scribbler
import simplifile

const corpus = "test/scribbler/conformance/corpus"

// ═══════════════════════ 1. `--link` is scoped to `build` (R13) ═══════════════════════

/// R13: on every scribbler verb OTHER than `build`/`to-beam`, a `--link` token is rejected
/// fail-closed with a diagnostic naming the flag — before any file IO (note the paths below are
/// never read). `--link` cannot silently no-op on a verb that produces no artifact to link into.
pub fn link_flag_rejected_on_non_build_verbs_test() {
  let assert Error(m1) =
    scribbler.run(["to-core", "--link", corpus <> "/add.wasm"])
  assert string.contains(m1, "--link")
  let assert Error(m2) =
    scribbler.run(["run", "--link", corpus <> "/add.wasm", "add", "2", "3"])
  assert string.contains(m2, "--link")
}

// ═══════════════════════ 2. the positive `--link` path (O5) ═══════════════════════

/// O5: `build --unsafe --link <in.wasm> <out.beam>` writes ONE self-contained `.beam` from a
/// simple import-free tier-P module, and that artifact RUNS: `pipeline.exec_beam` reads the module
/// atom baked into the `.beam`, loads + instantiates it in an owned process and invokes the export
/// — no compiler in the loop — returning the spec-correct `add(2, 3) == 5` (corpus `add.expected`).
///
/// **Why `--unsafe` (MeterOff) and not the default Safe binding:** the Safe pipeline inserts fuel
/// metering (`ir_lower` → `charge` → `rt_meter`), whose closure reaches
/// `gleam@dynamic@decode:decode_int/1` via a fun-capture; the linker rewrites that capture to a
/// local mangled call but does not pull the capture's target DEF into the merge, so a linked Safe
/// build traps `undef` on the first `charge`. That is a carder linker-reachability gap, not a CLI
/// defect. `--unsafe` sets `MeterOff` (no `charge` emitted), keeping this a genuine import-free
/// tier-P (`Paged`) linked build that exercises the whole CLI `--link` path.
pub fn linked_build_smoke_test() {
  let linked = "build/scribbler_link_smoke_add.beam"

  let assert Ok(msg) =
    scribbler.run([
      "build",
      "--unsafe",
      "--link",
      corpus <> "/add.wasm",
      linked,
    ])
  assert string.contains(msg, "wrote")
  let assert Ok(beam) = simplifile.read_bits(linked)
  assert beam != <<>>

  // The written artifact is self-contained: load + instantiate + invoke it directly.
  let assert Ok(#(_micros, outcome)) =
    pipeline.exec_beam(beam, "add", [2, 3], 1)
  assert outcome == pipeline.Returned([5])

  let _ = simplifile.delete(linked)
}
