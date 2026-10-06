---
ticket_id: MP-R1-C9-T06
feature_id: MP-R1
chunk_id: MP-R1-C9
bucket: 1-refactor
title: Move ReworkRequeue out of the Orchestrator namespace into pr-lifecycle (after U2 names the transition owner)
status: blocked
blocked_by: [DESIGN-R1, RQ-U2-TRANSITION, U2, MP-R1-C9-T05, MP-R1-C1-T02]
prior_units: [U2, U5, U8]
prior_boundaries: [PRL #15]
prior_features: []
prior_findings: [orch-b-24, orch-b-25]
size_owner: LIFECYCLE_STATUS (src/test/aiur/orchestrator/rework_requeue_test.exs, 522 lines); rework_requeue.ex (459) not in the ledger
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C9-T06 — Rework re-queue worker leaves orchestration core

## Identity and outcome

- Bucket 1, MP-R1, chunk C9, prior §7 step 9.
- **User value:** none visible. Same move as C9-T05 for the second periodic PR worker:
  `Aiur.Orchestrator.ReworkRequeue` (`src/lib/aiur/orchestrator/rework_requeue.ex`) becomes
  `Aiur.PRLifecycle.ReworkRequeue` (PROPOSED, `src/lib/aiur/pr_lifecycle/rework_requeue.ex`).
- **Non-goals:** no change to classification (`:addressed`, `:merge_only`,
  `:not_addressed`, `:unknown`, moduledoc `:16-35`), to its alert wording (finding
  `orch-b-25` stays open), or to how the state write is performed.

## Dependencies and blockers

- **RQ-U2-TRANSITION (blocking).** Unlike the PR-health scanner, this worker **writes ticket
  state**: on `:addressed` it moves a ticket from `agent:rework` to `agent:human-review`
  through `Tracker.update_issue_state/2` (`rework_requeue.ex:87`, moduledoc `:17-26`). The
  prior program's open question "Which process owns the authoritative ticket transition?"
  (`docs/research/refactor-2026-09-26/synthesis/open-questions.md:9`) is unanswered at the
  base, and U2's exit criterion is "every stuck state has one owner … no second label
  writer remains". Per RC-20 the worker may stay a **caller** of the single label-writer
  seam, but whether its *decision* to re-queue belongs to `pr-lifecycle` or to U2's
  lifecycle owner is U2's call. Moving it before U2 decides would pick a component for it.
  When U2 lands: if U2 keeps the worker as a seam caller, do this ticket as written; if U2
  folds the decision into its lifecycle owner, close this ticket as superseded and record
  that in MP-R1-C11-T02.
- DESIGN-R1 §1; C9-T05 (same `aiur.ex` area and the `pr-lifecycle` manifest entry).

## Verified starting point (45a290e3)

- `use Aiur.PeriodicWorker` (`rework_requeue.ex:57`), registered under the module name,
  started at `src/lib/aiur.ex:448`, immediately after the PR-health scanner.
- Dependencies: `Alerts`, `Issue`, `Tracker`, `GitHub.Client`, `GitHub.Config`,
  `GitHub.LocalHold`, `GitHub.Tracker` (`:61-65`). No reference to `Aiur.Orchestrator`
  besides its own `defmodule`.
- Reads: `Tracker.fetch_issues_by_states(["rework"])` (`:144`),
  `Tracker.fetch_open_pull_request_for_branch/1` (`:146`). Writes:
  `Tracker.update_issue_state/2` (`:87` default `state_writer`). Gate
  `pr_health_enabled?` and GitHub tracker (`:137`).
- References outside the file: `aiur.ex:448` and `src/test/aiur/orchestrator/rework_requeue_test.exs`.

## Chosen design

Identical to C9-T05: rename + move, same child position (`aiur.ex:448`), no alias, the
`state_writer` default stays the label-writer seam that U2 names (before U2:
`Tracker.update_issue_state/2`; after U2: U2's writer — RC-20). Manifest owner
`pr-lifecycle`.

## Implementation steps

1. Re-read U2's merged decision; confirm the "seam caller" outcome (else close as above).
2. `git mv` the module and its test; rename; update `aiur.ex:448`.
3. Set `state_writer` default to whatever U2 exports as the writer (one line).
4. While moving the 522-line test, split it below 500 (U8 LIFECYCLE_STATUS row): pure
   classification cases (`latest_blocking_review/1`, `classify/3`) to
   `rework_requeue/classify_test.exs`, tick cases stay.
5. `components.json` update.

## Non-happy paths

Unchanged behaviour: refused re-queue raises the needs-attention alert and retries next
tick; transient fetch failure is a no-op; local GitHub hold is honoured via `LocalHold`.

## Compatibility and rollout

No config/flag/disk change. Rollback: revert.

## Verification

```bash
env -C <checkout>/src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/pr_lifecycle/rework_requeue_test.exs test/aiur/pr_lifecycle/rework_requeue \
  test/aiur/application_test.exs
python3 scripts/check-components.py
```

| Test | Expectation | Fails without |
|---|---|---|
| `application_test "rework requeue keeps its position directly after the health scanner"` | adjacent indices | the `aiur.ex` edit |
| `rework_requeue_test "addressed re-queue goes through the lifecycle writer seam"` | the default `state_writer` is the function U2 exports (assert by capture with a stubbed seam module) | step 3 |

Mutation check per AGENTS.md. Manual: wrapper-tmux `aiurdev --test`; a sandbox PR in
`agent:rework` with a new own-diff commit moves to `agent:human-review` at the next tick.

## Completion and handoff

- [ ] U2 decision quoted in the PR body.
- [ ] No `Aiur.Orchestrator.ReworkRequeue` reference remains; test file < 500 lines.
- Docs: none.
- Dependents: C9-T07 table row for the worker. size_owner re-resolved at ticket start
  (RC-23, MP-R1-C11-T02).
