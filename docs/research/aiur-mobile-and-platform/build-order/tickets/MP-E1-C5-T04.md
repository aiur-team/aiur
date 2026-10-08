---
ticket_id: MP-E1-C5-T04
feature_id: MP-E1
chunk_id: MP-E1-C5
bucket: 2-platform
title: Promoted but unauthorized - detect the dispatcher's decline
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C5-T01, MP-E1-C1-T06, MP-E1-C3-T04]
prior_units: [U2, U5]
prior_boundaries: [DSP #13]
prior_features: []
prior_findings: [MP-E1 F1, RQ-7]
size_owner: n/a (build_queue files only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C5-T04 — `promoted_unauthorized`

> **Plan refresh (wave 0).** Uses only the RC-11 ClaimProbe edge.

## Identity and outcome

- Bucket 2, MP-E1, C5, T04.
- **User value:** under a strict `allowed_users`, a daemon-applied `todo`
  without prior human triage never starts; the operator is told which ticket
  needs a human label instead of watching it sit (plan §6 Authorization).
- **Deliverable:** for promoted items, the server reads
  `ClaimProbe.status/1`; `{:declined, :unauthorized}` → state
  `promoted_unauthorized` + `ticket.<id>.queue.attention.promoted_unauthorized`.

## Dependencies and blockers

- DESIGN-E1 (copy: "a human must apply the marker or `agent:todo`"), C5-T01,
  C1-T06, C3-T04.

## Verified starting point (`45a290e3`)

- Authorization rules: `github/dispatch_authorization.ex:55-73, 127-148, 198-213`
  (F1). Decline `{:skip, :unauthorized}` (`orchestrator/dispatch_policy.ex:846`).
- `:unauthorized` is stored in `dispatch_declines` only while
  `Slots.available_slots/1 > 0` (`orchestrator/dispatcher.ex:1054-1070`).

## Chosen design

- Each reconcile includes promoted, unclaimed items in the `status/1` batch.
- Detection is **conditional on free slots** (the decline is not recorded
  otherwise). The read model shows `promoted` until a slot frees; stated in
  docs. No attempt to re-run authorization from the queue.
- Resolves when the decline disappears (claimed, or authorization fixed).

## Implementation steps

1. Planner rule + server batch inclusion (≈ 25 lines).

## Non-happy paths

Probe `:unavailable` → state unchanged; no attention.

## Compatibility and rollout

None.

## Verification

| Test (`src/test/aiur/build_queue/unauthorized_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "declined :unauthorized → state promoted_unauthorized and one attention" | state + one event | the rule |
| "decline cleared → resolved" | `.resolved` event | resolve |
| "other declines (e.g. :worker_capacity) do not alert" | none | the reason match |

Mutation check: match any decline → test 3 fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_queue/unauthorized_test.exs
```

## Completion and handoff

- [ ] Detection + attention; free-slot condition documented.
- Docs: C9-T02 concept page notes it.
- Dependents: C8-T01.
