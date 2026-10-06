---
ticket_id: MP-E1-C1-T02
feature_id: MP-E1
chunk_id: MP-E1-C1
bucket: 2-platform
title: Treat the queue marker as deliberate parking in the zero-label heal and strand sweep
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C1-T01]
prior_units: [U2]
prior_boundaries: [ORC #12, DSP #13]
prior_features: []
prior_findings: [MP-E1 F4, F5]
size_owner: "LIFECYCLE_DISPATCH / Ticket lifecycle and dispatch (orchestrator/issue_sync.ex, 2295 lines; provisional, RC-23)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C1-T02 — Queue marker exempts a ticket from the zero-label heal and strand sweep

> **Plan refresh (wave 0).** Cites `45a290e3`. U2 ("give lifecycle one owner")
> rewrites `issue_sync.ex`; per RC-19 the U2 tickets rebase over this hook and
> keep it, and U2's transition owner names the queue as owner of the
> marker-only ↔ todo transition (plan §10). Re-check the size owner when the
> ticket starts (RC-23).

## Identity and outcome

- Bucket 2, MP-E1, chunk C1, ticket T02.
- **User value:** a ticket waiting in the queue keeps waiting. Without this,
  the poll either writes `agent:todo` back onto it or raises a
  `state-label-missing-no-evidence` attention on it every poll.
- **Deliverable:** `Issue.queued?/1` joins `paused?`/`parked?` in the two
  "deliberate parking" predicates of `IssueSync`.
- **Non-goals:** no change to what counts as a strand for unqueued tickets.

## Dependencies and blockers

- DESIGN-E1 (gate), MP-E1-C1-T01 (`Issue.queued`).
- Must ship in the same release as C1-T01 or later, and before C3-T05
  (withdrawal), which depends on it to keep a withdrawn item marker-only.
- Concurrent with C1-T03..T06 and C2.

## Verified starting point (`45a290e3`)

- The conditional poll returns every open issue with zero or several state
  labels as "healable" (`src/lib/aiur/github/issues.ex:468-482`,
  `degenerate_state_labels?/1`). A marker-only item has `state_labels: []`,
  so it reaches the heal.
- `src/lib/aiur/orchestrator/issue_sync.ex:392-410`
  `heal_or_leave_missing_state_label/3`: exempts `Issue.paused?`,
  `Issue.parked?`, `parked_marker?/1`; otherwise restores the last known state
  from `running` or `last_polled_issues` (`:435-458`), or raises
  `alert_missing_state_label_no_evidence/2` (`:501-519`).
- `:200-207` `legitimately_unowned?/1` (strand sweep, called from `:165`).
- Called from `reconcile_contradictory_state_labels/3` (`:71-107`, heal at `:93`)
  and `sync_stranded_ticket_reconciliation/3` (`:147-158`).
- Test pattern to copy: `src/test/aiur/orchestrator/issue_sync_test.exs:2477-2510`
  "leaves an agent:paused zero-label ticket alone and raises no attention
  alert" (#2610).

## Chosen design

Add `Issue.queued?(issue)` to the first `cond` arm of
`heal_or_leave_missing_state_label/3` and as one more `or` term in
`legitimately_unowned?/1`. Rationale: the marker is the queue's statement that
the ticket deliberately has no state label (plan §5.2); this is the same rule
#2610 applied to `agent:paused`. A ticket carrying marker **and** a state label
is not affected (it never reaches the zero-label heal).

Invariant: an issue with `queued: true` and `state_labels: []` is never
rewritten by `IssueSync` and never alerted on as a missing state.

## Implementation steps

1. `issue_sync.ex:394`: `Issue.paused?(issue) or Issue.parked?(issue) or Issue.queued?(issue) or parked_marker?(issue) -> {issue, state}`.
2. `issue_sync.ex:200-207`: add `Issue.queued?(issue) or`.
3. Update the comment block at `:386-391` to name the queue marker.
4. Two tests (below). About 6 production lines.

## Non-happy paths

- **Rollback** to a release without this hunk while markers exist: marker-only
  items whose previous poll saw `todo` get `agent:todo` back, so they start
  early. The plan §8 runbook (`aiur queue clear --remove-markers`, C6-T03)
  runs before a downgrade.
- **A human strips every state label from a queued ticket by mistake:** it is
  left alone (deliberate). The queue's own competing-writer rules (C3-T06)
  show it.

## Compatibility and rollout

No config. Behaviour changes only for tickets carrying the marker, which no
code writes before C3-T04.

## Verification

| Test (`src/test/aiur/orchestrator/issue_sync_test.exs`) | Expected | Fails without |
| --- | --- | --- |
| "leaves a queued marker-only ticket alone although its last poll was todo" — `%State{last_polled_issues: %{"q" => %{issue("q","todo")}}}`, issue `%{state_labels: [], queued: true, labels: ["agent:queued"]}`, `update_state_fun` = `flunk` | no rewrite; no event on `ticket.<id>.agent.attention.state-label-missing` | the heal-arm hunk (heal calls `update_state_fun.(id, "todo")`) |
| "raises no state-label-missing-no-evidence for a queued ticket" — no prior state, subscribe to the topic | `refute_receive {:event, _}` | the heal-arm hunk (alert fires) |
| "strand sweep treats a queued marker-only ticket as legitimately unowned" via `sync_stranded_ticket_reconciliation/3` with a released claim in `state.released_claims` | no requeue write | the `legitimately_unowned?` hunk |

Mutation check: revert each hunk separately; its test fails; restore. Run in a
worktree with a clean `git status --porcelain` besides the revert.

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/orchestrator/issue_sync_test.exs
```

## Completion and handoff

- [ ] Both exemptions in place; three tests pass and fail under their mutation.
- [ ] Docs: none on their own (the marker row lands in C1-T01; queue docs in C6/C9).
- Dependents: C3-T05 (withdrawal), C3-T06, C9-T03.
