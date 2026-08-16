# Implementation State — the live ledger

> The swarm's shared ledger for **the phase currently in flight** in **scribbler** (the WebAssembly
> frontend). Before claiming work, read it; after finishing, update it. It is a *working* file, not a
> history archive — completed phases are compacted into [`01-status.md`](01-status.md) once proven, and
> this file resets to the template below for the next phase.
>
> **How to use this file:** [`03-phase-workflow.md`](03-phase-workflow.md) §7.
> **Where we are:** [`01-status.md`](01-status.md) · **What's next:** [`02-roadmap.md`](02-roadmap.md)
> · **Architecture:** [`00-high-level.md`](00-high-level.md) · **Backend contract:** carder's
> `specs/FRONTEND-API.md` (carder repo).
>
> The **backend** (IR, middle-end, Core Erlang codegen, runtime) has its own ledger in the **carder**
> repo (`specs/state.md`). A phase that spans both repos is claimed in both, with each side stating
> what it hands the other — and a carder-side seam widening lands there **first**, as its own PR
> ([`03-phase-workflow.md`](03-phase-workflow.md) §8).

**Legend — unit status:** `unclaimed` · `in-progress (name)` · `blocked (on …)` · `done`
**Legend — freeze milestone:** a published, compiling type/signature stub that unblocks downstream
units. Announce it here the moment it lands (`FROZEN ✓` / `published ✓`).

---

## Current phase

**No phase in flight.** Phases 1–15 were built and proven **pre-split, in the single carder tree**;
their frontend half is what now lives here. The ones this repo owns the evidence for:

- **Phases 1–10** — the WebAssembly 2.0 fixed-width surface: decode → validate → canon → lower, the
  WAT printer, the spec-test Driver, and the conformance suite itself.
- **Phase 5 / 6** — surface phases (`docs/phase-5-surface.md`, `docs/phase-6-surface.md`).
- **Phase 13** — WASM tail calls (`return_call` / `return_call_indirect`), frontend half
  (`docs/phase-13-surface.md`); the IR + `emit_core` half is carder's.
- **Phase 14** — cross-module funcref-in-`elem` init, closing the `table_copy.wast` residual
  (+1,088 pass) (`docs/phase-14-surface.md`).

**Then the repo split** — scribbler became the WebAssembly frontend (`wasm/{ast,decode,validate,canon,
lower,wat}`, the wasm pipeline + CLI, the host shims `host/spectest`, `host/teavm`, `porffor/*`, the
`smoke/` benchmark harness, and the entire official spec-test conformance suite), consuming carder as
an ordinary Gleam dependency. See [`01-status.md`](01-status.md) for what moved.

**Baselines.**

| | Figure | Provenance |
|---|---|---|
| **Historical (pre-split)** | `2,221` gleam tests / 0 fail · `gleam build` zero warnings · `gleam format` clean · WASM conformance **47,734 pass / 683 skip / 0 fail** (Safe ≡ Unsafe, every `state_strategy × mem_tier`) | the one tree, at the Phase-15 capstone, before the split. The conformance triple is the figure this repo inherits and must not regress. |
| **Current (scribbler)** | gleam tests: **re-measure on the split tree** (`gleam test`; scribbler keeps the frontend + conformance share of the pre-split suite) · `gleam build` zero warnings · `gleam format` clean | measure it, write the number here, and don't quote a number you didn't run. |
| **Conformance (this repo's headline)** | **re-measure and record the full triple** — the pre-split `47,734 / 683 / 0` is the value to reproduce; `fail` must be `0` and `pass` must not go down. | greenness is measured, never promised (decision R16). |

**Pick the next phase from [`02-roadmap.md`](02-roadmap.md)** and copy the template block below into
this file to start it. The nearest-leverage candidate for this repo (roadmap "Suggested sequencing"):
an **EH-lowering unit** to drive the 2 legacy exception-handling `.wast` files green — Phase 13's
honest deferral. Anything it needs from the backend must be a *general seam*, proposed as an additive,
default-off change to carder's `specs/FRONTEND-API.md` and landed there first.

---

## Template (copy this block when the next phase starts)

> Phase N — «title». Goal & honest scope: see the phase overview. Decisions: **scribbler's post-split
> series is `S-`-prefixed and restarts at `A`** — `S-A`, then `S-B`, `S-C`, … (`#1` = keystone, last =
> honest scope). The unprefixed letters `A`–`S` belong to the pre-split shared history (Phases 1–15,
> one tree, one series) and are never reissued. **carder continues `C-T`, `C-U`, … in its own repo**,
> so the two series can never collide. All prior-phase decisions and the invariants in
> [`03-phase-workflow.md`](03-phase-workflow.md) §8 still hold — including *no scribbler change may
> require a carder change*.

### Freeze milestones

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«X-FROZEN»` — … | 01 | `unclaimed` | … |

### Units

| Unit | Owner / status | Depends on (freeze) | Leaves |
|---|---|---|---|
| **01** Interface freeze (keystone) | `unclaimed` | — | … |
| **…** | `unclaimed` | … | … |
| **N** Capstone | `unclaimed` | all above | **PHASE N PROVEN.** … |

### Landing log

_(one line per landing: `unit — N tests (was M, +K), conformance p/s/f, 0 warnings, format clean, byte-identical`. If the phase needed a carder seam, record the carder PR + released version it depends on.)_
