# Specification: The WebAssembly Frontend for carder

**Status:** Canonical architecture specification for **scribbler**. The WebAssembly 2.0 fixed-width surface is complete and proven; the frontend was extracted from the single carder repo on 2026-08-16 with the IR contract unchanged. For *what is actually built* see [`01-status.md`](01-status.md), for *what is planned but not built* see [`02-roadmap.md`](02-roadmap.md), for *how phases are scoped & implemented* see [`03-phase-workflow.md`](03-phase-workflow.md), and for the live per-phase ledger see [`state.md`](state.md).
**Audience:** A downstream planning agent and the agent swarm that implements it.
**The backend's specs are the other half of this document:** carder's architecture is [`specs/00-high-level.md`](https://github.com/scarletindustries/carder/blob/main/specs/00-high-level.md) (carder repo), and the complete IR contract scribbler emits against is [`specs/FRONTEND-API.md`](https://github.com/scarletindustries/carder/blob/main/specs/FRONTEND-API.md) (carder repo). When this document and carder's disagree about anything below the IR, carder's wins. When either disagrees with the [WebAssembly spec](https://webassembly.github.io/spec/) about WebAssembly, **the spec wins.**

---

## 1. What scribbler is

**scribbler owns the WebAssembly binary and text formats, and stops at carder's IR.** It decodes a `.wasm` (or parses a `.wat`/`.wast`), proves it well-typed, and lowers it into a `carder/ir.Module`. Everything from the IR down — the policy pass, the optimizer, Core Erlang codegen, the BEAM runtime, the run/invoke ABI, the linker, the shared CLI vocabulary — is carder's, consumed here as an **ordinary Gleam package dependency**.

carder's platform diagram, quoted for context (carder `specs/00-high-level.md` §1):

```
   FRONTENDS (per-language → IR)         SHARED MIDDLE-END            BACKEND          RUNTIME
 ┌───────────────────────────┐
 │ WASM   (scribbler repo)   │─┐      ┌──────────────────┐     ┌──────────────┐   ┌──────────────┐
 │ Rust   (via WASM)         │ ├────▶ │   SHARED IR      │────▶│ IR → Core    │──▶│ shared rt +  │
 │ JS via Porffor (scribbler)│ │      │  + optimizer     │     │ Erlang AST → │   │ optional     │
 │ JS native   (arc repo)    │ │      │  + stdlib/cap    │     │ .core → BEAM │   │ linear-mem   │
 │ Erlang/Gleam (later, own  │─┘      │    lowering      │     └──────────────┘   │ subsystem    │
 │              repo)        │        └──────────────────┘                       └──────────────┘
 └───────────────────────────┘
   ── other repos ──────────▶│◀────────────────── carder ──────────────────────────────────────▶
         each stage is a public, independently-callable interface; the IR has a textual form
```

**scribbler is the top-left box.** That box also transitively carries languages nobody wrote a frontend for:

- **Rust → BEAM**, via any Rust→WASM toolchain (LLVM). Real, though not native-Rust speed.
- **JavaScript → BEAM**, via **Porffor** (an AOT JS/TS→WASM compiler). Porffor's output imports its own runtime ABI rather than WASI, and scribbler supplies that ABI (§4) — which is what makes "any Porffor application runs on the BEAM" true. It is bounded by Porffor itself, not by us. The native JS road is **arc** (`alii/arc`), a different frontend in a different repo.
- **Java → BEAM (experimental)**, via **TeaVM**'s WebAssembly-GC backend, whose host namespaces scribbler supplies the same way.

Three properties hold for everything in this repo, and they are the reason the split is worth its cost:

1. **Nothing below the IR lives here.** No codegen, no runtime, no optimizer. If a bug's fix is below the IR, it is a carder change and a dependency bump.
2. **carder is never vendored, forked, or patched locally**, and this repo never defines a module under `src/carder/` (Gleam hard-errors on a duplicate module path) nor an `.erl` file outside the `scribbler_*_ffi.erl` naming rule (duplicate Erlang module atoms shadow **silently** — the prefix is the only defense). See [`CLAUDE.md`](../CLAUDE.md).
3. **The WebAssembly spec is the authority**, not carder's behavior and not what this code currently does.

---

## 2. The stage graph

```
 .wasm bytes ──decode──┐
                       ├──▶ ast.Module ──validate──▶ TypedModule ──lower──▶ carder/ir.Module
 .wat / .wast text ─wat┘        (+ canon: GC iso-recursive type identity)            │
                                                                                     │
        ┌──────────────────────── scribbler ends here ────────────────────────────────┘
        ▼
 carder:  ir_lower ──▶ ir_opt ──▶ emit_core ──▶ build_beam ──▶ BEAM  (load · instantiate · invoke)
```

Every stage is a public, independently-invokable function with its own error type, and every stage is **total**: untrusted input produces a typed `Error`, never a panic, a `let assert`, or a diverging loop.

| Stage | Module | Owns | Notes |
|---|---|---|---|
| **Decode** | `scribbler/wasm/decode` | `.wasm` bytes → `ast.Module` | Gleam's inherited Erlang bit syntax makes LEB128 and value bytes fall out of pattern matching. The **malformed** boundary for binary input. |
| **WAT / WAST parse** | `scribbler/wasm/wat` | text → the *same* `ast.Module`; a `.wast` → a `Script` of module + command forms | Sits **beside** the decoder and produces the identical AST, so `validate`/`lower` serve text and binary alike. Correctness bar is differential: `parse_module(text)` ≡ `decode(wat2wasm(text))`. The malformed boundary for text; it does **not** typecheck. |
| **AST** | `scribbler/wasm/ast` | the decoded module model | The frontend's own type; carder never sees it. |
| **Canon** | `scribbler/wasm/canon` | iso-recursive type canonicalization (GC `rectype`s) | One canonical id per type index such that `canon[i] == canon[j]` **iff** the types are iso-recursively equivalent — the validator's heap-type matchers compare canonical ids, not declared indices. |
| **Validate** | `scribbler/wasm/validate` | `ast.Module` → `TypedModule` (**the security boundary**) | The spec's abstract stack-typing algorithm. Reads `scribbler/wasm/ast` **only — no dependency on the IR**, so it gates independently of the backend. The `TypedModule` carries exactly the typing facts lowering needs, so lowering never re-derives a type. |
| **Lower** | `scribbler/wasm/lower` | `TypedModule` → `carder/ir.Module` | Two classic frontend jobs in one SSA naming context: **stack elimination** (the operand stack's shape is statically known, so every push becomes a named binding and every pop a value reference — there is no runtime stack) and **structure → named labels (D6)** (WASM's numeric branch *depths* are resolved here; a depth NEVER reaches the IR — `br` to a `loop` → `Continue`, to a `block`/`if` → `Break`, the function frame → `Return`). Mutable WASM locals become loop-carried params / extra block results. An *imported* `ref.func` lowers to the distinct `RefFuncImport` node carder's adapter expects. |
| **Pipeline** | `scribbler/pipeline` | stage wiring + error composition (D4) | `.wasm` in, a BEAM result out. Composes the three frontend errors and wraps every carder failure as `Backend(_)`, rendering all four with the same stage prefixes the single-repo CLI printed — a diagnostic is byte-identical to before the split. |
| **CLI** | `scribbler` | `decode`, `validate`, `to-ir` (= `lower`/`ir`), `to-core`, `run`, `build`, `help` | Argument parsing, file IO, printing. Every subcommand is total: bad input goes to stderr and halts non-zero. carder's `.ir`-level verbs (`ir-lower`, `opt`, `emit`, `to-erl`, `exec`) are in **carder's** binary, not this one. |
| **Embed** | `scribbler/embed` | `.wasm` bytes → `carder/embed.Compiled` | Only the wasm→IR half. Everything from the IR down — chunking, `instantiate`/`invoke`/`stop`, `mem_read`/`mem_write`, the artifact cache — is used **directly** from `carder/embed`; this module deliberately re-exports none of it (except the `Compiled` type alias, which is literally the same type). |

**The one build-time posture field the frontend reads** is `binding.narrow_carried` (it selects the liveness narrowing in `lower.lower_with`). No other stage branches on a `Binding` axis: postures are threaded unchanged into carder, and an incoherent posture is a *linker* rejection surfaced by `carder/cli.resolve_binding` **before** any stage runs.

**The run/invoke ABI is carder's, and fixed (D5/T8).** Arguments and results are **raw unsigned bit patterns as Erlang integers** — an i32 in `[0, 2^32)`, an i64 in `[0, 2^64)`, a float as its raw IEEE-754 bit pattern (never a BEAM double). A **trap** is a runtime outcome (`Trapped`); an **uncaught WebAssembly exception** is a *distinct* outcome (`UncaughtException`) — `assert_exception` ≠ `assert_trap`. Neither is a compile error.

---

## 3. The frontend/backend boundary

scribbler touches a small, deliberate slice of carder's public API. This list *is* the coupling — anything not on it is not ours to call, and anything missing from it is a carder roadmap item, never a local patch.

| carder API | scribbler uses it for |
|---|---|
| `carder/ir` (+ `carder/ir/printer`, `parser`) | the module we build; printing `.ir` for the `to-ir` verb and for IR freezes |
| `carder/pipeline` — `lower_ir`, `optimize_ir`, `ir_to_cmod`, `cmod_to_beam`, `compile_ir`, `run_ir`, `run_ir_chunked`, `ir_to_chunks`, `instantiate*`, `invoke_instance*`, `host_output`, `classify_run_error` | driving the backend from the IR seam; the conformance `Driver` sequences exactly these |
| `carder/embed` — `compile_ir`, `instantiate`, `instantiate_with_providers`, `invoke`, `stop`, `mem_read`/`mem_write`, `to_artifact`/`from_artifact` | the embedder story (`scribbler/embed` is only the bytes→IR half) |
| `carder/runtime/link` — `Provider`, **`Namespace`**, `link_imports`, `link_func_imports`, `call_import` | supplying host namespaces (§4) and proving `assert_unlinkable` fail-closed |
| `carder/runtime/profiles` — `safe`, `unsafe`, `portable`, `ceiling`, `engine`, `direct`, `compose`, `link` | postures; the conformance matrix's binding points |
| `carder/runtime/instance` — `Binding`, `MemTier`, `TableTier`, `state_strategy` | threading a posture through the frontend unchanged |
| `carder/cli` — the axis flags, `resolve_binding`, `with_binding`, `link_gate`, `parse_args`/`format_values`/`format_uncaught`, file IO | the CLI, **imported not forked**: `resolve_binding` is the fail-closed `Binding → Instance` security gate, and a copy here could drift into admitting a posture the gate exists to refuse |
| `carder/backend/{build_beam, beam_link, bindings, core_erlang}` | the `build` verb's `--link` and `--bindings <langs> --out <dir>` output paths |

**Where the seam is drawn, and why there.** Validation is the last stage that is purely about WebAssembly; lowering is the first stage that mentions carder. That is exactly the seam: WASM *typing* facts never cross it (carder has no notion of an abstract operand stack or a branch depth), and BEAM facts never cross back (scribbler has no notion of a `letrec` continuation, a trust tier's module name, or a Core Erlang atom). The IR's textual form makes the seam auditable — a `wasm → .ir` dump is a complete, diffable statement of everything scribbler decided, and it is the unit in which a bug report crosses between the repos.

---

## 4. Host namespaces — how a wasm producer's runtime gets supplied

A real-world `.wasm` almost never stands alone: it imports an environment. **carder hard-codes no host module by name** — it resolves an import `#(module, name)` only against the providers its caller handed it, and fails closed otherwise. Supplying those providers is scribbler's job, because the environment is a property of the *producer toolchain*, which is a wasm fact.

| Namespace module | Supplies | Why it exists |
|---|---|---|
| `scribbler/host/spectest` | the spec suite's reference host module `spectest` — 4 immutable globals, a funcref table, a memory, 7 `print*` functions | the official `.wast` scripts cannot link without it. **Not ambient any more**: a harness must pass `spectest.provider()` explicitly, or every `(import "spectest" …)` becomes an unowned namespace — a harness bug, not a spec outcome |
| `scribbler/host/teavm` | TeaVM's `teavmJso`, `wasm:js-string`, `teavmMemory`, `teavmDate`, `teavm`, plus the imported `env.memory` and layout globals | in a browser these come from the generated `*.wasm-runtime.js`; on the BEAM they come from here |
| `scribbler/porffor/host` | Porffor's runtime intrinsics, imported from the **empty module name `""`** under single-letter idents (`a`=print, `b`=printChar, `c`=time, `d`=timeOrigin) | Porffor's ABI is its own, not WASI. The letter is the stable identity; the function index is not (the assembler re-orders indices but preserves idents) |

Two mechanics make this safe, and make it work for reference types:

- **`link.Provider.Namespace(link_name, func, state)`** hands carder a *resolver*, not a table of names carder knows. The resolver returns a term-native `ProvidedFunc(sig, closure)`, matched against the declared import type by **equality** (spec §3.2.7) — so a resolver that builds its `ProvidedFunc` from the type it was handed matches by construction, and the handler's fate is the handler's, not the linker's. This is what lets **reference-typed** imports (`externref` string handles, GC refs) work at all: carder's `rt_host` capability seam is a *numeric* ABI (`List(Int) -> List(Int)`) and cannot carry a term.
- **No ambient authority (D3a).** Every dispatch target is a first-class closure written in this repo and applied directly; carder reads `#(module, name)` only to *select* among the providers it was given, never to `apply/3` a data-derived module/function atom. Installing `providers()` **is** the grant — these imports are therefore not additionally `HostPolicy`-gated, and omitting the provider is a fail-closed link error, not a silent degradation. Each namespace keeps its **signature face** (`func_type`, used for fail-closed link matching) and its **dispatch face** (`handler`) as literal `case`s in lock-step, so an unknown name is `Error` in both.

A guest whose imports are ordinary scalar `(import "cap" "name" (func …))` needs none of this: it uses carder's plain host dispatcher. Namespaces are for environments carder has deliberately never heard of.

---

## 5. The conformance suite

The **entire** official WebAssembly spec-test suite lives here (`test/scribbler/conformance/**`), together with the wabt / wast2json / vendored-testsuite CI block. It is the frontend's reason for existing at the scale it does: it is what turns "we implement WebAssembly" into a number.

**Vendoring is pinned and self-checking.** `vendor/PIN` fixes the testsuite SHA, the wabt version, the wasm-tools version (the GC lane — wabt 1.0.41's WAT parser cannot tokenize GC instructions, upstream issue #2530), and the reference-engine version. `vendor/ALLOWLIST` names the `.wast` files the compiled slice is expected to drive, with an optional per-file flag column passed verbatim to `wast2json`. `vendor/vendor.sh` clones at the SHA, converts each allowlisted file, and **requires `spectest-interp` to report N/N before the fixtures are trusted** — a mismatched fixture set fails at vendor time, not in the runner. The full normalised fixture set is gitignored (it is large); a curated subset is committed so `gleam test` runs without re-vendoring. Bumping any PIN line is a deliberate, reviewed change: the baked-in expected values are only trustworthy against a known suite revision.

**The harness is a handful of small pieces, each independently testable:**

| Piece | Role |
|---|---|
| `fixture` | wast2json JSON → typed `Command`/`Action`/`SpecValue`. The spec files carry their own expected values, so this needs **no compiler and no reference engine**. Every numeric value is a JSON *string* holding the decimal of the unsigned bit pattern; a NaN expectation carries a **class**, never a pattern |
| `wat_fixture` | the same, for `.wast` files parsed by **our own** WAT parser, entering the pipeline at `validate` — so files `wast2json` cannot convert at the pin still run, from our parser, through the identical chain |
| `registry` | the current / `$name` / `register` link-name bindings a `.wast` builds up, so a multi-module file's invokes bind to the module the spec says they do |
| `driver` | sequences carder's public stages (decode → validate → lower → link → emit → compile+load → `instantiate/0` vs `instantiate/1` → invoke) and adapts each stage's error into the runner's channel. It **re-implements nothing** |
| `runner` + `oracle` | drives commands, partitioned by type, and judges results. `assert_invalid`/`assert_malformed` exercise the **frontend only** (a typed `Error`, never an instantiation); `assert_return`/`assert_trap`/`assert_exception` exercise the **full pipeline**. The oracle is the single place a result is judged: **exact unsigned bit-pattern equality** for concrete values (so `-0.0` and `+0.0` are correctly distinct) and **NaN by class, never by bit-equality** |
| `reference/wasmtime` | a Tier-B reference engine for authored / random inputs, where no baked-in expected value exists |

**Honest coverage is a design rule, not a disclaimer (D9).** A module the frontend rejects turns its dependent assertions into **counted skips with reasons**; an unhandled command is a counted skip; a text module the parser cannot take is a counted skip. Skips are visible in the report, never silent, and never a pass. `fail == 0` is meaningful precisely because of that discipline.

**The suite is also carder's differential.** It runs under both optimizer profiles (Safe / Baseline + enforcing fuel, and Unsafe / Aggressive) and across the shipped `(state_strategy × mem_tier [× table_tier])` matrix, all of which must produce identical outcomes — WebAssembly is deterministic (its only non-determinism, NaN payload bits, is pinned as raw patterns by D5), so a divergence is a genuine bug on one of the two sides. A tier regression, an optimizer-soundness break, or a dropped threaded state record in carder shows up **here** first. That is why the suite stayed whole in the move rather than being split.

**Baseline (pre-split, measured on the single repo up to 2026-08-16):** **47,734 pass / 683 skip / 0 fail**, Safe ≡ Unsafe, every `state_strategy × mem_tier`. Re-measure on the split tree; the number is scribbler's to carry now.

---

## 6. Non-goals

- **Nothing below the IR, ever.** No Core Erlang, no BEAM runtime, no optimizer pass, no trust tier, no `.beam` linking logic in this repo. A fix below the seam is a carder change plus a dependency bump — never a local patch, never a vendored copy, never a `src/carder/` module here.
- **No other source language.** JavaScript-the-language is arc's; scribbler carries only JS that arrived *as WebAssembly* (Porffor), and Java only as TeaVM's wasm output.
- **WASM threads / shared memory** is a hard non-goal of the platform: every memory tier is process-local by design, which conflicts with shared mutable memory. Single-threaded across all tiers and modes.
- **WASI is not core.** If it is ever wanted it is one more `link.Provider.Namespace` beside `spectest`/TeaVM/Porffor — an additive module here, not a change to carder. The browser DOM is out of scope entirely.
- **We do not judge WebAssembly by carder's behavior.** Where the spec and our output disagree, the code is wrong. Tests are written against the spec, never against whatever the implementation currently prints.

---

## 7. Summary for the next agent

scribbler is the **WebAssembly frontend** for the carder compiler backend, in Gleam, on the BEAM. It owns the wasm binary and text formats — `decode`, `wat`, `canon`, `validate`, `lower` — and stops at `carder/ir.Module`; carder owns the IR and everything below it and is consumed as an ordinary Gleam dependency. Validation is the security boundary (untrusted bytes in, a typed rejection out, never a panic); lowering does stack elimination and resolves WASM's numeric branch depths into the IR's **named** labels, so no wasm-ism reaches the IR. Postures are threaded, not interpreted: the only build-time field the frontend reads is `narrow_carried`, and the fail-closed `Binding → Instance` gate is **imported** from `carder/cli`, never forked. A wasm producer's runtime environment — the spec suite's `spectest`, TeaVM's namespaces, Porffor's `""` intrinsics — is supplied from here as a `link.Provider.Namespace` of first-class closures, because carder hard-codes no host module by name. The official spec-test suite lives here in full: pinned, self-checking vendoring; an allowlist; a harness whose oracle judges by exact bit pattern and NaN *class*; honest counted skips; and a matrix run that doubles as carder's optimizer and tier differential — pre-split baseline **47,734 / 683 / 0**, re-measure on the split tree. The rule that makes all of it hold: **nothing below the IR lives here, and no wasm knowledge lives in carder.**
