<img width="128" src="https://github.com/scarletindustries.png" />

### Scribbler

The WebAssembly frontend for the carder compiler backend.

[Documentation](https://scarlet.industries/docs/scribbler)

---

> this is a large experimental project. no promises made. don't use it in production, it's pretty slow right now (that will be fixed in the future)

scribbler decodes a `.wasm`, validates it and lowers it into [carder](https://github.com/scarletindustries/carder)'s IR, and carder does everything from there down to a running BEAM module.

`wasm -> carder ir -> core erlang -> beam`

### try it

scribbler builds with gleam 1.16 on erlang/otp 29.

```shell
$ gleam run -- run test/scribbler/conformance/corpus/add.wasm add 3 5
8
```

that turns the module below into a `.beam`, loads it and calls its `add` export with 3 and 5:

```webassembly
(module
  (func (export "add") (param i32 i32) (result i32)
    (i32.add (local.get 0) (local.get 1)))
  (func (export "mul") (param i32 i32) (result i32)
    (i32.mul (local.get 0) (local.get 1))))
```

arguments and results are raw unsigned bit patterns, so an i32 `-1` is written `4294967295`. `gleam run -- help` lists the other commands, which dump each stage of the pipeline on its own.

### license

[Apache License 2.0](LICENSE). see [NOTICE](NOTICE) for attribution.
