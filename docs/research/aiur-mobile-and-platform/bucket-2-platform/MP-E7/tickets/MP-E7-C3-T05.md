---
ticket_id: MP-E7-C3-T05
feature_id: MP-E7
chunk_id: MP-E7-C3
bucket: 2-platform
title: "Conformance: aiur's Effective and Scheduler agree with the vendored scheduler.v1.json and support vocabulary"
status: ready
repo: aiur-team/aiur
wave: 3
blocked_by: [DESIGN-E7, MP-E7-C1-T04, MP-E7-C2-T02, MP-E7-C3-T02]
prior_units: [U3]
prior_boundaries: [MSG (16)]
prior_features: [integrations-43]
prior_findings: []
size_owner: n/a (test files only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C3-T05 — Shared-spec conformance test

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E7 / C3.
- **User value:** the two products' listener semantics cannot drift silently
  (plan acceptance criterion 5).
- **Deliverable:** `src/test/aiur/listener/conformance_test.exs` (PROPOSED):
  1. For each `scheduler.v1.json` row (via `Aiur.Listener.Spec.scheduler_rows/0`,
     MP-E7-C1-T04), map the row's boundary to aiur's equivalent and assert the
     aiur decision: `tool` boundary → only `steer` may be claimed
     (`claim_next_checkpoint_queue_item_call/2` behaviour from C3-T02);
     `stop` boundary → `steer` and `sync` claimed by the turn-boundary drain;
     any boundary → `async` never claimed and never wakes.
  2. Vocabulary: `Aiur.Listener.Spec.modes/0` equals aiur's mode atoms and
     default (`sync`); every status `Effective` can emit is in
     `support_statuses/0`; `steer_carrier` values are in the schema enum.
  3. Rows aiur does not model (Claude `prompt`-boundary busy rule for hook
     sessions) are listed explicitly in a `@not_applicable` table with a reason
     each, so a new spec row fails until it is classified.
- **Non-goals:** hook envelope goldens (MP-E7-C6-T04).

## Dependencies and blockers

- DESIGN-E7; MP-E7-C1-T04 (vendored spec, which needs the Khala release);
  MP-E7-C2-T02; MP-E7-C3-T02. This is the only wave-3 aiur ticket that waits
  on Khala; C3-T01..T04 do not.

## Verified starting point

- Spec rows and fields are defined by MP-E7-C1-T02 (`harness, event, mode,
  busy, busy_age_ms, continuation, delivers, mark_idle_only`).
- aiur boundaries: tool boundary = safe checkpoint (`agent_runner/checkpoint_delivery.ex:66-88`);
  turn boundary = queue drain (`agent_runner/queue_drain.ex:399-408`); idle =
  `queue_wake_required?/1` (`delivery_policy.ex:177-180`).

## Chosen design

Table-driven ExUnit test, `async: true`, no Orchestrator process: it builds
an `AgentQueueStore` and a `State` fixture, enqueues one item per row's mode
with routing `:listener`, and calls the claim functions for the row's
boundary. Unclassified rows fail with the row printed.

## Implementation steps

1. Add the test and the `@not_applicable` table.
2. Add the file to the coverage shard rules if `scripts/check-test-shard-parity.py` requires it.

## Non-happy paths

- Vendored spec missing → the test fails with "spec unavailable" (no skip).

## Compatibility and rollout

- Test only.

## Verification

```sh
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/listener/conformance_test.exs
python3 scripts/check-test-shard-parity.py
```

Mutation checks: remove the `:sync` exclusion from the checkpoint matcher
(C3-T02) → the `tool`/`sync` rows fail; remove the `:pull` skip (C3-T01) →
every `async` row fails; add a fake row with `event: "compact"` to a copy of
the spec in a temp dir → the unclassified-row assertion fails.

## Completion and handoff

- [ ] Conformance test green against the vendored v1 spec.
- Dependents: MP-E7-C4 (adds native steer rows), MP-E7-C5 (async pull rows), MP-E7-C6-T04.
- Docs: none.
