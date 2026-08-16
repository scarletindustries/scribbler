<img width="128" src="https://github.com/scarletindustries.png" />

### Scribbler

The WebAssembly frontend for the carder compiler backend.

[Documentation](https://scarlet.industries)

---

> this is a large experimental project. the mass majority of the code was written by claude. no promises made. definitely don't use it in anything production as it's pretty slow right now (that will be fixed in the future)

scribbler is the wasm half of what used to be one repo. it owns the WebAssembly binary and text formats: it decodes a `.wasm`, validates it, and lowers it into [carder](https://github.com/scarletindustries/carder)'s IR. that's where scribbler stops. carder owns everything from the IR down — the optimiser, Core Erlang codegen, the BEAM runtime, the run ABI — and scribbler consumes it as an ordinary Gleam package dependency.

the split is the same shape as the `arc` JS frontend's relationship to carder: a frontend produces carder IR, and carder turns that IR into a running BEAM module. there is no wasm code left in carder any more, and there is no backend code here.

### how?
`wasm -> carder ir -> core erlang -> beam`

### let me try it

there is a pretty big corpus of wasm files scattered across the code for testing if you don't have one to hand. for example,
give this a try:

```shell
$ gleam run -- run test/scribbler/conformance/corpus/add.wasm add 3 5
8
```

this command is the "all in one", it'll take the wasm, convert it to the ir, hand that to carder, which turns it into core erlang, compiles it to beam, then loads that module and runs it.
the WAT for this file is as follows:

```webassembly
;; add(i32,i32) — direct numeric op, params, export, end-to-end plumbing.
;; mul exercises i32 two's-complement WRAP through codegen (i32.mul is mod 2^32).
(module
  (func (export "add") (param i32 i32) (result i32)
    (i32.add (local.get 0) (local.get 1)))
  (func (export "mul") (param i32 i32) (result i32)
    (i32.mul (local.get 0) (local.get 1))))
```

(so we're calling the add export with params 3 and 5 for the two i32's)

arguments and results are raw unsigned bit patterns, not signed numbers — an i32 `-1` is written `4294967295` going in, and comes back out the same way.

you can also print out each stage of the pipeline. it's all modular. run `gleam run -- help` to see all the commands (e.g. dump the ir, dump the .core, just export to .beam)

### license

scribbler is licensed under the [Apache License 2.0](LICENSE). you're free to use, modify, and distribute it — including in commercial and closed-source products — provided you keep the license and attribution notices intact. the Apache license also carries an explicit patent grant. see [LICENSE](LICENSE) and [NOTICE](NOTICE) for the full terms.
