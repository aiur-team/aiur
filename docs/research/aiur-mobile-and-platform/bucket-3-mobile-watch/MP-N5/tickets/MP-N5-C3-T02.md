---
ticket_id: MP-N5-C3-T02
feature_id: MP-N5
chunk_id: MP-N5-C3
bucket: 3-mobile-watch
title: Hourly cap for non-Command notifications per (device, instance)
status: ready
blocked_by: [DESIGN-N5 (no-UI release), MP-N5-C3-T01]
prior_units: []
prior_boundaries: [new #41 candidate push-relay]
prior_features: []
prior_findings: [N5 plan §5.5 cap 6/hour; relay per-handle limit 60/hour (MP-N4-C2-T04)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C3-T02 — Hourly cap

## Identity and outcome

Bucket 3, MP-N5, chunk C3. At most 6 non-Command notifications per instance per device per
rolling hour; excess intents fold into the next digest (C3-T01) instead of being dropped
silently. Commands (`command.needs_you`, `command.resolved`) are never capped.

## Dependencies and blockers

C3-T01. DESIGN-N5 no-UI release.

## Verified starting point

N5 plan §5.5; the relay's own per-handle limit (60/h, burst 10; MP-N4-C2-T04) is a
backstop, not the policy.

## Chosen design

Sliding window counter per `(device_id, instance_id)` in the policy process (persisted
with the ledger so a restart cannot reset the cap); fold = add to the pending digest
counts with a `capped: true` marker.

## Implementation steps

`policy/cap.ex` (PROPOSED) + tests.

## Non-happy paths

Clock jump backwards → window entries with future timestamps are dropped.

## Compatibility and rollout

Constant in v1 (no config); documented in the guide (C5-T01).

## Verification

`src/test/aiur/push/policy/cap_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"seventh progress notification in an hour folds into digest"` | 6 sent, 7th counted in digest | drop the 7th |
| `"Commands are never capped"` | 10 Commands → 10 intents | cap all kinds |
| `"cap survives restart"` | after restart 7th still folded | in-memory only |

Commands (from `src/`): `mise exec -- mix test test/aiur/push/policy/cap_test.exs`.

## Completion and handoff

- [ ] Dependents: C5-T01 (document the cap).
