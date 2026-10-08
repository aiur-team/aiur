---
ticket_id: MP-R1-C9-T09
feature_id: MP-R1
chunk_id: MP-R1-C9
bucket: 1-refactor
title: Transition back-calls return effects to U2's lifecycle owner instead of calling the Orchestrator facade
status: blocked
blocked_by: [DESIGN-R1, RQ-U2-TRANSITION, U2, MP-R1-C9-T07, MP-R1-C9-T08, MP-E1-C1]
prior_units: [U2, U8]
prior_boundaries: [ORC #12, CTL #14, PRL #15, MSG #16]
prior_features: [MP-E1]
prior_findings: [orch-a-06, orch-b-11, orch-b-12]
size_owner: LIFECYCLE_STATUS (reconciler.ex); LIFECYCLE_DISPATCH (orchestrator.ex, comment_wake.ex, operator_messages.ex, push_routing.ex); re-resolve at start
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C9-T09 — Facade back-calls, part 2 (transitions as effects)

## Identity and outcome

- Bucket 1, MP-R1, chunk C9, step S16.
- **User value:** none visible. The 22 remaining sub-module → facade calls are all ticket
  transitions. After this ticket, sub-modules **return** a transition request and exactly
  one module — the lifecycle owner U2 names — applies it. This is the "effects return" of
  prior §7 step 10.
- **Deliverable:** `Aiur.Orchestrator.Effect` (PROPOSED) type, sub-module functions that
  today call one of the seven transition facades return `{state, [effect]}`, and the U2
  owner's `apply_effects/2` executes them in order.
- **Non-goals:** no change to what a transition does, its order inside a tick, or its
  side effects (labels, alerts, worker stop). No new process.

## Dependencies and blockers

- **RQ-U2-TRANSITION (blocking, owner: prior program U2).** "Which process owns the
  authoritative ticket transition? … Name the owner, durable replay/idempotency rule and
  failure behavior before U2"
  (`docs/research/refactor-2026-09-26/synthesis/open-questions.md:9`). The effect
  interpreter **is** that owner; C9 must not choose it (MP-R1 plan §9 C9 research note).
  This ticket starts only after U2's owner PR merges, and adopts U2's module name and
  replay rule.
- C9-T07 (owner table; `:lifecycle` mapped to U2's module), C9-T08 (non-transition calls
  already gone, so this diff is only transitions).
- **RC-19/RC-20:** MP-E1-C1 hooks stay. The build queue is a sanctioned *caller* of the
  label-writer seam; it does not emit `Effect`s and must not be routed through this
  interpreter unless U2 says so. Add the explicit guard test below.

## Verified starting point (45a290e3)

Transition facades in `src/lib/aiur/orchestrator.ex` and their implementations:
`resume_paused_issue/3` → `PauseResume` (`:951-952`), `reactivate_issue/2` → `PauseResume`
(`:937`), `transition_control_status/4` → `PauseResume` (`:256-257`),
`terminate_running_issue/3` → `AgentTeardown` (`:402-403`),
`preserve_running_issue_on_external_error/2` → `RetryEngine` (`:374-375`),
`pause_issue_for_ci_wait/2` → `CiLifecycle` (`:382`),
`maybe_deactivate_human_review_issue/2` → `HumanReview` (`:398-399`).

Back-call sites (`git grep` at base): `reconciler.ex` 12, `push_routing.ex` 4,
`operator_messages.ex` 3, `comment_wake.ex` 2, `github_budget_pause.ex` 1,
`pr_anchored.ex` 1 (23 including one test,
`src/test/aiur/orchestrator_control_routing_test.exs`).

## Chosen design (conditional only on U2's module name)

```elixir
@type t ::
  {:terminate, issue_id :: String.t(), cleanup_workspace :: boolean()}
  | {:resume_paused, running_entry :: map(), operator? :: boolean()}
  | {:reactivate, running_entry :: map()}
  | {:transition_control, running_entry :: map(), status :: atom(), reason :: term()}
  | {:preserve_on_external_error, issue :: Aiur.Issue.t()}
  | {:pause_for_ci_wait, issue :: Aiur.Issue.t()}
  | {:maybe_deactivate_human_review, issue :: Aiur.Issue.t()}
```

- Each call site `state = Orchestrator.x(state, …)` becomes "append `{:x, …}`"; the
  enclosing public function returns `{state, effects}`; its caller (already inside the
  orchestrator process) calls `Lifecycle.apply_effects(state, effects)` (name per U2)
  **immediately**, at the same point in the tick where the inline call ran.
- **Order invariant:** effects are applied in emission order, and before any later read
  of the fields they write. Where a call site's following code reads the result of the
  transition (check each of the 23 sites), the site applies at that point instead of
  deferring — i.e. the interpreter is called at the end of the smallest enclosing function
  whose later code does not read transition output. This is what keeps behaviour
  identical; the implementer records each site's apply point in a table in the PR body.
- Idempotency/replay: whatever U2 defines for its owner applies unchanged; this ticket adds
  none.

## Implementation steps

1. Add `effect.ex` (types only).
2. Convert sites file by file (`reconciler.ex` first — 12 sites), each file one commit.
3. Delete the seven facade entries once no caller remains (the test at
   `orchestrator_control_routing_test.exs` switches to the owner).
4. Checker: the "sub-module → facade" violations reach zero; remove the allowlist rows.

Estimated: ≈250 changed lines.

## Non-happy paths

| Case | Behaviour |
|---|---|
| A transition fails (label write error) | Same as the inline call today: the owner's error path, unchanged. |
| A site reads transition output right after | Applied at that point (order invariant). |
| Effects list dropped by a refactor slip | Compile-time: functions return `{state, effects}`; the test below fails if any effect is ignored. |
| Build queue (RC-20) | Not an effect producer; guard test. |

## Compatibility and rollout

Internal; no config. Rollback: revert (U2 owner stays).

## Verification

```bash
env -C <checkout>/src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/orchestrator test/aiur/orchestrator_control_routing_test.exs \
  test/aiur/orchestrator_deactivate_test.exs test/aiur/orchestrator_status_test.exs \
  test/aiur/orchestrator_ci_lifecycle_test.exs test/aiur/build_queue
python3 scripts/check-components.py
```

| Test | Expectation | Fails without |
|---|---|---|
| `reconciler_test "stalled running issue emits a :terminate effect and the owner applies it"` | returned effects equal `[{:terminate, id, false}]`; after apply, `running` lacks the id | the conversion in `reconciler.ex` |
| `effects_test "effects are applied in emission order"` | two effects on the same issue (`transition_control` then `terminate`) leave the recorded order in the owner's transition log | the ordered apply |
| `orchestrator_facade_test "no orchestration sub-module calls a transition facade"` | zero source matches | any site conversion |
| `build_queue_seam_test "build queue emits no Orchestrator.Effect and calls only the label-writer seam"` | source scan of `src/lib/aiur/build_queue/**` finds no `Effect` and no `Aiur.Orchestrator` reference (RC-11, RC-20) | (regression guard; passes at E1 head by construction — label it so) |

Full CI on the head SHA plus the AGENTS.md wrapper-tmux `aiurdev --test` run: pause and
resume an agent from the TUI (`r`/pause keys) and from `aiurdev pause/resume`; see the same
rows and states as before.

## Completion and handoff

- [ ] U2 owner module and replay rule cited in the PR body.
- [ ] Zero facade transition calls; per-site apply-point table in the PR body.
- [ ] MP-E1-C1 hooks unchanged.
- Docs: none.
- Dependents: later PR-lifecycle / messaging process splits (prior §7 step 10 "only after
  that consider separate processes"). size_owner re-resolved at ticket start (RC-23).
