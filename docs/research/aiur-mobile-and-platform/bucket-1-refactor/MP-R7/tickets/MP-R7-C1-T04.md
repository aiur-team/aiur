---
ticket_id: MP-R7-C1-T04
feature_id: MP-R7
chunk_id: MP-R7-C1
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: R7 characterization suite (single-writer lock coverage, one command)
status: ready
blocked_by: [DESIGN-R7, MP-R7-C1-T01, MP-R7-C1-T02, MP-R7-C1-T03]
prior_units: [U4]
prior_boundaries: [RUN (18), CA (20)]
prior_features: []
prior_findings: [MP-R7 plan F4, F11]
size_owner: n/a (test tags and a mix alias only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C1-T04 — R7 characterization suite

## Identity and outcome

- Bucket 1, MP-R7, chunk C1, ticket T04.
- **Changed from chunks.md:** the planned "single-writer lock test" already
  exists (see below), so writing it again would be a duplicate. T04 instead
  turns the existing lock tests plus T01–T03 into **one named suite** that
  every later R7 PR (C2–C4) and MP-E7-C3 runs unchanged before and after
  (acceptance criterion 2 of the R7 plan).
- **Deliverable:** `@moduletag :r7_characterization` on the existing lock and
  drain tests; a documented single command; a CI step that runs it.
- **Non-goals:** no new behaviour test; no production change.

## Dependencies and blockers

- Blocked by **DESIGN-R7** and by C1-T01..T03 (their files carry the tag).
- Dependents: C2-T01..T03, C3-*, C4-*, MP-E7-C3 (each PR body quotes the
  suite result before and after).

## Verified starting point (base `45a290e3`)

Single-writer lock (`app_server/operator_delivery.ex:41-51`) is already
covered three ways:

- `src/test/aiur/app_server/operator_delivery_test.exs:47-62`
  "checkpoint is skipped while a parent provider turn is live" (unit).
- `src/test/aiur/coding_agent_checkpoint_test.exs:12-40` — Codex and Claude
  adapters do not open a second `turn/start` while the parent turn is live
  (#1247 regression, fake app-server trace).
- `coding_agent_checkpoint_test.exs:45-65` — a deliver-now update interrupts
  the parent turn instead (`turn/interrupt`).

Turn-boundary delivery after the parent turn is covered by
`src/test/aiur/agent_runner/queue_drain_test.exs:321` "a deferred check-in is
delivered as exactly one follow-up turn after the parent turn completes".
Interrupt state machine: `app_server/interrupts_test.exs:14-48`. Queue item
flags: `agent_queue_test.exs:93-127`. Policy normalization:
`orchestrator/operator_messages/delivery_policy_test.exs:7-38`. Accepted sets:
`orchestrator/operator_messages/capabilities_test.exs:8-65`.

CI: `.github/workflows/ci.yml:291-292` runs the suite as the 4-way
`coverage-partition` matrix. A new tag adds no exclusion, so tagged tests
still run in that job. `CONTRIBUTING.md` has a `## Testing` section (:66).

## Chosen design

A tag, not a new directory: moving tests would itself be a refactor that
breaks blame and partition balance. The suite is
`mix test --only r7_characterization`. A separate CI step is **not** added
(the tagged tests already run in the normal partitioned job); instead each R7
PR body reports the tagged run, which the reviewer checks. This keeps CI cost
unchanged (AGENTS.md "A claimed saving must be measured" — no claim made).

## Implementation steps

1. Add `@moduletag :r7_characterization` to:
   `app_server/operator_delivery_test.exs`, `coding_agent_checkpoint_test.exs`,
   `app_server/interrupts_test.exs`, `agent_queue_test.exs`,
   `orchestrator/operator_messages/delivery_policy_test.exs`,
   `orchestrator/operator_messages/capabilities_test.exs`,
   `agent_runner/queue_drain_test.exs` (all under `src/test/aiur/`).
2. Add a "Harness characterization suite" paragraph to `CONTRIBUTING.md`
   under its testing section naming the command and the rule "must pass
   unchanged before and after every MP-R7 PR". (C6-T1 later folds this into
   the add-a-harness guide.)
3. Record the baseline: run the suite at the merge base and paste the test
   count in the PR body.

## Non-happy paths

- A tagged file that is `async: false` and touches global names
  (`agent_chat_broadcast_test.exs` pattern) still works under `--only`;
  no change in isolation.
- `--only` on a partition with zero tagged tests prints "0 tests"; that is
  not a failure. The PR body must show the non-zero full count.

## Compatibility and rollout

n/a — tags and one contributor paragraph.

## Verification

- Command (from `src/`): `mise exec -- mix test --only r7_characterization`
  — expected: all pass at `45a290e3` + T01–T03, count recorded.
- Mutation: revert `operator_delivery.ex:48-51` (the lock clause) in a
  worktree; `--only r7_characterization` must fail
  (`checkpoint is skipped while a parent provider turn is live` and both
  `coding_agent_checkpoint_test.exs` lock tests). This proves the suite
  contains the lock guard.

## Completion and handoff

- [ ] Seven files tagged; suite command documented in `CONTRIBUTING.md`.
- [ ] Baseline count and the lock mutation witness in the PR body.
- Docs: `CONTRIBUTING.md` only (engineering norm, not user docs).
- Dependents: every later R7 ticket cites the suite count before/after.
