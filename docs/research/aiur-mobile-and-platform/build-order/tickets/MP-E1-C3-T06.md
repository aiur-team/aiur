---
ticket_id: MP-E1-C3-T06
feature_id: MP-E1
chunk_id: MP-E1-C3
bucket: 2-platform
title: Competing writers - manual promotion, external hold, marker removal
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C3-T04]
prior_units: [U2]
prior_boundaries: [BO #30]
prior_features: []
prior_findings: [MP-E1 F1, F2]
size_owner: n/a (build_queue files only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C3-T06 — Never fight another label writer

> **Plan refresh (wave 0).** Pure queue behaviour; moves unchanged after MP-R1.
> The second `agent:todo` writer (`aiur --todo`) is sanctioned (RC-20).

## Identity and outcome

- Bucket 2, MP-E1, C3, T06. Plan §5.8.
- **User value:** the Executor's or a human's hand edits win; the queue shows
  them and stops managing that item until `aiur queue release` (AC7).
- **Deliverable:** executors for `mark_override`, `mark_external_hold`,
  `dequeue`, and the `release/1` server call that clears them.

## Dependencies and blockers

- DESIGN-E1 (copy of the states), C3-T04 (intents exist to compare against).

## Verified starting point (`45a290e3`)

- Own writes are invisible on the bus (daemon actor filtered,
  `events/publisher.ex:405-423`, F2) — so detection compares observations with
  recorded intents, not events.
- `aiur --todo [--only]` adds `agent:todo` with the daemon credential and
  `--only` removes it from up to 50 other pending tickets
  (`agent_control_cli.ex:854-893, 1082-1158`) — both look "external" to the queue.

## Chosen design

| Observed change (no matching intent within the last 2 reconciles) | Item becomes | Queue then |
| --- | --- | --- |
| `todo` appears on a waiting item | `overridden` (`override: :manual_promotion`) | no promote/withdraw for it |
| `todo` disappears from a queue-promoted, unclaimed item | `held` (`hold: :external`) | never re-adds |
| marker disappears | removed (dequeued) | edges to it dropped; dependents re-evaluated |
| other state label | `claimed` (C2-T04 rule 3) | read-only |

`release(id | queue)` clears `override` and `hold` (operator or external) and
reconciles. A matching intent means: same issue, action whose
`target_labels` equal the observed set, outcome `:ok` or pending.

## Implementation steps

1. Server executors (state bookkeeping only; no tracker calls).
2. `Aiur.BuildQueue.release/1` facade + server call.

## Non-happy paths

- **Daemon `--todo` on a queued item:** treated as manual promotion (the
  queue cannot tell the daemon's `--todo` from its own except by intent);
  C6-T02 docs say so.
- **Marker removed by mistake:** item leaves the queue; `queue add` re-adds
  (position at end).

## Compatibility and rollout

No config.

## Verification

| Test (`src/test/aiur/build_queue/competing_writers_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "AC7: Executor removes todo from a promoted item → never re-added until release" | 5 reconciles: zero promote calls; after `release/1`, one promote | external-hold executor |
| "manual todo on a waiting item → overridden, no withdraw even when not ready" | zero remove calls | override executor |
| "marker removed → item dequeued and its dependent re-planned" | item gone; dependent verdict recomputed | dequeue executor |
| "queue's own promote is not mistaken for an override" | state `promoted` | intent matching |

Mutation check: skip intent matching → test 4 fails (own write seen as override).

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_queue/competing_writers_test.exs
```

## Completion and handoff

- [ ] AC7 green. Docs: state names documented with C6-T01/C9-T02.
- Dependents: C6-T02 (`release` verb), C8-T01 (states).
