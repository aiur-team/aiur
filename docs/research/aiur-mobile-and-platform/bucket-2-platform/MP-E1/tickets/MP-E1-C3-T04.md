---
ticket_id: MP-E1-C3-T04
feature_id: MP-E1
chunk_id: MP-E1-C3
bucket: 2-platform
title: Write protocol - intents, conditional promotion, marker writes, pacing and budget pause
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C3-T03, MP-E1-C1-T01, MP-E1-C1-T04]
prior_units: [U2, U5]
prior_boundaries: [BO #30, DSP #13]
prior_features: []
prior_findings: [MP-E1 F1, F2, F11, RQ-3, RQ-4]
size_owner: "GH_TRUST (github/tracker.ex, small addition; provisional, RC-23)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C3-T04 — Promotion and marker writes

> **Plan refresh (wave 0).** **RC-20:** the queue is a sanctioned caller of the
> single label-writer seam. Before U2 it writes through
> `Aiur.Tracker.update_issue_state/3`, `add_label/2`, `remove_label/2` (the
> existing `GitHub.IssueState` path); after U2 it calls U2's writer. U2's "no
> second label writer" exit means no second writing *implementation*.
> **Release order:** C1-T01 must already be in a shipped release (plan §8).

## Identity and outcome

- Bucket 2, MP-E1, C3, T04.
- **User value:** every ready item gets `agent:todo` within one reconcile, in
  start order, without exceeding GitHub's write limits; nothing is written on
  stale data or over someone else's label (D4, plan §5.4). AC1, AC2, AC10.
- **Deliverable:** the `promote` and `mark`/`unmark` action executors in the
  server, plus the intent protocol and pacing; a one-time label ensure through
  a new optional tracker callback `ensure_labels/1`.

## Dependencies and blockers

- DESIGN-E1, C3-T03, C1-T01 (marker registered), C1-T04 (`expected_state: :none`).

## Verified starting point (`45a290e3`)

- `Aiur.Tracker.update_issue_state/3` (`tracker.ex:86-107`) →
  `GitHub.IssueState.update_issue_state/3` (`github/issue_state.ex:14-36`),
  re-reads before writing, add-before-remove, markers kept (`:199-219`, F2).
- `Aiur.Tracker.add_label/2`, `remove_label/2` (`tracker.ex:109-117`); GitHub
  `POST .../labels` and `DELETE .../labels/:name`, 404 = success
  (`issue_state.ex:38-91`).
- Error shapes on budget or rate limits: `{:github, :rate_limited | :local_hold, _}`
  and `{:aiur, :locally_held, _}` (`github/errors.ex:26-27, 195-205`); the queue
  matches these tuples as data, without referencing the module.
- `Labels.ensure/5` treats 422 `already_exists` as success
  (`github/labels.ex:154-194`).
- `Orchestrator.note_queued_demand/1` collapses idle backoff (F1;
  `orchestrator.ex:433-437`), reached through `ClaimProbe.notify_demand/1` (C1-T06).
- GitHub secondary limit: 80 content-generating requests/min, 500/hour
  (F11; https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api, accessed 2026-10-06).

## Chosen design

**Intent protocol** (per write):

1. Append `Intent{action, issue_id, target_labels, recorded_at_ms}` and
   `Store.save/1`. If the save fails, do not write.
2. Call the tracker:
   - `promote` → `update_issue_state(id, "todo", expected_state: :none)`;
   - `mark` (queue add) → `add_label(id, marker)`;
   - `unmark` (queue remove/clear) → `remove_label(id, marker)`.
3. Record the outcome on the intent and save. Successful promote → set
   `item.promoted_at`; publish via C5-T03 once that exists.

**Pacing:** a token bucket of `max_writes_per_minute`; actions beyond it wait
for the next window in rank order. 30 ready items at 20/min take two windows.

**Errors:**

| Result | Effect |
| --- | --- |
| `{:error, {:stale_issue_state, :none, _}}` | not an error; item re-observed next reconcile (becomes claimed/overridden) |
| `{:error, {:no_state_label_written, _}}` | issue closed; re-observe |
| budget/rate-limit tuples above | status `:writes_paused`, all writes stop until the next reconcile succeeds a probe write; read model shows `writes paused (github budget)` |
| other error | retry with backoff (1 s, 4 s, 16 s) max 3 per reconcile; consecutive failure count per item; at 5 → `write_failed` attention (C5-T02) |

**Ensure label:** before the first `mark` per daemon boot, call
`tracker.ensure_labels([marker])`. GitHub implementation (in
`github/tracker.ex`): `Labels.ensure(owner, repo, token, labels)`. Memory: `:ok`.
Linear: `{:error, :unsupported}`. A failed ensure refuses the add with the
GitHub error (no partial marker writes).

**After a promote batch:** `ClaimProbe.notify_demand(promoted_ids)`.

**Cost (no saving claimed):** per promotion, at most three conditional
`GET /issues/:n` (C1-T04) + one `POST`; per mark/unmark, one call.

## Implementation steps

1. `build_queue/writer.ex` (PROPOSED): intent bookkeeping, pacing bucket,
   error classification, executor functions.
2. Server wires `promote/mark/unmark` actions to the writer.
3. `tracker.ex`: optional `@callback ensure_labels([String.t()])`; GitHub,
   memory, Linear implementations.

## Non-happy paths

- **Crash between write and outcome:** intent has no outcome; C3-T07 resolves
  it by observation (AC11).
- **Promotion races a human relabel:** the conditional write refuses
  (`:stale_issue_state`).
- **Duplicate trigger:** planner yields no promote for an item whose todo is
  already present (AC10).
- **Authorization:** unchanged; the dispatcher decides (C5-T04 reports denials).

## Compatibility and rollout

First ticket that writes labels. Requires C1-T01 in a prior release.
Disabling the queue stops all writes immediately.

## Verification

Fake tracker (`src/test/support/build_queue_fake_tracker.ex`, PROPOSED) records
every call and holds label sets; it implements `:none` semantics like C1-T04.

| Test (`src/test/aiur/build_queue/writer_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "AC1: A then B-after-A — only A promoted; after A closes completed, B promoted next reconcile" | call log `[{:update_issue_state,"A","todo",[expected_state: :none]}]` then `B` | promote executor |
| "AC2: three ready items written in one pass, in rank order" | three calls ordered by downstream count | rank-ordered execution |
| "pacing: 30 ready at 20/min → 20 now, 10 after the window" (injected clock) | counts | the bucket |
| "intent saved before the call; save failure → no call" | store saw intent first; zero calls when save fails | step 1 ordering |
| "stale_issue_state is not counted as a failure" | failure count stays 0 | the classification |
| "local_hold error pauses writes" | status `:writes_paused`; no further calls | the pause branch |
| "five consecutive failures raise write_failed once" | one attention action | the counter |
| `src/test/aiur/github/tracker_ensure_labels_test.exs` (PROPOSED) "422 already_exists counts as ensured" | `:ok` | the callback delegating to `Labels.ensure/5` |

Mutation check: write before saving the intent → test 4 fails; remove the
bucket → test 3 fails.

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/build_queue/writer_test.exs test/aiur/github/tracker_ensure_labels_test.exs
```

## Completion and handoff

- [ ] AC1, AC2, AC10 green against the fake tracker.
- [ ] PR body states the per-promotion request cost and claims no saving.
- Docs: the CLI and concept pages land with C6/C9; this ticket adds a
  "build queue writes" line to `website/docs-app/apis/github.md` (what is
  written, how often, paced at `max_writes_per_minute`) because it changes
  what Aiur sends to GitHub (AGENTS.md "Auth").
- Dependents: C3-T05..T07, C4-T02, C5-T03, C5-T04, C6-T02.
