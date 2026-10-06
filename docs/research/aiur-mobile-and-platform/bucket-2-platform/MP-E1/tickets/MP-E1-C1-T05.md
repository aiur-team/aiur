---
ticket_id: MP-E1-C1-T05
feature_id: MP-E1
chunk_id: MP-E1-C1
bucket: 2-platform
title: Hints table and the DispatchPolicy rank and hold hook
status: blocked
blocked_by: [DESIGN-E1]
prior_units: [U2]
prior_boundaries: [DSP #13, ORC #12]
prior_features: []
prior_findings: [MP-E1 F3, X-1]
size_owner: "LIFECYCLE_DISPATCH / Ticket lifecycle and dispatch (orchestrator/dispatch_policy.ex, 1213 lines; provisional, RC-23)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C1-T05 — `Aiur.BuildQueue.Hints` and the `DispatchPolicy` hook

> **Plan refresh (wave 0).** Cites `45a290e3`. This is RC-11 edge 1 (the rank
> and hold lookup). After MP-R1, `DispatchPolicy` becomes package
> `aiur_dispatch_policy` and `Hints` a published port of `build-queue`. U2
> rebases over this hook and keeps it (RC-19).

## Identity and outcome

- Bucket 2, MP-E1, C1, T05.
- **User value:** among ready tickets, the one that unblocks the most
  downstream work starts first (D3), and a ticket being withdrawn cannot start
  in the window before its label is removed (D8).
- **Deliverable:**
  1. PROPOSED `src/lib/aiur/build_queue/hints.ex`, `Aiur.BuildQueue.Hints`:
     `table_name/0`, `sort_key(issue_id) :: {integer(), non_neg_integer()}`
     (default `{0, 0}`), `held?(issue_id) :: boolean()` (default `false`).
     Reads only; the table is created and written by the queue server (C3-T03).
  2. `DispatchPolicy.sort_issues_for_dispatch/1` key becomes
     `{d, priority_rank, position, created_at, identifier}` where
     `{d, position} = Hints.sort_key(issue.id)`.
  3. New decline reason `:build_queue_hold`, first clause of
     `dispatch_state_decision/4`.
- **Non-goals:** no queue server; nothing writes the table yet.

## Dependencies and blockers

- DESIGN-E1 (gate; OQ-1 fixes where `position` sits — this ticket implements
  the recommended "after priority, before age"; if OQ-1 differs, move the
  `position` element accordingly).
- Concurrent with C1-T01..T04, T06 and C2. C1-T07 depends on this (first
  module under `build_queue/`).

## Verified starting point (`45a290e3`)

- `src/lib/aiur/orchestrator/dispatch_policy.ex:609-618`
  `sort_issues_for_dispatch/1` key `{priority_rank, created_at_key, identifier}`;
  `:620-630` helpers. Callers: `orchestrator/dispatcher.ex:1004`,
  `orchestrator/issue_sync.ex:2123`.
- `:644-664` `t:dispatch_decline_reason/0`; `:672-697`
  `@dispatch_decline_reasons` / `dispatch_decline_reasons/0`.
- `:862-878` `dispatch_state_decision/4` (`blocked_on_decision` first).
- `orchestrator/pause_resume.ex:2180-2209` `resume_decline_reason/4`
  (fallback `{:unmapped_dispatch_decline, _}` with a warning).
- `src/test/aiur/orchestrator/resume_decline_reason_test.exs:18-52`: every
  reason needs a translation, the list must equal the typespec, and every
  `{:skip, :x}` literal in the source must be in the list.
- `src/test/aiur/orchestrator/dispatch_policy_test.exs:345-368` sort test.
- Absent-table pattern: `github/open_issue_snapshot.ex:43-47, 70-77`
  (`rescue ArgumentError`).
- `Issue.id` is the GitHub number as a string (`github/issues.ex:987`).

## Chosen design

- **Splice, do not prepend.** The plan's earlier "prepend `Hints.rank/1`,
  `{0}` when absent" would be wrong: Erlang orders tuples by size before
  elements (https://www.erlang.org/doc/system/expressions.html#term-comparisons,
  accessed 2026-10-06), so a 1-tuple default sorts before every 5-tuple. Two
  integers spliced into the existing key keep one tuple shape for every issue.
- `d = -downstream_open` (more dependents → smaller → first). Non-queue
  tickets get `{0, 0}`, so with no table, or an empty table, the key equals
  today's key with two constant zeros: identical order (AC8).
- `held?/1` is checked first in `dispatch_state_decision/4`:
  `Hints.held?(issue.id) -> {:skip, :build_queue_hold}`. Hold only blocks a
  start; it never removes a running agent.
- `resume_decline_reason(:build_queue_hold, …) -> :build_queue_hold` so
  `aiur resume` says why.
- ETS reads are O(1) per issue; the sort runs on the candidate list only.

## Implementation steps

1. `build_queue/hints.ex`: module with `@table :aiur_build_queue_hints`,
   rows `{issue_id, {d, position}, held?}`; reads rescue `ArgumentError`.
2. `dispatch_policy.ex`: alias, new key, new clause, type and list entries
   (≈ 12 lines).
3. `pause_resume.ex`: one clause.
4. Tests below.

## Non-happy paths

- **Table absent / server down:** defaults → today's order, no holds.
- **Stale hold left by a crashed server:** the table dies with its owner
  (ETS ownership), so no orphan hold survives a server crash.
- **Manual start (`manual_resume_decision/2`, `:730-748`)** also goes through
  `dispatch_state_decision/4`, so the hold covers it; documented in C6-T02.

## Compatibility and rollout

No config. With the queue disabled the behaviour is byte-identical.

## Verification

| Test | Expected | Fails without |
| --- | --- | --- |
| `dispatch_policy_test.exs` "sort is unchanged with no hints table" — 20 issues with mixed priority/dates, compare to the sort computed with the pre-change key written inline in the test | equal lists | (guard; must pass before and after — declared regression guard) |
| "a queue item with downstream 3 precedes a priority:1 non-queue item" — insert `{"7", {-3, 0}, false}` into a test-owned table | `"7"` first | the spliced `d` element |
| "list position orders equal-priority queue items before age" | lower position first despite newer `created_at` | the `position` element |
| "a held issue is declined with :build_queue_hold" via `dispatch_decision/5` | `{:skip, :build_queue_hold}` | the new clause |
| `resume_decline_reason_test.exs` (existing) | passes with the new reason | the `pause_resume.ex` clause (first test fails) |

Mutation check: revert the sort hunk → tests 2–3 fail; revert the clause → test
4 fails; revert the pause_resume clause → the existing totality test fails.

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/orchestrator/dispatch_policy_test.exs test/aiur/orchestrator/resume_decline_reason_test.exs
```

## Completion and handoff

- [ ] `Hints` reader shipped; sort and hold hook in `DispatchPolicy`;
      `aiur resume` translation.
- [ ] Production lines in `dispatch_policy.ex` ≤ ~15 (U8 debt).
- Docs: none yet (the `aiur resume` message is documented with C6-T02).
- Dependents: C1-T07, C3-T03, C3-T05.
