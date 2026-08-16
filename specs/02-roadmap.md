# What's planned but not built

> The honest "not-yet" list for **scribbler, the WebAssembly frontend** — everything on the wasm
> surface, in the wasm-producer host shims, or in the spec-test conformance suite that was designed,
> scoped, or explicitly deferred and is still open. Nothing here is a vague wish: each item names
> *what it is*, *why it was deferred*, and *what it needs*. Pick the next phase from this file, scope
> it per [`03-phase-workflow.md`](03-phase-workflow.md), and record it in [`state.md`](state.md).
>
> Companion to [`01-status.md`](01-status.md) (what *is* built) and [`00-high-level.md`](00-high-level.md)
> (the architecture each item serves). **Last consolidated:** 2026-07-06 (in the single repo, after
> Phases 11 & 12 landed and as Phases 13–15 were scoped). **Re-cut for the carder/scribbler split:**
> 2026-08-16.

Rule of the house: **deferrals are categorized, never false-green.** Every item below corresponds to a
real, tested boundary — a categorized conformance skip, a `Memory64Unsupported`-style typed rejection,
a `todo`-free stub, or a documented single-owner gap. `fail=0` holds regardless: a module scribbler
cannot decode, validate or lower turns its dependent assertions into **counted skips with reasons**,
never a silent pass and never a fail.

---

## 0. Where this list came from (the split routing)

scribbler and carder were one repo until 2026-08-16. carder
([`scarletindustries/carder`](https://github.com/scarletindustries/carder)) is now purely the
**backend** — the shared IR, the middle-end, Core Erlang codegen and linking, the BEAM runtime, the
embedder API, the shared CLI vocabulary. scribbler is the **WebAssembly frontend** and owns the entire
official spec-test conformance suite. The old single-repo roadmap split along its existing section
boundaries; the letters are preserved so a cross-reference still lands.

| Section | scribbler owns | carder's half |
|---|---|---|
| **§A Frontends** | the wasm frontend track + the producer-toolchain shims | what the IR/backend must grow to accept a frontend → carder `specs/02-roadmap.md` §A (carder repo) |
| **§B WASM surface (post-2.0)** | **all of it** — decode, validate, lower, the categorized skips | any new IR node / runtime layer a proposal needs → carder §B |
| **§C Cross-module** | the `.wast` coverage that proves it | the IR/link/`--link` seam → carder §C |
| **§D / §D′ Runtime tiers & binding** | — (the tier matrix is *exercised* by the suite, never implemented here) | → carder §D/§D′ |
| **§E Optimizer** | — (the suite is the differential that proves it sound) | → carder §E |
| **§F JS / Porffor measured gaps** | **all of it** (a Porffor guest is a `.wasm`, so it enters here) | — |
| **§G Exception handling** | the 2 legacy EH `.wast` files | the EH lowering fixes → carder §G |
| **§H Tooling & out-of-core** | the WAT parser, the vendoring pipeline, the PIN | WASI's out-of-core posture, native packaging → carder §H |

**A note on the numbers.** The headline **47,734 pass / 683 skip / 0 fail** triple cited below is the
**pre-split historical baseline**, measured on the single repo up to 2026-08-16 (Safe ≡ Unsafe, every
`state_strategy × mem_tier`). It is **scribbler's number now** — the whole wabt / wast2json / vendored
testsuite block moved here with the suite, and carder's CI no longer contains any of it. The gleam-test
count likewise **re-measure on the split tree**; the pre-split figure, both halves together, was
2,111 → 2,221 tests / 0 fail.

**Recently completed — moved out of this list** (see [`01-status.md`](01-status.md)); each landed in the
single repo, so the *frontend* half of each is what scribbler inherited:
- ✅ **Phase 13 — WASM tail calls** (`return_call`/`return_call_indirect`): decode/validate/lower on this
  side, constant-stack BEAM tail calls on carder's; +117 conformance pass, 46,646/1,771/0. *Measurement
  correction (R16): the 2 `return_call`-blocked legacy EH files now **convert** but do **not** run
  green — a deeper non-tail-call scope, deferred in §G.*
- ✅ **Phase 14 — cross-module funcref-in-`elem` init**: the `table_copy.wast` residual **fully flipped
  569/1080 → 1649/0/0**, headline 47,734/683/0, +1,088 pass — the single largest categorized residual,
  CLOSED.
- ✅ **Phase 15 — production tier-N C NIF** (carder's, exercised by this suite's tier matrix; the
  conformance `cell_nif` point still runs the bit-identical paged delegate — see §D).

---

## A. The frontend track (scribbler's own surface)

scribbler is **one frontend among several**, all in their own repos, all emitting `carder/ir.Module`
against carder's [`FRONTEND-API.md`](https://github.com/scarletindustries/carder/blob/main/specs/FRONTEND-API.md)
(carder repo): scribbler for WebAssembly, **arc** (`alii/arc`) for JavaScript, and a possible
Erlang/Gleam frontend later. scribbler never takes another language's work, and never reaches below the
IR.

- **Producer-toolchain coverage is scribbler's, not carder's.** carder no longer hard-codes any host
  module by name, so every wasm *producer's* runtime environment is supplied from here as a
  `link.Provider.Namespace`: the spec suite's `spectest` (`scribbler/host/spectest`), TeaVM's
  `teavmJso`/`wasm:js-string`/`teavmMemory`/`teavmDate`/`teavm` (`scribbler/host/teavm`), and Porffor's
  empty-module `""` intrinsics (`scribbler/porffor/host`). **Open:** any further producer (a WASI-based
  toolchain, Emscripten's environment, a new TeaVM release's import set) is a new namespace module here
  — an additive, well-shaped unit of work, not a compiler change.
- **TeaVM / Java guests (experimental).** The namespace set is shipped; what remains is bounded by the
  **GC surface** (§B) and by measurement — see [`01-status.md`](01-status.md) for exactly what is proven
  end-to-end today. A reference-typed provider that wants to *construct* (rather than pass through) a
  `funcref`/`externref` is blocked on a carder-side gap (carder §D′).
- **Not scribbler's:** the native JS frontend (arc) and an `fe_beam` Erlang/Gleam frontend (its own repo
  when prioritized). Both are listed in carder §A only because carder owes them IR/runtime work.

---

## B. WASM surface (post-2.0 proposals)

WASM 2.0 fixed-width is **complete**. What's left is post-2.0 proposals, each a categorized skip today.
A proposal that needs more than a decoder is a **two-repo job**: the surface here, any new IR node or
runtime layer in carder (carder §B).

- ✅ **Tail-call proposal (`return_call` / `return_call_indirect`).** **Done — Phase 13.** Ingest,
  validation and lowering on this side; carder's `KReturn` tail path and the
  `rt_table.call_indirect_lookup` seam underneath. Funcref/`elem` modules became result-identical.
  *It did NOT run the 2 legacy EH files green — see §G.*
- **GC proposal + GC reference types** (`anyref`, typed function refs, `struct`/`array`/`i31`, `(rec)`
  recursive types). Out of the funcref/externref scope shipped in Phase 5. Porffor confirmed it does
  **not** need GC, so this is spec-completeness, not a JS blocker — but it **is** the ceiling on the
  TeaVM/Java path (§A), and it gates the `try_table` / `tag.wast` EH files, which are blocked on
  `(rec …)` + typed refs, not on an EH gap. Toolchain note: wabt 1.0.41's WAT parser cannot tokenize
  the GC instructions (upstream gap, wabt issue #2530), so the GC lane's fixtures are converted with
  **wasm-tools `json-from-wast`** and driven separately from the main wabt allowlist (see
  `test/scribbler/conformance/vendor/PIN`).
- **Stack-switching**, **the component model**, **relaxed-SIMD**, **extended-const** (arithmetic in
  const-init expressions). All separate proposals, all deferred, all categorized. Extended-const and
  stack-switching are the two that reach carder as well (const-init evaluation at the IR/link seam; a
  codegen/runtime story for switching).

---

## C. Cross-module — the `.wast` coverage

The **IR/link/`--link` seam** is carder's (carder §C). What lives here is the suite that proves it, and
the residuals that suite still reports.

- ✅ **Cross-module funcref-in-elem-segment init.** **Done — Phase 14.** `elem` segments initialized
  with `ref.func` of *imported* functions + `call_indirect`: `table_copy.wast` **fully flipped
  569/1080 → 1649/0/0** — the single largest categorized bucket, CLOSED. The frontend half is the
  `RefFuncImport` distinction produced by the import-split during lowering; the adapter closure and the
  package ABI are carder's.
- **`linking.wast` residuals.** The remaining skips are **parse**-level, not semantic — `(module
  definition)` module-linking and friends, see §H. The runtime features behind them are proven by
  authored backstops.
- **Cross-module EH tags** — the `.wast` files that need a qualified `{module, idx}` tag identity across
  module boundaries. The identity model is carder's; the coverage and the counting are ours (§G).
- **Registry semantics** are already modelled properly (current / `$name` / `register` link-name — see
  `conformance/registry`), so a multi-module file binds its invokes correctly; that is *built*, listed
  here only so nobody re-scopes it.

---

## D / D′ / E. Runtime tiers, bindings, optimizer — carder's

Nothing here is scribbler's to implement, but scribbler is where several of them are **proven**:

- The conformance suite runs the full `(state_strategy × mem_tier [× table_tier])` matrix and both
  optimizer profiles, so a tier regression or an optimizer-soundness break shows up here first.
- **Open, joint:** letting the conformance **`cell_nif`** matrix point run the *real* native tier. It
  currently runs the bit-identical paged delegate, blocked by the keystone probe's `RT_CREATE`-only
  resource type (carder) **plus** this harness's orphan-spawn resource lifecycle (ours). The native tier
  is proven on carder's side by a differential + fuzz + corpus tier differential instead. Fixing the
  harness half without the carder half changes nothing — scope it as a pair.
- Everything else — the tier-N imported-memory native path, `priv/*.so` packaging, B1 runtime-dispatch
  binding, the typed-binding follow-ups, escape analysis, the range solver, pure-call CSE — is
  carder `specs/02-roadmap.md` §D/§D′/§E (carder repo).

---

## F. JS / Porffor path (measured gaps, not compiler bugs)

A Porffor guest is a `.wasm`, so the whole JS-via-Porffor path enters through scribbler; the host
intrinsics live in `scribbler/porffor/host` and the corpus/harness in `test/scribbler/js/**`.

- **Heap-typed run results.** The JS harness observes via `console.log` (Porffor's `printChar` emits
  bytes in-band). Decoding heap-typed `(f64,i32)` return values (string/object/array results from routed
  instance memory) is best-effort/deferred.
- **Two-profile (Safe/Unsafe) optimizer-soundness roll-up over the JS corpus.** `run_porffor` hardwires
  the Porffor posture; a `run_porffor_with(binding)` seam is left to a later phase. (Post-split the
  posture is composed here from `carder/cli`'s vocabulary plus this repo's `provider()` — the seam is
  ours to open.)
- **The 3 JS skips are Porffor's own bugs** (measured: `-0` rendering + broken lexical closures in
  0.61.13, which Porffor's authors call the "closure wall" / "terminal"). We reproduce `porf run`
  byte-for-byte on them — they bound Porffor, and are the reason the **arc frontend** (its own repo) is
  the real JS road forward, not more work here.
- **PGO / non-`{a,b,c,d}` idents.** `func_type/1` and `handler/1` are literal lock-step cases over the
  four Porffor import letters; anything outside them (e.g. the PGO `""."e"` `profileLocalSet`) is a
  fail-closed `Error(Nil)` in **both** faces. Supporting a new Porffor build means adding the letter to
  both cases, deliberately.

---

## G. Exception handling — the 2 legacy `.wast` files

- **Drive `legacy/try_catch` and `legacy/try_delegate` green.** ⓘ **Newly measured by Phase 13 (R16).**
  The tail-call proposal *converts* both files (they now vendor + parse), but running them green needs a
  **deeper, non-tail-call scope**, and most of the fix is carder's (carder §G):
  - `try_catch` — a **cross-module EH function+tag import** (`(import "test" …)` dispatched via a plain
    `call`, not a tail call). Needs carder's qualified cross-module tag identity (§C).
  - `try_delegate` — **(a)** pre-existing **legacy-`delegate` label-targeting** bugs (wrong handler
    depth, no `return_call` involved) and **(b)** the **`return_call`-inside-`try` interaction**: a WASM
    tail call must abandon the enclosing handler, but BEAM `try/catch` is *dynamically scoped*, so a
    tail `apply` emitted inside it stays in scope. (b) is a carder EH-lowering fix; **(a) is a
    measurement first** — the depth may be resolved wrongly in *our* wasm→IR lowering or mis-modelled in
    carder's IR `Try` surface. Take the measurement before scoping.
  - Both files stay **categorized-deferred, fail=0** (never false-green) until an EH unit takes them.
    Scope it as a **paired unit across the two repos**: carder lands the codegen fix, scribbler bumps the
    dependency, and **scribbler's `.wast` count is the capstone**.
- **Threaded + EH where state threads *through* a throw/catch** (the Phase-7 `cell`-only bound) and
  **modern `exnref`/`throw_ref`/`catch_ref`/`catch_all_ref` as a live feature** (shipped
  spec-conformance-only, Porffor-inert): the runtime halves are carder's; the surface and the coverage
  are ours.

---

## H. Tooling & the suite's own machinery

- **WAT-parser extensions:** the SIMD text format (~511 skips; the binary path proves SIMD e2e), plus the
  out-of-scope constructs in `memory64.wast`/`linking.wast` (`(module definition)` module-linking, 2⁴⁸
  hex-with-underscore literals, `(memory i64 (data …))` inline data, interleaved GC typed-ref globals).
  All are **file-level parse-skips**; the *runtime* features are proven by authored backstops. Closing
  any of them is pure frontend work in `scribbler/wasm/wat` plus the `wat_fixture` adapter.
- **The vendoring pipeline and the PIN.** `vendor/vendor.sh` clones the testsuite at
  `TESTSUITE_SHA`, converts each `ALLOWLIST` entry with `wast2json`, and **requires
  `spectest-interp` to report N/N before the fixtures are trusted** — a mismatched fixture set fails
  there, not in the runner. The full normalised fixture set is gitignored (it is large); a curated
  subset is committed so `gleam test` runs without re-vendoring. Open items: bumping `TESTSUITE_SHA` /
  `WABT_VERSION` / `WASM_TOOLS_VERSION` is a deliberate reviewed change (the baked-in expected values
  are only trustworthy against a known suite revision), and the second (wasm-tools) lane should
  eventually converge with the main allowlist if wabt ever parses GC.
- **CI.** The wabt / wast2json / vendored-testsuite block lives here now and nowhere else. Keep it that
  way: if it ever reappears in carder, the split has leaked.
- **The carder dependency.** `gleam.toml` may carry a local `path` override for development;
  `gleam.toml.git-dep` is the committed shape. **Restore the git dep before committing** — a
  path-override on `main` breaks every consumer. Automating that check is an open tooling item.
- **WASI** stays deliberately out of carder's core; if it is ever wanted, it lands here as one more
  `link.Provider.Namespace` beside `spectest`/TeaVM/Porffor. The browser DOM is out of scope entirely.

---

## Suggested sequencing (not binding) — scribbler

Roughly by leverage. Items whose fix is carder's are listed with their pairing, because the *proof*
still lands here.

1. **The EH pair** (§G) — take the `try_delegate` handler-depth measurement first (it decides which repo
   owns half the work), then land the paired unit and let the 2 legacy files' counts be the capstone.
   Closes Phase-13's honest deferral.
2. **WAT-parser extensions** (§H) — the SIMD text format is the biggest single skip bucket (~511) and is
   *entirely* ours; no carder change, no new IR, pure parser + adapter work.
3. **GC surface** (§B) — the ceiling on the TeaVM/Java path and on the `try_table`/`tag.wast` files.
   Two-repo: decode/validate/lower here, IR types + runtime in carder. Sequence the carder half first.
4. **The `cell_nif` conformance point** (§D) — small, joint, and it removes a documented honest gap
   from carder's Phase-15 claim.
5. **Producer shims** (§A) — a new toolchain's namespace module is additive and self-contained; good
   parallel work for a swarm.
6. **The Porffor seams** (§F) — `run_porffor_with(binding)` for the two-profile roll-up, and heap-typed
   result decoding. Bounded by Porffor itself; do not spend more here than the bound is worth.
7. **Suite hygiene** (§H) — PIN bumps, allowlist growth toward the full testsuite, and the dependency
   guard. Cheap, continuous, and it is what keeps `fail=0` meaningful.
