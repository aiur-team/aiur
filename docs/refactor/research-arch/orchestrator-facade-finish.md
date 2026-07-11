# Decomposition proposal (round 2): finish `src/lib/aiur/orchestrator.ex`

Round 1 (T-022→T-027) moved the orchestrator's *logic* into 27 submodules under
`src/lib/aiur/orchestrator/`; the facade landed at **2,824 lines** (verified on
`origin/v2` — 56 GenServer callbacks, 196 public `def`, 177 private `defp`). The behavior
moved; the **interface and glue did not**. This round relocates the residual glue so the
facade becomes a thin dispatch index — without a dispatch-registry rewrite.

**Decisions (operator, 2026-07-10):**
- **Target = idiomatic ~400–800, behavior-preserving moves only.** No dispatch-registry
  rewrite (rejected: behavioral risk on the fleet's hottest GenServer). The 200-line norm
  is a guiding target with judgment exceptions (17 of 28 current orchestrator modules
  exceed it by design; 29% of `src/lib`) — the goal is killing the 2,824 *outlier*, not a
  hard cap.
- **Client API stays with the GenServer (OTP idiom).** Splitting the ~140 client wrappers
  into `Orchestrator.Api` is the only lever below ~400 and is a mild anti-pattern (callers
  expect `Orchestrator.pause_agent/2`); explicitly a **non-goal** here. If ever wanted,
  it's a separate, reversible follow-up evaluated on this round's result.
- **Scope = facade + clean sibling splits.** Split siblings only where a real concern
  boundary exists; leave verbatim-invariant / hotspot modules whole.

---

## 1. What's in the 2,824 (verified `origin/v2`)

| Content | Count | Disposition |
|---|---:|---|
| GenServer callback clauses (`handle_call`/`cast`/`info`) | 56 (36/2/18) | **Stay** — thinned to 1-line delegators once F1 moves their bodies |
| Public client API (`pause_agent`, `snapshot`, …) | ~140 | **Stay** (OTP idiom; the ~400 floor) |
| Private helper glue | 177 defp | **F1** — relocate into owning submodules |
| `init/1`, `terminate/2`, subscriptions, tick seed | — | **F1b** — pipeline → `Lifecycle`; facade keeps 2-line `@impl` heads |
| `*_for_test` seams | ~30 | **F3** — the deferred round-1 W29 cleanup |
| Module head / aliases / tracked-set closure | — | **Stay** (`issue_tracked?/1` = publisher-closure contract) |

Fattest residual functions carry inline logic that belongs in a submodule:
`handle_call(:snapshot)` 67 → `StatusReport`; `handle_agent_down/2` 44 → `RetryEngine`
(see §4); `publish_ci_terminal_event/4` 42 → `CiLifecycle`; `maybe_choose_under_load/2` 36
+ `do_maybe_dispatch/1` 36 → `Dispatcher`/`DispatchPolicy`.

---

## 2. Facade seams (F-waves)

### F1 — relocate the 177 residual helpers (pure moves, zero caller churn)
Most map onto **existing** submodules. One net-new cohesive concern warrants its own home:

| Residual cluster | Representative fns | Destination |
|---|---|---|
| CI feedback loop (net-new, #892) | `publish_ci_terminal_event/4`, `transition_ci_ticket/3`, `pause_issue_for_ci_wait/2` | **new** `Orchestrator.CiLifecycle` — a *coordinator* (fans out to `Tracker`/`DispatchPolicy`/`Reconciler`), not a pure leaf; keep the fan-out one-directional |
| `:DOWN` completion/retry | `handle_agent_down/2`, `preserve_running_issue_on_external_error/2` | `RetryEngine` (**single home** — see §4) |
| Dispatch entry | `do_maybe_dispatch/1`, `maybe_choose_under_load/2` | `Dispatcher` / `DispatchPolicy` |
| Label-override pause | `pause_issue_for_label_override/2` | `PauseResume` (co-locate with #914's fix) |
| Control-status writes | `transition_control_status/4`, `handle_worker_control_state/4`, `put_running_control_status/3` | relocate to their **primary caller's** module — **no** new `ControlState` module (they're thin cross-cutting writers coupling `State`/`OperatorMessages`/`StatusReport`; a module would manufacture a seam). Resolve exact home in FF-W1 from the call graph. |

Mechanics unchanged from round 1: moved `defp`→`def` taking `%State{}` first; the facade's
`handle_*` clauses call the new module. **Invariant:** extracted code stays plain function
calls inside the orchestrator process — no `GenServer.call` back into `self()` (deadlock).

### F1b — extract the lifecycle pipeline → `Orchestrator.Lifecycle`
Move the `init/1` cleanup-ordering pipeline (terminal → todo → stray-RC → tracked-set init
→ subscriptions → tick 0) and `terminate/2` (`ProcessReaper.reap([:agent], drain: false)`);
facade keeps 2-line `@impl` heads. **Invariant:** init ordering and `drain: false` unchanged.

### F3 — run the deferred W29: collapse `*_for_test` seams (touches `src/test/aiur/`)
The only wave that edits tests. **Convert** each `*_for_test` wrapper to a direct call to the
now-extracted module in its test — do **not** delete an assertion whose invariant isn't
otherwise reachable via a public path (that would silently un-pin it). Excludes
`src/test/aiur/regression/` (do not edit). Verify coverage does not drop.

Residual facade after F1/F1b/F3 + clause thinning: `use GenServer` + `Lifecycle` heads +
56 delegator clauses + ~140 client wrappers + tracked-set closure ≈ **~400–800** (FF-W0/W1
pins the exact figure).

---

## 3. Sibling splits (clean boundaries only)

| Module | LOC | Verdict | Split |
|---|---:|---|---|
| `operator_messages` | 459 | **Split** | enqueue · delivery-policy · capabilities/queue-depth |
| `token_accounting` | 450 | **Split (safe)** | pure payload parsers → `TokenAccounting.Payloads` (~300, zero state); deltas/integration stay (~150) |
| `comment_polling` | 428 | **Split** | target-selection · poll-drivers (round-1 W10/W11 seam) |
| `retry_engine` | 396 | **Leave whole** | verbatim budget invariant (`giant-orchestrator.md:97`) |
| `comment_wake` | 387 | **Leave whole** | hotspot #1 (~35 incidents, TOCTOU revalidation chain #621→…→#683); a single cohesive state machine — carving its revalidation path is exactly the historically-regressing seam. Same judgment as `retry_engine`. |

---

## 4. Waves / tickets

Serialized on `orchestrator.ex` (F-waves); sibling splits are independent files (parallel).

- **FF-W0** — characterization tests, weighted to the **least-tested glue**: the net-new CI
  feedback loop (#892, no dedicated pins), control-status writes, and `:DOWN` routing.
  Prereq for F1. (More than one wave's worth of the round-1 gaps live here.)
- **FF-W1** — F1 relocation of CI-terminal + control-status + `:DOWN` glue (+ `CiLifecycle`) (~350).
- **FF-W2** — F1 relocation of dispatch + remaining glue + F1b `Lifecycle` extraction (~350).
- **FF-W3** — F3 / W29 test-seam conversion.
- **SB-W1..3** — split `operator_messages`, `token_accounting`, `comment_polling` (parallel).

**Behavior-preservation:** all `giant-orchestrator.md` §4 invariants carry forward verbatim.
Two called out by the round-2 review:
- **§4.7 `handle_agent_down` is atomic** — `:normal` → `complete_issue` + continuation
  retry attempt 1; crash → `next_retry_attempt_from_running`; it calls **no** teardown.
  Move it whole to `RetryEngine`; do **not** fragment the `:normal`-vs-crash branch across
  modules.
- **§4.11 pause-clock ordering** — control-status + clock steps in
  `send_resume_control_message` must not be reordered by the relocation.
