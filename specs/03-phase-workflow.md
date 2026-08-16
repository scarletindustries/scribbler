# How to scope & implement a phase

> The repeatable recipe that got this project to Phase 10. Ten phases were built this way; it works.
> Follow it. This is the "how we work" reference — read it before scoping anything new.
>
> **Scope note (post-split):** this repo is scribbler, the **WebAssembly frontend** — decode, validate,
> canonicalize, lower to carder's IR, the WAT printer, the wasm-producer host shims (`spectest`,
> `teavm`, Porffor), and the entire official WebAssembly spec-test conformance suite. The shared IR,
> middle-end, Core Erlang backend and BEAM runtime are the **carder** repo, consumed here as an
> ordinary Gleam dependency; carder keeps its own copy of this file. §§0–7 (the process) are identical
> in both; §§8–10 (invariants, Definition of Done, differentials) are repo-specific — these are
> scribbler's.
>
> Companions: [`00-high-level.md`](00-high-level.md) (the vision every phase serves),
> [`01-status.md`](01-status.md) (what's built), [`02-roadmap.md`](02-roadmap.md) (what to build next),
> [`state.md`](state.md) (the live ledger you update as you go), and **carder's**
> `specs/FRONTEND-API.md` (the backend contract this frontend compiles against — carder repo).

---

## 0. The shape of a phase

A **phase** is one coherent capability increment (a WASM surface, a proposal's decoder + validator, a
host-ABI shim). It is decomposed into numbered **units**, each single-owner and independently
committable. Unit **01 is always the keystone** (freezes the interfaces); the **last unit is always the
capstone** (proves the phase). Everything between builds in parallel behind the frozen interfaces.

```
overview + decisions ─▶ scoping fan-out ─▶ adversarial critique ─▶ reconcile
        │                                                              │
        ▼                                                              ▼
   KEYSTONE (unit 01)  ──freezes «X-FROZEN» interfaces──▶  parallel units (02..N-1)  ──▶  CAPSTONE (unit N)
   lands green, defaults byte-identical                    each single-owner, green      proves the phase
```

The discipline that makes it parallelizable: **freeze the complete interface first, then build bodies
independently behind it.** A late-discovered interface gap re-breaks every exhaustive match in the
phase, so the keystone must freeze the *whole* surface (all AST variants, all decode/validate error
reasons, all lowering cases) up front — not incrementally.

---

## 1. The lifecycle (seven steps)

1. **Author the overview** (`00-overview.md` in the phase's working area) to the fixed skeleton in §2.
   Open by restating that **all prior-phase decisions still hold** and cite the running baseline (test
   count / 0 warnings / conformance triple).
2. **Scoping fan-out.** Multiple scoping agents propose/refine the unit split from the overview's
   proposed dependency DAG. The overview flags open seams for them to sanity-check (is the decoder unit
   single-agent-sized? does this feature belong in unit 08 or get cut?).
3. **Adversarial critique.** Critique the scoped decisions and unit docs from several lenses. This is
   the step that catches the blockers — incompatible interface spellings invented by parallel scoping
   agents, unsound validation rules, missing AST variants, double-owned files.
4. **Reconcile.** Fold the fan-out + critique into a single authoritative `RECONCILIATION.md` carrying
   `R`-numbered decisions. Declared **authoritative: where a unit doc conflicts, RECONCILIATION wins.**
   Implementer read order becomes overview → RECONCILIATION → unit doc. *(Small phases with no
   conflicts skip the standalone file and fold resolutions into the overview.)*
5. **Freeze the keystone** (unit 01, §3). Publish the `«X-FROZEN»` interfaces, make the deliberate
   documented cross-file reaches, land **green** with the pipeline still identity / defaults
   byte-identical. Announce each milestone in [`state.md`](state.md) the moment it lands.
6. **Build the parallel units** (§4) in waves behind the frozen signatures. Each is single-owner, needs
   only the frozen *signatures* (not sibling bodies), ships code + adversarial fixtures, is individually
   green + committable, and updates `state.md` with what it leaves.
7. **Close with the capstone** (§5). The only unit that edits the single wiring/registration point. It
   runs the corpus-wide differential across every `(mode × state_strategy × mem_tier)`, satisfies the
   §1 acceptance table, refreshes the conformance image, and produces the measured benchmark.

Throughout, the manager QA-gates every unit (format / build / test + conformance `fail=0` + a spec-DoD
read) before commit + push to `main`.

---

## 2. Anatomy of the overview doc

Fixed skeleton — every phase overview has these sections:

- **§0 Where this phase sits** — one paragraph placing it on the platform ([`00-high-level.md`](00-high-level.md)).
- **§1 Goal + acceptance table** — "Area | Must demonstrate" rows (the capstone owns proving these) and
  an **Honest-scope** subsection stating what is deferred and *to which future phase*.
- **§2 The numbered phase decisions** — a letter-prefixed list (see §6). Each is **frozen**: the
  standing rule is *"if you believe one is wrong, raise it with the planner BEFORE building — do not
  silently diverge."* By convention **decision #1 is the keystone** (the phase's load-bearing new
  thing) and **the last decision is "Honest scope."**
- **§3 The dependency DAG** — names the `«X-FROZEN»` milestones and the parallel waves.
- **§4 File-ownership map** — one owner per file (invariant D1).
- **§5 How to claim & complete** — pointer to the ledger conventions (§7 here).

---

## 3. The keystone (unit 01) — "Interface freeze"

Single-owner, goes **first and alone**. It:

- **Implements the phase's one load-bearing new thing** (decision #1) and **freezes its interface** as
  the `«X-FROZEN»` milestone(s): AST types, the decoder's binary-format delta, new decode/validate
  error reasons, the lowering's IR mapping, and host-shim signatures as bodies that are
  **conservative-sound, never `todo`** (an unimplemented opcode is a *rejection*, never a silent
  accept; an unsatisfied import is a link-time failure, never a stub that returns zero).
- **Makes the deliberate, documented cross-file reaches** needed to compile. This is necessary because
  **Gleam has no default field values** — extending an AST node or an error type breaks every
  constructor and every exhaustive match. The keystone updates
  `wasm/ast.gleam`/`wasm/decode.gleam`/`wasm/validate.gleam`/`wasm/canon.gleam`/`wasm/lower.gleam`/
  `wasm/wat.gleam`/`pipeline.gleam` so the tree compiles, and records every reach in `state.md`.
- **Lands green with the pipeline still identity** and defaults chosen so **every prior module is
  byte-identical** — a module using none of the new surface must lower to the same `.ir` and build to
  the same `.beam` as before the phase. Nothing is unsound until a later unit proves the guard.
- Ships a dedicated freeze test module (e.g. `ir3_freeze_test` / `eh_freeze_test` / `tier_freeze_test`)
  — small spec-tests that the new surface is expressible and the defaults are fail-closed.
- **Uses the backend as-is.** If the new surface appears to need a change in carder, that is a §8
  invariant to answer deliberately — see *"no scribbler change may require a carder change."*

**Why first & alone:** an unsound validator or a missing AST variant makes every downstream unit
unsound; and publishing the stable signatures is what lets the parallel units + the lowering build
without racing on names.

---

## 4. The units (02 … N-1)

- **Single-owner** (D1). Additive changes only. Needs only the frozen *signatures* of its dependencies,
  **not** their bodies — e.g. the lowering is built in parallel with the decoder bodies; `validate`
  gates on the day-1 published AST stub.
- **Does not touch the single pipeline/registration point** — that's the capstone's job. This is what
  keeps units independently committable without merge races.
- Ships its code **plus isolated, adversarial fixtures** — including "must-NOT-do-this" fixtures for
  anything whose failure is silent (a validator that accepts a malformed module is a silent soundness
  hole, so it gets its own adversarial unit; every `.wast` `assert_invalid` / `assert_malformed` is a
  must-reject fixture).
- Is individually **green + committable + pushable**, and updates `state.md` with what it leaves and to
  which downstream unit.

---

## 5. The capstone (last unit) — "PHASE N PROVEN"

- The **only** unit that edits the single wiring/registration point: the wasm pipeline, the CLI verb
  table, the conformance Driver, or the host-provider registry (`host/spectest`, `host/teavm`,
  `porffor/host` — each handed to carder as a `link.Provider`, `Namespace` variant included).
- **Proves the phase** by owning the §1 acceptance table: the corpus-wide **differential** — producing
  **byte-identical returned values (by bit pattern) and identical traps (same `TrapReason`, same
  trap-or-not)** — run under **every** shipped `(mode × state_strategy × mem_tier)` combo and **both**
  profiles; plus the fail-closed / isolation / trap-preservation properties.
- **Refreshes** [`docs/wasm-conformance.svg`](../docs/wasm-conformance.svg) (`fail=0`, honest
  categorized skips; regenerate with `scripts/gen-conformance-svg.sh`) and produces a committed,
  **measured** benchmark with methodology and the honest pattern-dependent ceiling written down
  (`docs/phase-N-benchmark.md` or `-surface.md`) — *measured, not asserted; no hero number.*
- Reports the running gleeunit total **and the conformance triple** (`pass / skip / fail`). Capstones
  **confirm green, they do not re-derive** prior units.

---

## 6. Decision codes & reconciliation

Each phase's overview §2 carries its own letter-prefixed, sequentially-numbered decision list, frozen
for that phase. The letters advance one per phase:

| Phase | Codes | Phase | Codes |
|---|---|---|---|
| 1 | `D1–D10` (the permanent cross-phase invariants) | 6 | `I1–I8` + `S1–S15` (reconciliation) |
| 2 | `E1–E8` | 7 | `J1–J8` + `T1–T14` (reconciliation) |
| 3 | `F1–F8` | 9 | `M1–M8` |
| 4 | `G1–G8` | 10 | `N1–N8` |
| 5 | `H1–H8` + `R1–R18` (reconciliation) | 13 / 14 / 15 | `Q…` / `R…` / `S…` |

**Post-split the series forks, so the two repos can never mint colliding codes.** The unprefixed
letters `A`–`S` are the **pre-split shared history** (Phases 1–15, one tree, one series) and stay
readable as written wherever they appear. From the next phase onward:

| Repo | Series | Next |
|---|---|---|
| **scribbler** (this repo) | `S-`-prefixed, restarting at `A` | `S-A`, then `S-B`, `S-C`, … |
| **carder** (backend) | `C-`-prefixed, continuing the letter run | `C-T`, then `C-U`, `C-V`, … |

Within each list: **#1 = the keystone**, **last = "Honest scope."** When a fan-out + critique surfaces
conflicts, the resolutions become a separate authoritative `RECONCILIATION.md` with `R`-numbered
decisions that **win over any conflicting unit doc**.

---

## 7. Using the state file (`state.md`)

`state.md` is the **live ledger for the phase in flight** — the swarm's shared "who's doing what."
*Read it before claiming work; update it after finishing.* It is **not** a history archive — completed
phases are compacted out of it into [`01-status.md`](01-status.md) once proven (that's this
consolidation). Keep it small and current. It carries three things:

1. **A freeze-milestone table** — `Milestone | Produced by | Status | Unblocks`. Mark a milestone
   `FROZEN ✓` / `published ✓` the *moment* it lands.
2. **A unit table** — `Unit | Doc | Owner / status | Depends on (freeze) | Leaves`. Status legend:
   `unclaimed` · `in-progress (name)` · `blocked (on …)` · `done`. The **Leaves** column states what
   the unit produces and hands to which downstream unit.
3. **A landing log** — each landing recorded as a running count (`N tests (was M, +K)`), the
   conformance triple (`pass/skip/fail`), `0 warnings, format clean`, and `byte-identical`.

When a phase closes (capstone proven), fold its outcome into `01-status.md` §3, move any new deferrals
into `02-roadmap.md`, and reset `state.md` to the empty template for the next phase.

---

## 8. The permanent, cross-phase invariants (never violate these)

These are the load-bearing rules every phase preserved. They are the difference between "compiles" and
"correct + sandboxed." Treat them as a hard gate.

- **D1 — One owner per file.** Every file has a single owning unit; changes stay additive. Only the
  keystone/capstone make cross-file reaches, and only *deliberate, documented* ones (recorded in
  `state.md`) — justified because Gleam has no default field values.
- **WASM byte-identical / conformance-neutral by default.** A module using no new surface compiles
  byte-identically to the prior phase (defaults route new surface away: memory-index 0 defaults away,
  unchecked nodes are never produced by the frontend, Safe.beam differs from Unsafe.beam only by charge
  instrumentation + the `instantiate/0` seed). Where a change legitimately alters emitted code, the bar
  relaxes to **result-identical** (same values by bit pattern, same traps), proven by the corpus-wide
  differential. **Conformance-neutral** is the daily form of the rule: the spec-suite triple never
  regresses — `fail` stays `0` and `pass` never goes down.
- **No scribbler change may require a carder change** *(post-split — the invariant that keeps the split
  real).* The backend is language-neutral by construction (D6), and this repo is the only place that
  knows what WebAssembly is. When a new wasm surface *appears* to need backend work, the answer is
  never a wasm-shaped feature in carder. It is:
  1. a **more general seam** in carder — a new IR node/effect any frontend could use, a `link.Provider`
    variant, a `Binding` axis, a `carder/cli` flag — proposed as an additive, default-off change to
    carder's `specs/FRONTEND-API.md`; **plus**
  2. the **specific wasm knowledge** kept *here*: the opcode, the validation rule, the host module
    name, the ABI, the trap-message wording.

  Concretely: carder hard-codes **no** host module by name — `spectest`, TeaVM's `teavmJso` and
  Porffor's `""` intrinsics are all supplied from this repo as `link.Provider` values. If a change
  would put the string `"spectest"` (or any other wasm concept) back into carder, it is the wrong
  change. A genuine seam widening is a **separate, separately-reviewed PR in the carder repo** with its
  own Definition of Done, landed and released first — never a drive-by edit from a scribbler unit.
- **carder's invariants still bind everything we emit.** They are normative here even though they live
  in §8 of `specs/03-phase-workflow.md` in the **carder repo** — read them there. The ones a frontend
  can violate from a distance:
  - **D3a — no ambient authority.** Host functions reach a guest only as `link.Provider` capabilities
    handed to the instance through `carder/cli.resolve_binding`; nothing we emit or register may become
    a data-driven `apply(Mod, Fun, Args)`.
  - **D4 / D9 — fail closed.** Safe is the default. An unimplemented opcode *rejects*; an unsatisfied
    import fails at **link** time; an unknown host name is never silently satisfied. Decode and
    validate errors are per-stage typed errors, never a permissive fallthrough.
  - **D5 / D7 — raw bit patterns, compared by bit pattern.** Floats and v128 cross the boundary as raw
    IEEE-754 / 16-byte bit patterns (NaN payloads, `-0.0`, wrap all exact). The `.ir` textual form is
    the lossless inter-stage contract — and, post-split, the actual repo boundary: what we hand carder
    is `.ir`, nothing else.
  - **D6 — no WASM-isms in the IR.** References lower to term-layer values, bulk ops to generic
    sequence ops, memories to the generic multi-region model. The lowering is where wasm vocabulary
    stops.
  - **E6 + trap-preservation.** A linear-memory access is **trap-or-access, not a pure read/write**.
    The lowering must preserve *when and whether* a trap fires and which `TrapReason` it carries — every
    downstream optimizer legality argument rests on that.

---

## 9. Definition of Done (the hard gate)

From `CLAUDE.md` + decision D8 — applied **per unit** and **per phase**. Not a checklist to skim.

**Per unit:**
1. **Spec-cited tests** written against the original specification — the
   [WebAssembly spec](https://webassembly.github.io/spec/) for WASM semantics (core spec for shipped
   surface, the proposal's own repo for proposal surface; the binary-format and validation sections are
   normative — cite the section), the relevant RFC/standard otherwise — asserting *defined* behavior,
   **not** change-detector tests that lock in current output. When a bug is found, add a failing
   spec-encoding test **first**, then fix. For a new surface: decode + validate + lower, adversarial
   `assert_invalid` / `assert_malformed` must-reject fixtures, and end-to-end BEAM value/trap
   preservation through carder.
2. **Doc comments** (`///` items, `////` module-level) on every public function — the *contract* (what
   / params-meaning-units-ranges / `Result`-`Ok`-`Error`-`Some`-`None` semantics / failure-modes +
   anything that can panic), not a restatement of the name.
3. `gleam format --check src test` **clean** (CI fails otherwise).
4. `gleam build` with **zero warnings**.
5. The unit's own conformance/interface suite **passes** — *done is "the suite passes," never "it
   compiles."*

**Per phase (the capstone bar):** the whole prior acceptance corpus + WASM spec suite stay green and
**result-identical** (by bit pattern, same traps) under both profiles and every
`(state_strategy × mem_tier)`; conformance `fail=0` with honest categorized skips; a measured
benchmark. The manager QA-gates every unit before commit + push to `main`.

---

## 10. Differential testing & toolchain pins

- **Spec `.wast`:** Tier-A (values baked in the `.wast`) + Tier-B (an engine oracle — `wasmtime` /
  `wat2wasm` / `wast2json` / the rebuild oracle), held across the full `(mode × tier)` matrix; every
  `(state_strategy × tier)` must be **byte-identical**.
- **Greenness is measured, never promised** (decision R16): re-verify empirically at the pinned SHA per
  file; the headline is whatever is measured (a "skip drops" plan can turn into a "pass roughly
  doubled" reality — report the reality).
- **Pins are explicit** (`vendor.sh` + `PIN`): Porffor 0.61.13, Node 22, wabt 1.0.41, wasmtime 46.0.1.
- **The `smoke/` benchmark harness lives here** — it is a wasm differential (cargo-builds a Rust crate
  to wasm, gates it import-free/MVP-only with `wasm-tools`, compares against `wasmtime`). It drives
  **this** repo's `build` verb and **carder's** `exec -n`, and compiles the tier-N `.so` out of band
  from carder's `c_src/carder_rt_mem_nif.c`, which — with carder as a Gleam dependency — is unpacked at
  `build/packages/carder/c_src/`. The measurements it produced stay committed in the **carder** repo
  (`docs/phase-3-benchmark.md`, `docs/phase-4-benchmark.md`, `docs/phase-15-tier-n.md`); reproduction
  is cross-repo.

---

## Commit conventions (from `CLAUDE.md`)

Never Claude-brand commits or PRs (no `Co-Authored-By: Claude`, no "Generated with Claude Code").
Commit frequently — one logical unit per commit, small and independently reviewable. Only commit/push
when explicitly asked; if on `main`, branch first.
