//// `--bindings`/`--out` PASS-THROUGH from scribbler's CLI (P12-05).
////
//// The claim this file owns is the thin frontend one: **wasm in → the same folder out**. Driving
//// `scribbler.run(["build", "--threaded", "--bindings", "gleam", "--out", <dir>, "<in.wasm>"])`
//// reaches carder's bindings driver from a `.wasm` and lands the `.beam` PLUS its companion
//// binding files in `<dir>`, every returned path really written.
////
//// The bindings driver's own semantics are carder's, proven in carder's
//// `backend/bindings_driver_test` on `.ir` input and never re-asserted here: `parse_langs`'
//// canonical/deduped ordering, the R17 lower-ONCE seam (the module `describe` sees IS the module
//// the `.beam` is generated from), default-off `.beam` byte-identity / non-perturbation, the
//// companion contents equalling `emit_<lang>(describe(m, binding))`, emission determinism, and the
//// R12/R20/P8 rejection matrix (`--bindings` without `--threaded`, a mutable memory tier, an
//// import-bearing module).

import gleam/list
import gleam/string
import scribbler
import simplifile

/// `mem.wasm` — an import-free, memory-mutating corpus module exporting `roundtrip`, so the
/// generated module atom (hence the `.beam` filename) is `carder@wasm@roundtrip`. Threaded +
/// export-only, i.e. an ACCEPTED shape for the bindings emitter.
const wasm = "test/scribbler/conformance/corpus/mem.wasm"

/// The paths named by a successful `build` confirmation line (`"wrote a, b, c"`).
fn wrote_paths(msg: String) -> List(String) {
  let assert Ok(#(_, tail)) = string.split_once(msg, "wrote ")
  string.split(tail, ", ")
}

/// A `.wasm` compiled with `--bindings gleam --out <dir>` lands the `.beam` and its companion
/// binding sources in `<dir>`: every path the CLI reports as written EXISTS and is non-empty, the
/// `.beam` is named after the compiled module atom, and at least one `.gleam` companion sits
/// beside it. That is the whole frontend obligation — the bytes of each file are carder's.
pub fn build_bindings_writes_beam_and_companions_test() {
  let dir = "build/scribbler_bindings_out"
  let _ = simplifile.delete(dir)

  let assert Ok(msg) =
    scribbler.run([
      "build", "--threaded", "--bindings", "gleam", "--out", dir, wasm,
    ])
  let paths = wrote_paths(msg)

  // The `.beam` is written FIRST, named after the module atom the frontend derived.
  let assert [beam_path, ..companions] = paths
  assert beam_path == dir <> "/carder@wasm@roundtrip.beam"
  // At least one Gleam companion accompanies it.
  assert list.any(companions, string.ends_with(_, ".gleam"))

  // Every reported path really exists on disk and carries content.
  list.each(paths, fn(p) {
    let assert Ok(bytes) = simplifile.read_bits(p)
    assert bytes != <<>>
  })

  let _ = simplifile.delete(dir)
}
