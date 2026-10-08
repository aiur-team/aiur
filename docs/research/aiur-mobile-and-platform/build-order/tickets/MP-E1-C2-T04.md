---
ticket_id: MP-E1-C2-T04
feature_id: MP-E1
chunk_id: MP-E1-C2
bucket: 2-platform
title: Pure action planner (desired vs observed labels)
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C2-T02, MP-E1-C2-T03]
prior_units: [U2]
prior_boundaries: [BO #30]
prior_features: []
prior_findings: [MP-E1 F1, F4, F5]
size_owner: n/a (new file)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C2-T04 — `Aiur.BuildQueue.Planner`

> **Plan refresh (wave 0).** Pure code under `src/lib/aiur/build_queue/`
> (PROPOSED); moves unchanged after MP-R1. No reference to orchestration,
> GitHub or Build Order modules (C1-T07).

## Identity and outcome

- Bucket 2, MP-E1, C2, T04.
- **User value:** every queue decision (promote, withdraw, hold, override,
  attention) comes from one deterministic, idempotent function, so duplicate
  or missing events and restarts converge (plan §6).
- **Deliverable:** PROPOSED `src/lib/aiur/build_queue/planner.ex`:
  `plan(%Input{queues, items, edges, observations, intents, latches, claims, now_ms, opts}) :: {[item_state], [action]}`.
- **Non-goals:** executing actions (C3), I/O.

## Dependencies and blockers

- DESIGN-E1 **OQ-3** (do not promote while `agent:paused`, `agent:parked`,
  `needs-triage` or `human:todo` is present — recommended; implemented as
  `opts[:promote_parked?]`, default from the answer).
- C2-T02, C2-T03.

## Verified starting point (`45a290e3`)

- Item states and allowed writes: contract §2.3; withdrawal: §2.4;
  competing writers: plan §5.8.
- Parking markers recognised today: `orchestrator/issue_sync.ex:485-494`
  (`needs-triage`, `human:todo`, `epic:*`) and `Issue.paused?/parked?`
  (`issue.ex:100-107`). The planner re-derives them from label strings with
  the prefix from opts (it does not call `IssueSync`).
- Own writes are not observable as bus events (daemon actor filter,
  `events/publisher.ex:405-423`, F2) — hence intents.

## Chosen design

Item state derivation (first match):

1. marker absent and item was managed → `:removed` (action `dequeue`).
2. issue closed → `:completed` / `:cancelled`.
3. any non-todo state label, or `claims[id] == :claimed` → `:claimed`.
4. `todo` present and no intent explains it and item was not promoted by the
   queue → `:overridden` (action `mark_override`).
5. item was promoted, `todo` now absent, no withdraw intent → `:held`
   external (action `mark_external_hold`).
6. `item.hold` or queue held → `:held`.
7. verdict `{:unknown, _}` → `:unknown`; `{:failed, _}` → `:failed_prerequisite`.
8. verdict `:ready`, parked marker present and not `promote_parked?` → `:held`
   (reason `:parked_marker`).
9. verdict `:ready` and `todo` absent → `:ready` (action `promote`).
10. `todo` present (queue's own) → `:promoted`; if verdict is no longer
    `:ready` → action `begin_withdraw` (C3-T05 then asks the ClaimProbe and
    emits `withdraw` or `hold_release` + attention on the next plan).
11. otherwise `:waiting`.

Extra rules:

- `promote` only when the item's observation is younger than
  `opts[:observation_max_age_ms]` (plan §5.4).
- `{:declined, :unauthorized}` in claims for a promoted item → state
  `:promoted_unauthorized` + `attention_open`.
- Attention actions are emitted only on latch transitions (latch absent →
  `attention_open`; cause gone and latch present → `attention_resolve`).
- Actions are sorted by rank (C2-T03) so promotion writes follow start order.
- **Idempotence:** feeding the outputs' effects back (labels and intents as
  the actions would leave them) yields an empty action list.

## Implementation steps

1. `planner.ex` with `Input` struct, `derive_state/2`, `actions/2`.
2. Property test generator in `test/support` (PROPOSED).

## Non-happy paths

Stale observation → no promote; unknown claims (`:unavailable`) → no
`withdraw`, hold kept; cyclic or unknown verdicts never produce writes.

## Compatibility and rollout

New pure module.

## Verification

| Test (`src/test/aiur/build_queue/planner_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "ready + marker-only + fresh observation → promote" | `[{:promote, id}]` | rule 9 |
| "ready but stale observation → no action" | `[]` | the age guard |
| "todo applied by someone else on a waiting item → mark_override" | action | rule 4 (intent matching) |
| "queue-promoted item whose todo vanished → mark_external_hold, never promote" | action; no promote | rule 5 |
| "promoted item whose prerequisite reopened → begin_withdraw" | action | rule 10 |
| "claims :unavailable during withdraw → no withdraw" | no `withdraw` | the claims check |
| "parked marker holds a ready item (OQ-3)" | state `:held` | rule 8 |
| "unauthorized decline → attention_open once; second plan with latch → none" | one action, then `[]` | latch check |
| property "plan is idempotent" | second action list empty | the derivation |

Mutation check: remove the intent matching in rule 4 → test 3 fails; remove the
latch check → test 8 fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_queue/planner_test.exs
```

## Completion and handoff

- [ ] Planner covers every contract §2.3 state; idempotence property holds.
- Dependents: C3-T03..T07, C5.
