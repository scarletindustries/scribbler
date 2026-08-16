# Where we are today

> The single "current state" reference for **scribbler — the WebAssembly frontend**. For the
> architecture & vision read [`00-high-level.md`](00-high-level.md); for what's *not* built read
> [`02-roadmap.md`](02-roadmap.md); for how phases are scoped & implemented read
> [`03-phase-workflow.md`](03-phase-workflow.md); for the live work ledger read [`state.md`](state.md).
> The backend half of every claim below lives in the **carder** repo — its ledger is
> [carder `specs/01-status.md`](https://github.com/scarletindustries/carder/blob/main/specs/01-status.md),
> and the interface scribbler compiles against is
> [`FRONTEND-API.md`](https://github.com/scarletindustries/carder/blob/main/specs/FRONTEND-API.md).
>
> **Last consolidated:** 2026-07-04, after Phase 10 (in the carder tree). **Split into this repo:**
> 2026-08-16 (below).

> **The split — 2026-08-16.** Phases 1–15 were all built in a single repo, `carder`, which carried the
> compiler backend *and* the WebAssembly frontend *and* the official spec-test suite. On 2026-08-16 the
> frontend was extracted into **this repo**. Nothing about the compiler changed — it was a relocation
> along a seam (`carder/ir`) that was already a file format with a parser on both sides.
>
> - **scribbler (this repo) owns** the WebAssembly binary & text formats and everything up to the IR:
>   `scribbler/wasm/{ast,decode,validate,canon,lower,wat}`, the wasm-entry pipeline
>   (`scribbler/pipeline`) and embedder front door (`scribbler/embed`), the wasm CLI, the
>   wasm-producer host shims (`scribbler/host/spectest`, `scribbler/host/teavm`,
>   `scribbler/porffor/*`), and the **entire** official WebAssembly spec-test conformance suite (§9).
> - **carder owns** everything below the IR: the shared IR itself, the middle-end (policy pass +
>   optimizer), Core Erlang codegen, the whole-program linker, the BEAM runtime, the embedder API and
>   the shared CLI vocabulary. scribbler depends on it as an ordinary Gleam package
>   (`carder = { git = "…/carder.git", ref = "main" }`; `gleam.toml.git-dep` is the committed form —
>   a local `path =` override is a dev-only edit).
> - **arc** (`alii/arc`, JavaScript) is the precedent: a frontend in its own repo, no JS in carder.
>
> Two consequences worth knowing before reading further: **(1)** carder no longer hard-codes any host
> module by name — `spectest`, TeaVM's `teavmJso` and Porffor's `""` intrinsics are supplied from
> **here**, as `carder/runtime/link.Provider.Namespace` values (§9); **(2)** the wabt / `wast2json` /
> vendored-testsuite CI block moved here wholesale, and its absence from carder's CI is the proof the
> extraction was clean.

---

## 1. One-paragraph summary

scribbler is a **working** WebAssembly frontend: it decodes and fully validates untrusted `.wasm`
(and parses `.wat`), then lowers into carder's shared, language-neutral IR — from which carder emits
**Core Erlang**, so the result runs **compiled and preemptively on the BEAM**, not interpreted. It
covers the **complete WebAssembly 2.0 fixed-width surface** (WASM 1.0 + reference types + bulk memory
+ multiple memories + memory64 + SIMD + cross-module function linking + exception handling + tail
calls + cross-module funcref-in-`elem` init), and it **reaches the JS-on-the-BEAM goal**: real
Porffor-compiled JavaScript runs on the BEAM byte-identically to `porf run`.

Everything from the IR down — the two named modes (**Safe** sandbox / **Unsafe** near-native), the
**trust-tier ladder** (tier-P/O/N), the trust-neutral memory optimizer, `--link` self-contained
output and `--bindings` typed host bindings — is **carder's**, reached from here through the shared
axis flags (§7) and described in
[carder's ledger](https://github.com/scarletindustries/carder/blob/main/specs/01-status.md) §4–§6.
scribbler's job is to hand carder an `ir.Module` that means exactly what the WebAssembly spec says it
means, and to prove that against the official suite.

**Live metrics (authoritative, from `gleam test` on `main`):**

| | |
|---|---|
| WASM spec conformance | **47,734 pass / 683 skip / 0 fail** — identical under Safe **and** Unsafe, and `fail=0` under every shipped `(state_strategy × mem_tier)` combo. *Provenance:* measured 2026-07-04 at the Phase-14/15 close, on the combined pre-split tree, at the pinned toolchain (testsuite `193e551f`, wabt 1.0.41, wasmtime 46.0.1). The suite moved into this repo **unchanged** — re-run it here to confirm the triple reproduces (§9) |
| JS-on-BEAM (Porffor 0.61.13 → carder → BEAM) | **52 pass / 0 fail / 3 skip** over a 55-program corpus (all 3 skips are Porffor's own `-0`/closure bugs, reproduced byte-for-byte — they bound Porffor, not this pipeline) |
| Gleam tests | **re-measure on the split tree** — scribbler keeps the frontend + conformance share (roughly 44%); the backend tests stayed with carder. Historical baseline, whole (pre-split) tree: **2,111 pass / 0 fail** at the Phase-15 close (2026-07-04), **2,221 pass / 0 fail** immediately before the split (2026-08-16) |
| Build | `gleam build` **zero warnings**, `gleam format --check src test` clean |
| Every skip | categorized (never false-green); `fail=0` is an absolute invariant |

---

## 2. The pipeline, as built

scribbler's pipeline **ends at the IR**. Everything to the right of that seam is carder's, consumed
as a package (its stages are shown collapsed here; the full backend diagram is
[carder §2](https://github.com/scarletindustries/carder/blob/main/specs/01-status.md)):

```
 SOURCE                    FRONTEND (this repo)                       SHARED IR              ── carder (a package dependency) ──
 .wasm  ─┐              ┌ decode ─┐                                  ┌───────────┐    ┌ ir_lower → ir_opt → emit_core → build_beam ┐
 .wat   ─┼──▶ scribbler ┤ wat     ├─▶ validate ─▶ canon ─▶ lower ───▶│ ir.gleam  │───▶│  + beam_link (--link), bindings (--bindings)│──▶ .beam
 (Porffor JS→.wasm)     └ (text)  ┘   (security)   (types)           │ (ANF, D6) │    └ runtime: rt_num/rt_mem/rt_table/rt_host/…  ┘
 (TeaVM Java→.wasm)                                                  └───────────┘        ▲
                                                                       ▲ .ir text         │ host imports supplied from HERE as
                                                                       └ carder's         └ link.Provider.Namespace values:
                                                                         printer/parser     spectest · teavmJso · Porffor's ""
```

Every arrow is an independently-invokable stage with a CLI verb (§7). The IR is the seam, and it has
a canonical, round-trippable `.ir` textual form (carder's `ir/printer.gleam` + `ir/parser.gleam`) —
which is why the split cost nothing: a `.wasm` compiled through this repo and a `.ir` compiled
straight through carder produce **the same bytes**. **`emit_core` is the single binding chokepoint**
(D3b) and lives in carder; scribbler never touches it.

---

## 3. What each phase delivered (condensed history)

All fifteen phases are **done and proven**. This is the compacted ledger; the per-phase decision
codes (`D/E/F/G/H/I/J/M/N/O/P/Q` and the `R/S/T` reconciliations) now live in the code and tests, with the
*permanent* ones lifted into [`03-phase-workflow.md`](03-phase-workflow.md) §4.

Every phase below happened **in the carder repo, before the 2026-08-16 split**. The **Owner** column
names which repo the delivered code lives in *today*: rows marked `carder` — and the backend half of a
`both` row — are **retained here for context**, because that work happened and reading it is what
makes the frontend rows legible; their code, tests and live numbers are in
[carder](https://github.com/scarletindustries/carder). Cross-repo section references are marked.

| Phase | Owner today | Delivered | Proven at close |
|---|---|---|---|
| **1 — Core platform** | both | The keystones: the language-neutral IR + `.ir` textual form; the Core-Erlang AST + pretty-printer + `build_beam` FFI driver; the WASM decoder *(→ scribbler)*; `rt_num` (90-fn tier-P numeric-fidelity reference); `full` WASM validation + stack-elim/SSA lowering *(→ scribbler)*; `emit_core`; `ir_lower` + the Safe profile + the per-stage CLI. Real `.wasm` → BEAM end-to-end (add/sum_to/fib), 100k-iter tail loop in constant space. | Acceptance corpus green; spec runner 1699/1400/0 |
| **2 — Complete WASM 1.0** | both | Linear memory (`rt_mem` `paged` + `rebuild` oracle), tables + `call_indirect` (3-fault fail-closed), mutable globals, full floats/conversions, and **mutable instance state** via the tier-O **`cell`** (process-dictionary) strategy. `load→instantiate→invoke` run-ABI; Safe max-pages cap. *(The WASM-1.0 decode/validate/lower surface → scribbler; every runtime layer named here → carder.)* | ~509 tests; conformance image refreshed |
| **3 — "Fast"** | carder | The shared IR optimizer `ir_opt` (`baseline` both-modes + `aggressive` Unsafe-only: const-fold/prop/DCE/inline), the **Unsafe** profile (passthrough stdlib, open BIF gate, no metering), and **enforcing** CPU fuel (`FuelExhausted`). B3 monomorphization (Safe.beam ≠ Unsafe.beam). Honest benchmark: Safe was **~76× slower** than hand-written Erlang → motivated Phase 4. | 674 tests; 15,747/411/0 under both modes |
| **4 — "Free-standing"** | carder | The **trust-tier ladder**: tier-P **`threaded`** state (a purely-functional instance record — the runs-anywhere build, 0 native + 0 pdict), tier-O memory (`atomics` O(1)) + tables (`ets`/`atomics`), tier-N memory (`nif` interface + skeleton, Safe-forbidden). `link/1` as the sole validated Binding→Instance seam. | 906 tests; `fail=0` for every `(strategy × tier)` |
| **5 — "The complete WASM engine"** | both | The full standardized surface **minus SIMD**: reference types (funcref/externref, `rt_ref` forge-proof values), bulk memory/table ops, multiple memories, **memory64 decode+validate only**, non-function imports + the `spectest` host *(→ scribbler, now a `link.Provider.Namespace`)* + `link.gleam` fail-closed instantiation, and a first-class **WAT text parser** *(→ scribbler)*. First IR growth since Phase 2, kept language-neutral & byte-identical by default. | 1195 tests; pass **+5,776** → 21,525/1,257/0 |
| **6 — "Complete WASM 2.0"** | both | The three Phase-5 deferrals: **SIMD** (`rt_simd`, ~236 lane ops emulated bit-exact lane-wise — faithful, not hardware, no speed claim), the **memory64 runtime** (i64 addressing, documented 2³²-page/256-TiB cap), and **cross-module wasm→wasm function linking** (`CallImport` node dispatching through a build-constructed closure capability — never `erlang:apply`). *(Runtime + IR → carder; the SIMD/memory64 decode+validate surface → scribbler.)* | 1491 tests; pass **+25,004** → 46,529/1,768/0 (largest movement in project history: the 59 `simd_*.wast` lit up) |
| **7 — "JS on the BEAM via Porffor"** | both | **WASM exception handling** lowered to BEAM-native `try/catch/raise` (`rt_exn`, both legacy & modern encodings → one neutral inline-handler IR) *(→ carder)*, the **Porffor-ABI host shim** (4 build-fixed intrinsics) *(→ scribbler: `scribbler/porffor/*`, supplied as a `link.Namespace` provider; carder keeps only the generic `rt_host` capability boundary)*, and a **JS-subset conformance harness** judged differentially vs `porf run` *(→ scribbler)*. Reached the platform's original goal — bounded & measured by Porffor's ~⅓-of-ECMA coverage. | 1690 tests; JS 52/0/3; EH 153 asserts ×3 profiles |
| **8 — Native JS IR (arc frontend track)** | carder | The **second road to JS-on-BEAM**: a BEAM-native value layer in the IR (term construction, native closures `MakeClosure`/`CallClosure`, maps/objects, the term↔numeric boxing bridge, the `rt_js` fail-closed boundary, guarded native arithmetic) so a from-scratch JS frontend (reusing arc's parser + scope analysis) can emit carder IR directly — making closures/GC/maps/bignums *native* and bypassing Porffor's closure wall. IR value-layer units shipped; the frontend + real `rt_js` are the **arc repo's** deliverable per [carder `FRONTEND-API.md`](https://github.com/scarletindustries/carder/blob/main/specs/FRONTEND-API.md). *(Not tracked in the old `state.md`; kept in project memory.)* | ~1734 tests; WASM byte-identical |
| **9 — The memory optimizer** | carder | The middle-end memory-dataflow passes (deferred all the way from Phase 3): **MemorySSA + linear-memory alias analysis** (`mem_ssa`), **store→load forwarding + redundant-load elimination** (`mem_forward`), **dead-store elimination** (`mem_dse`). Trap-preserving ⇒ trust-neutral ⇒ run at Baseline ⇒ every tier & both modes win. No new IR nodes, no runtime touch. | 1783 tests; ~3–4× faster on paged |
| **10 — The memory optimizer, completed** | carder | The three Phase-9 deferrals: **LICM** (hoist pure loop-invariant work to a preheader), **cross-control-flow MemorySSA** (forwarding/RLE/DSE survive `If`/`Block`/`Switch` via a may-clobber gate), and **range-based bounds-check elimination via loop versioning** (an unchecked fast loop guarded by a runtime range-proof, else the checked slow loop — values *and* traps preserved). First memory opt since Phase 4 to grow the runtime ABI (unchecked access, paged+atomics; nif stays checked). | **1827 tests**; LICM ~3.5×, BCE ~1.1× on paged |
| **11 — Self-contained output (`--link`)** | carder | A **whole-program Core-Erlang linker** behind an optional `--link` flag on the build verb (`beam_link.link_program` over the `cerl` FFI `carder_linker_ffi.erl`, pinned OTP 29): acquire every `carder@`/`gleam@`/FFI closure member's Core (`beam_lib` `debug_info(core_v1)`), reachability-DCE from the exports **+ `instantiate/N`** across calls/applies/**`fun M:F/A` captures**, mangle to local `'M__F'/A`, rewrite all in-closure remotes/captures to local, deterministic `from_core` → **one self-contained `.beam` that runs on a bare OTP node**. tier-P/O only (tier-N/import-bearing/`on_load` are fail-closed link-time rejections); **D3a preserved**; default output **byte-identical**. Reached from here as `build --link` (carder §5). | **1922 tests**; linked ≡ non-linked (bit/trap-identical) over corpus × mode × state × tier P/O, in-process **and** on an actually-booted bare `erl`; deterministic (link-twice byte-identical) |
| **12 — Typed host-language bindings (`--bindings`)** | carder | Alongside the `.beam`, emit **companion typed source files** (`.gleam`/`.erl`/`.ex`) giving a native-typed API over a compiled module: one language-neutral **`Iface` descriptor** (`iface.describe` on the lowered+optimized module) rendered by three sibling emitters + the `--bindings <langs> --out <dir>` folder driver. Value ABI: i32/i64 ⇄ signed `Int`, f32/f64 ⇄ a `Finite\|NonFinite` sum type (NaN/±Inf bit-exact), v128 ⇄ 16-byte binary, refs ⇄ opaque handle, multi-value ⇄ tuple, trap ⇄ `Result`/tagged-tuple caught structurally on `{wasm_trap,_}`. Two-shape API (Stateless pure file vs Threaded pure-value `Instance`). The `.beam` is **unchanged** & default output **byte-identical**; composes with `--link`. Reached from here as `build --bindings` (carder §5). | **1978 tests**; every binding **compiled by its real toolchain** (`gleam build`/`erlc`/`elixirc`) and **called**, bit-identical to the in-process oracle across the full type matrix + threaded state + a genuine trap; determinism byte-checked; conformance unchanged 46,529/1,768/0 |
| **13 — WebAssembly tail calls (`return_call`/`return_call_indirect`)** | both | The tail-call proposal (`0x12`/`0x13`) end to end — decode + WAT + validate (result-type-equality rule, stack-polymorphic like `return`) *(→ scribbler)* + `Return`-shape bottom-transfer lowering + `emit_core` *(→ carder)* — lowered to **genuine constant-stack BEAM tail calls**: direct reuses the `KReturn` tail path; **indirect** goes through a new `rt_table.call_indirect_lookup` seam (the 3 ordered fail-closed guards, returning the target) then **tail-applies** the package-ABI target, D3a-clean; imports reuse the import path under `KReturn` (value-correct, **bounded frame** — not a cross-module constant-stack claim, Q8). The funcref stored closure became **package-ABI + tail-transparent**, so funcref/`elem` modules are **result-identical**; non-funcref output stays **byte-identical**. No new trap, no optimizer/tier/state change. §9. | **2049 tests**; official `return_call.wast`+`return_call_indirect.wast` driven green (**+117** pass → 46,646/1,771/0); constant stack proven to **1,000,000** (direct + mutual + indirect, both table tiers); `OptNone ≡ Baseline ≡ Aggressive` + result-identical across every combo; the 2 `return_call`-blocked legacy EH files now **convert** (driving-green deferred on a deeper non-tail-call scope — measured, R16) |
| **14 — Cross-module funcref-in-`elem`-segment init** | both | `ref.func` of an **imported** function (the new `RefFuncImport(slot, ty)` IR distinction, produced by the `lower_call`-style import-split *(→ scribbler)*, a **pure barrier** in the optimizer) made a table-storable, `call_indirect`-able funcref that dispatches through the D3a import capability — an inline **adapter closure** capturing only the literal slot integer, routing `link.call_import(rt_state.func_import_at(slot), args)` (Cell) / threading `St` unchanged (Threaded), **never** `erlang:apply` on table data *(→ carder)*. Import-bearing detection became **one public predicate** (`emit_core.needs_func_imports`, extended to scan element segments) that the driver **delegates to**, so `instantiate/0`↔`instantiate/1` can't desync (R3). A module with no imported `ref.func` compiles **byte-identically**; modules driving the new surface are **result-identical** across `OptNone ≡ Baseline ≡ Aggressive` and the full state/tier matrix. §9. | **2080 tests**; flips the project's once-largest residual — `table_copy.wast` **569/~1,080 → 1,649/0/0** — for a headline **+1,088** pass → **47,734/683/0**; authored `corpus/xlink` backstop driven e2e across Cell/Threaded × `TablePaged`/`TableEts`/`TableAtomics` (`via_ci == direct`, cross-combo bit-identical, 3 ordered guards); D3a + arity-lockstep re-run green; audits tightened (`"UnknownFunction"`/`"call_indirect_table"` removed measure-then-remove, ceiling 1,900→750, pass floor 47,700 added) |
| **15 — Production tier-N C NIF for linear memory** | carder | Filled the Phase-4 paged-delegating `rt_mem_nif` skeleton with a **real `erl_nif` C backend** (`c_src/carder_rt_mem_nif.c`) over a **reserved raw byte buffer** via an ERTS resource — the raw O(1) native memory ceiling; **bit-identical to the paged reference for every access** + identical traps (the corpus-wide `cell_nif` tier differential is the proof). The C bounds-check (overflow-safe guarded subtractions, memory64-safe via `enif_get_uint64`) is the **fuzz-tested security boundary**. Adds the `*_unchecked` tier-N fast path. **Native-when-loaded, paged-delegate-otherwise** (MF3). Unsafe-only, Safe-forbidden, un-`--link`-able (O8). Default tier-P/O output **byte-identical**, conformance **unchanged**. Reached from here as `--tier nif` (carder §4/§5). | **2111 tests** (`+31`: the `nif_ping` build proof + gate categorization, the per-op `nif ≡ paged ≡ oracle` differential, the `emit_unchecked` flip, the C-bounds security fuzz incl. memory64 vectors, the native `cell_nif` matrix, the four Safe-forbidden re-assertions); conformance **47,734/683/0** unchanged; measured `nif` column in carder's `docs/phase-4-benchmark.md` with the **honest ceiling, no hero number** (tier-N does NOT reach hand-written Erlang) |

---

## 4–6. Runtime surface, deployment model, optimizer — carder's (cross-repo)

Deliberately not restated here, so the two ledgers cannot drift. In
[carder `specs/01-status.md`](https://github.com/scarletindustries/carder/blob/main/specs/01-status.md):

- **§4 — the runtime surface**: the Safe/Unsafe mode axis and the tier-P/O/N trust ladder
  (`rt_mem` paged / `rt_mem_atomics` / the tier-N C NIF; `rt_table[_ets|_atomics]`; `rt_state`
  `cell`/`threaded`), and the fail-closed capability boundary `rt_host` + `link`. What matters
  **here** is that carder names **no** host module: scribbler supplies them (§9).
- **§5 — the deployment model**: emitted modules are thin and call a resident shared runtime; `--link`
  merges the runtime closure into one self-contained `.beam` for a bare OTP node; `--bindings` emits
  typed `.gleam`/`.erl`/`.ex` companions. Both are reachable from scribbler's `build` verb (§7).
- **§6 — the optimizer** (`ir_opt`): Baseline (trust-neutral, trap-preserving, incl. the MemorySSA
  memory passes, LICM and BCE) and Aggressive (Unsafe-only). It runs on the IR, so scribbler gets
  every pass for free and contributes none.

The frontend-facing contract for all of this — the value model, the calling convention, every IR node
a frontend may emit — is
[`FRONTEND-API.md`](https://github.com/scarletindustries/carder/blob/main/specs/FRONTEND-API.md).

---

## 7. CLI (every stage is independently invokable)

`gleam run -- <verb>`. **Every verb takes a `.wasm`** (or `.wat` where noted) and either stops at the
IR seam or drives straight through it into carder:

| Verb | Pipeline |
|---|---|
| `decode   <in.wasm>` | decode → dump the WASM AST |
| `validate <in.wasm>` | decode → validate → print `valid` |
| `to-ir    <in.wasm>` (aliases `lower`, `ir`) | decode → validate → lower → print `.ir` |
| `to-core  [axes] <in.wasm>` | … → ir_lower → optimize → emit_core → `.core` |
| `run      [axes] <in.wasm> <export> <args…>` | … → load → instantiate → invoke → print |
| `build    [axes] [--link] <in.wasm> [<out.beam>]` | … → `compile:forms` → write `.beam` (alias `to-beam`) |
| `build    [axes] --bindings <langs> --out <dir> <in.wasm>` | + typed host-language companion sources |
| `help` | print the usage text |

**The build verb is simply `build`** — pre-split it was `to-beam-wasm` in the combined binary, to
distinguish it from the `.core`-input `to-beam`; with the two binaries separated there is nothing to
disambiguate. carder's own `.ir`-level verbs — `ir-lower`, `opt`, `emit`, `to-erl`, `exec`, and its
`.ir`-input `to-beam` — live in the **carder** binary
([carder §7](https://github.com/scarletindustries/carder/blob/main/specs/01-status.md)), not this one;
`to-ir` is the handoff between them (`scribbler … to-ir m.wasm > m.ir`, then any carder verb).

**Axis flags are carder's, imported not forked.** `carder/cli` owns the vocabulary
(`cli.axes_usage()` prints the block; `cli.resolve_binding` composes the flags into one coherent
`Binding` and validates it through `profiles.link/1`, the sole `Binding → Instance` seam). scribbler
**imports** that module: a copy here could drift into admitting a posture the gate exists to refuse.

- base (one of): `--unsafe` | `--portable` | `--ceiling` | `--engine`
- `--threaded`, `--tier paged|atomics|nif`, `--table-tier paged|ets|atomics`, `--cap PAGES`
- `--trust-memory` (skip bounds checks on all memory-0 access for a trusted guest), `--inline-joins`
- build verbs only: `--link`, `--bindings <langs> --out <dir>` (requires `--threaded`)

The default posture is the fail-closed **Safe / `Cell` / `Paged`**; leaving it requires **naming** a
flag, and an incoherent posture (`Safe`+`nif`, an uncapped `atomics`/`ceiling` build) fails closed
(non-zero exit), never silently downgraded. `run` values are **raw unsigned bit patterns in decimal**
(an i32 `-1` is `4294967295`; a float is its raw IEEE bits — D5); a trap prints `trap: <reason>` to
stderr and exits non-zero, and an uncaught WebAssembly exception is reported distinctly (T8).

Example: `gleam run -- run test/scribbler/conformance/corpus/add.wasm add 3 5` → `8`.

---

## 8. Source-tree map

```
src/scribbler.gleam                       CLI dispatch (arg parsing + file IO only) — wasm-entry verbs
src/scribbler/pipeline.gleam              the wasm-entry driver: .wasm bytes in, a BEAM result out;
                                          per-stage error mapping (D4) over carder/pipeline
src/scribbler/embed.gleam                 the WASM-BYTES front door of the embedder API:
                                          .wasm in, a carder/embed.Compiled out
src/scribbler/wasm/decode.gleam           untrusted .wasm bytes → AST
src/scribbler/wasm/wat.gleam              WASM text-format frontend (lexer + parse_module/parse_script)
src/scribbler/wasm/validate.gleam         full WASM validation — the security boundary
src/scribbler/wasm/canon.gleam            iso-recursive type canonicalization (GC proposal)
src/scribbler/wasm/lower.gleam            validated WASM → carder's shared IR (stack-elim/SSA)
src/scribbler/wasm/ast.gleam              the decoded WASM module model
src/scribbler/host/spectest.gleam         the spec suite's reference host module `spectest`, as a
                                          carder link.Provider.Namespace
src/scribbler/host/teavm.gleam            the TeaVM WASM-GC host runtime, as link providers
                                          (experimental)
src/scribbler/porffor/abi.gleam           the pure Porffor (f64, i32) typed-value ABI (J3)
src/scribbler/porffor/host.gleam          Porffor's runtime intrinsics (WASM module ""), as a
                                          link.Namespace provider
src/scribbler/porffor/run.gleam           the JS-on-BEAM run path: a Porffor .wasm in, its console
                                          output + decoded completion value out
```

There are **no `.erl` FFI shims in `src/`** — every FFI seam this pipeline needs (codegen, runtime
state, refs, exceptions, atomics/ets, the linker, the tier-N NIF) belongs to the runtime and lives in
carder. The two `.erl` files in this repo are **test-only**: `test/carder_conformance_ffi.erl` (the
conformance harness shim) and `test/scribbler_emit_test_ffi.erl`.

```
test/scribbler/wasm/                      decode / validate / lower / wat / canon + GC + tail-call units
test/scribbler/conformance/               THE SPEC SUITE (§9): runner, driver, registry, oracle,
                                          wat_fixture, residual_audit_test, skipcount_test, the
                                          per-proposal conformance tests, corpus/ + fixtures/, and
                                          reference/wasmtime.gleam (the Tier-B engine)
test/scribbler/conformance/vendor/        PIN + ALLOWLIST + vendor.sh — the pinned testsuite SHA and
                                          toolchain versions; the .wast files are gitignored and
                                          regenerated by vendor.sh
test/scribbler/js/                        the JS-on-BEAM lane: corpus, differential vs `porf run`,
                                          report, PIN (PORFFOR_VERSION)
test/scribbler/porffor/                   Porffor ABI / host / profile / e2e units
test/scribbler/teavm/                     TeaVM Java→wasm guests (experimental lane)
test/scribbler/{acceptance,cli,embed,bindings_driver,cli_link_flag,reffunc_import_freeze}_test.gleam
                                          end-to-end verbs, embedder, and the frontend-side proofs
                                          that the carder-owned flags still behave from this binary
```

Docs (measured writeups, kept): `docs/phase-{5,6,13,14}-surface.md` (the WebAssembly surface each
phase added) and `docs/wasm-conformance.svg` (regenerated by `scripts/gen-conformance-svg.sh`). The
backend writeups — `phase-{3,4,9,10}-benchmark.md`, `phase-11-linking.md`, `phase-12-bindings.md`,
`phase-15-tier-n.md` — stayed in the [carder repo](https://github.com/scarletindustries/carder).

---

## 9. Conformance & the categorized residual

The pinned WASM spec suite runs differentially (Tier-A: expected values baked in the `.wast`; Tier-B:
a `wasmtime`/`wast2json`/rebuild-oracle engine), held across the full `(mode × state_strategy ×
mem_tier)` matrix — every combo byte-identical, `fail=0` everywhere. Toolchain pins: testsuite SHA
`193e551f`, wabt 1.0.41, wasm-tools 1.253.0 (the GC lane only — wabt's WAT parser cannot tokenize GC
instructions), wasmtime 46.0.1, Porffor 0.61.13, Node 22 (see
`test/scribbler/conformance/vendor/{vendor.sh,PIN,ALLOWLIST}` and `test/scribbler/js/PIN`). This whole
block — including the CI steps that install wabt and clone the testsuite — moved here in the split;
carder's CI has none of it.

**The host modules are supplied from here.** carder's `runtime/link.Provider` has a `Namespace(link_name,
func, state)` variant precisely so the backend names no host module: `scribbler/host/spectest` supplies
the suite's `spectest` (its globals, `print_i32_f32` and friends), `scribbler/host/teavm` supplies
`teavmJso`, and `scribbler/porffor/host` supplies Porffor's `""` intrinsics. Resolution stays
fail-closed (WASM spec §4.5.4): an unprovided or type-mismatched import is a link error and the
instance is not created — the `assert_unlinkable` cases prove it.

The **683 skips are all categorized** (`residual_audit_test` fails red if any skip matches no
enumerated bucket). Phase 14 flipped the once-largest bucket — `table_copy.wast`'s cross-module
funcref-in-`elem` init — to **fully driven** (1,649/0/0, +1,088 pass), so its
`"UnknownFunction"`/`"call_indirect_table"` phrases are **removed** (a regression re-skipping those goes
red). Phase 13 folded the two official tail-call `.wast` into the driven allowlist, so
`return_call`/`return_call_indirect` are **no longer out-of-scope** — they run green (+117 pass). The
buckets map directly onto [`02-roadmap.md`](02-roadmap.md):

- **cross-module funcref-in-`elem` init** (`table_copy.wast` verifier) — **CLOSED in Phase 14**: `ref.func`
  of an *imported* function placed in a table and reached via `call_indirect` now builds + dispatches
  (the `RefFuncImport` distinction + the D3a import-adapter closure); `table_copy.wast` runs green
  (see `docs/phase-14-surface.md`).
- **~511** — SIMD *text-format* assertions the WAT parser can't read (the binary SIMD path proves them e2e).
- **+3** (Phase 13) — one host-import tail/direct call per tail-call file (`spectest.print_i32_f32`)
  **denied under the deny-all Safe host** (a categorized POLICY denial, not a spec trap — it passes
  under `unsafe`), plus one already-categorized text-format assert.
- **remainder** — genuinely out-of-scope proposals: GC-proposal reftypes, extended-const,
  `assert_exhaustion`. `memory64.wast`/`linking.wast` are file-level WAT-parser parse-skips (the
  features themselves are proven by authored in-scope backstops).

**The JS-on-BEAM lane** (`test/scribbler/js/`) is judged the same way and separately: each program's
Porffor-emitted `.wasm` is run through this pipeline and **differentially compared against `porf run`**
— **52 pass / 0 fail / 3 skip** over 55 programs, the 3 skips being Porffor's own `-0`/closure bugs,
reproduced byte-for-byte. That is what "JS on the BEAM" is proven to mean: bounded by Porffor's
~⅓-of-ECMA coverage, not by this pipeline.

**Provenance and what to re-measure.** The `47,734 / 683 / 0` triple above was measured on the combined
pre-split tree at the Phase-14/15 close (2026-07-04) at exactly these pins. The suite, the allowlist,
the audit and the corpus moved into this repo **unchanged**, and the backend they drive is the same
compiled code consumed as a package — so the expectation is that the triple reproduces verbatim. Run it
here and confirm; `fail=0` is an absolute invariant, and a drift in the *pass* count is a finding
either way.
