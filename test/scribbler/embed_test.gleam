//// Tests for `scribbler/embed` — the WASM-BYTES front door of the embedder API.
////
//// The claim this file owns is exactly the frontend half of the seam: **`.wasm` bytes reach the
//// embedder**. `compile` / `compile_named` / `compile_progress` turn guest bytes into a
//// `carder/embed.Compiled` (the SAME type carder's `instantiate` consumes), `compile_named`
//// overrides the generated BEAM module atom, and `compile_progress` reports the frontend's
//// `0/"analyzing"` phase ahead of carder's `20`/`45`.
////
//// Everything BELOW the IR is carder's and is proven in carder's own `embed_test` on IR input:
//// host injection through the `(capability, name, args)` dispatcher, `mem_read`/`mem_write`/
//// `mem_size`/`guest_pid`, and the `to_artifact`/`from_artifact` compile-once cache. Nothing here
//// re-asserts them.

import carder/embed
import gleam/erlang/process
import scribbler/embed as wembed
import simplifile

/// A guest with no imports and no memory — the canonical corpus `add` module.
const add_wasm = "test/scribbler/conformance/corpus/add.wasm"

/// A guest that DOES import (`dance.poke`) and declares a memory — proof the front door is not
/// limited to the trivial shape.
const poke_wasm = "test/scribbler/fixtures/poke.wasm"

/// The embedder's numeric host dispatcher; unused by the fixtures that declare no import.
fn no_host(_capability: String, _name: String, _args: List(Int)) -> List(Int) {
  []
}

/// `compile` turns `.wasm` bytes into a `carder/embed.Compiled` — the annotation below is the
/// type-level half of the claim (a value of scribbler's alias IS carder's type), and handing it
/// straight to `carder/embed.instantiate` + `invoke` is the value-level half: the compiled guest
/// runs and returns the spec-correct `add(3, 5) == 8`.
pub fn embed_compile_wasm_reaches_embedder_test() {
  let assert Ok(wasm) = simplifile.read_bits(add_wasm)
  let result: Result(embed.Compiled, String) = wembed.compile(wasm)
  let assert Ok(compiled) = result

  let assert Ok(instance) = embed.instantiate(compiled, no_host)
  assert embed.invoke(instance, "add", [3, 5]) == Ok([8])
  embed.stop(instance)
}

/// An IMPORT-bearing, memory-declaring guest compiles through the front door too (the embedder's
/// host dispatcher is wired at instantiate time, so nothing about an import stops the compile).
pub fn embed_compile_import_bearing_guest_test() {
  let assert Ok(wasm) = simplifile.read_bits(poke_wasm)
  let result: Result(embed.Compiled, String) = wembed.compile(wasm)
  let assert Ok(_compiled) = result
}

/// `compile` derives the BEAM module atom from the guest's first exported function
/// (`carder@wasm@<firstexport>`), and `compile_named` OVERRIDES it verbatim — the seam an
/// embedder needs to load several guests into one node without atom collisions.
pub fn embed_compile_named_overrides_atom_test() {
  let assert Ok(wasm) = simplifile.read_bits(add_wasm)

  let assert Ok(default) = wembed.compile(wasm)
  assert default.module.name == "carder@wasm@add"

  let assert Ok(renamed) =
    wembed.compile_named(wasm, "carder@wasm@embed_test_renamed")
  assert renamed.module.name == "carder@wasm@embed_test_renamed"

  // The override is the ONLY difference: the renamed guest still runs.
  let assert Ok(instance) = embed.instantiate(renamed, no_host)
  assert embed.invoke(instance, "add", [3, 5]) == Ok([8])
  embed.stop(instance)
}

/// `compile_progress` reports each compiler phase as `(completed_percent, label)` in order, so an
/// embedder can drive a build progress bar. The `0`/`"analyzing"` phase is scribbler's (decode →
/// validate → lower); `20`/`"generating"` and `45`/`"compiling"` are carder's, fired by
/// `carder/embed.compile_ir`. Progress is a side channel — the result is `compile_named`'s.
pub fn embed_compile_progress_reports_phases_test() {
  let assert Ok(wasm) = simplifile.read_bits(add_wasm)
  let events = process.new_subject()

  let assert Ok(compiled) =
    wembed.compile_progress(
      wasm,
      "carder@wasm@embed_test_progress",
      fn(pct, phase) { process.send(events, #(pct, phase)) },
    )
  assert compiled.module.name == "carder@wasm@embed_test_progress"

  assert process.receive(events, 200) == Ok(#(0, "analyzing"))
  assert process.receive(events, 200) == Ok(#(20, "generating"))
  assert process.receive(events, 200) == Ok(#(45, "compiling"))
}
