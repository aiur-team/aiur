---
ticket_id: MP-E1-C3-T03
feature_id: MP-E1
chunk_id: MP-E1-C3
bucket: 2-platform
title: Queue server - supervision, triggers, reconcile loop and Hints ownership
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C3-T02, MP-E1-C2-T04, MP-E1-C1-T03, MP-E1-C1-T05, MP-E1-C1-T06]
prior_units: [U2, U3]
prior_boundaries: [BO #30, BUS #10]
prior_features: [MP-R2]
prior_findings: [MP-E1 F2, F7, F8]
size_owner: "APP_BOOT / Repository support (src/lib/aiur.ex, 600 lines; provisional, RC-23)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C3-T03 — `Aiur.BuildQueue.Server`: the reconcile loop

> **Plan refresh (wave 0).** Cites `45a290e3`. After MP-R2-C3 the Exchange
> subscription comes from the `aiur_events` package with the same API; after
> MP-R1 the child moves into the `build-queue` component's own supervisor.

## Identity and outcome

- Bucket 2, MP-E1, C3, T03.
- **User value:** the queue reacts to a merge or a poll within one reconcile
  and does nothing at all when disabled or unsupported.
- **Deliverable:** PROPOSED `src/lib/aiur/build_queue/server.ex` (GenServer)
  and the facade `src/lib/aiur/build_queue.ex` (`Aiur.BuildQueue`):
  - starts only when `recording?` (`src/lib/aiur.ex:256`), `build_queue.enabled`,
    and the tracker is label-capable;
  - owns the `Hints` ETS table (`:protected`, `read_concurrency: true`);
  - reconcile = load observations → `Planner.plan/1` → hand actions to the
    executors of C3-T04..T07 (this ticket ships a no-op executor that only
    records planned actions, so it is mergeable alone) → write `Hints` →
    broadcast `{:build_queue_changed, status}` on PubSub `"build_queue:changed"`;
  - `status/0` (`:running | :disabled | :unsupported_tracker | :store_unavailable | :writes_paused`).
- **Non-goals:** label writes (C3-T04), CLI (C6).

## Dependencies and blockers

- DESIGN-E1, C3-T02, C2-T04, C1-T03 (observation + signal), C1-T05 (Hints),
  C1-T06 (ClaimProbe).

## Verified starting point (`45a290e3`)

- Children list: `src/lib/aiur.ex:419-481`; Orchestrator at `:442`;
  `recording_children/1` `:503-504`; `recording?` `:256`. Nil children are
  rejected (`:482-483`), so `if(cond, do: Aiur.BuildQueue.Server)` works.
- Exchange: `events/exchange.ex:69-73` `subscribe/2`; delivery
  `send(pid, {:event, event})` (`:92-108`); subscriber reaped on exit.
- Topics today: `ticket.<id>.pr.merged` (webhook normalizer
  `events/github_webhook/normalizer.ex:645-652`),
  `ticket.<id>.issue.label.added.agent.<state>` (`orchestrator/issue_sync.ex:1087-1094`),
  `ticket.<id>.agent.attention.error-<cause>` (`:1078-1079`),
  `ticket.<id>.dependency.merged_blocker_reconciled`
  (`orchestrator/merged_ticket_reconciler.ex:398`).
- PubSub `"tracker:open_issues"` (C1-T03). `Aiur.Tracker.adapter/0`
  (`tracker.ex:162-168`); Linear answers `{:error, :unsupported}`.

## Chosen design

- **Triggers** (all just schedule one coalesced reconcile, debounced 2 s):
  `{:open_issues_recorded, _}`; `{:event, _}` for `ticket.*.pr.merged`,
  `ticket.*.issue.label.added.agent.*`, `ticket.*.agent.attention.#`,
  `ticket.*.dependency.merged_blocker_reconciled`; a timer every
  `reconcile_interval_seconds`; an explicit `reconcile_now/0`. Events are hints
  (contract §1 rule 3); a duplicate just re-runs an idempotent plan.
- **Injection for tests:** `start_link(opts)` accepts `:tracker` (module with
  the `Aiur.Tracker` facade functions), `:claim_probe`, `:store`,
  `:clock`, `:name`. Defaults are the real modules.
- **Capability check at init:** `tracker.open_issue_labels(1)` returning
  `{:error, :unsupported}` → status `:unsupported_tracker`, no Hints table,
  no timers.
- **Store failure at init** → `:store_unavailable`, Hints table created empty
  (neutral), no writes.
- `Hints` rows rewritten each reconcile from `Ordering.hint/2` and the hold
  set; removed for items no longer queued.

## Implementation steps

1. `build_queue.ex` facade: `status/0`, `show/1` (stub until C6-T01),
   `reconcile_now/0`.
2. `server.ex` init/handle_info/handle_call; observation assembly calls
   `tracker.open_issue_labels(max_age_ms)` (C4 adds the other callbacks).
3. `src/lib/aiur.ex`: one child line after the Orchestrator, gated.
4. Tests below.

## Non-happy paths

- Orchestrator absent → ClaimProbe `:unavailable` → holds kept, no withdraw.
- Exchange not running at init → retry subscribe on the timer; reconcile still
  runs from the timer and the PubSub signal.
- Crash → supervisor restarts; Hints table dies with the process (no orphan
  holds); C3-T07 recovers intents.

## Compatibility and rollout

`build_queue.enabled: false` → no child, no table: dispatch order unchanged
(AC8). Rollback = disable.

## Verification

| Test (`src/test/aiur/build_queue/server_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "unsupported tracker starts in unsupported_tracker and creates no hints" — fake tracker answering `{:error, :unsupported}` | `status() == :unsupported_tracker`; `:ets.whereis(Hints.table_name()) == :undefined` | the capability check |
| "an open_issues_recorded signal triggers one reconcile" | planner called once within 3 s for two signals 100 ms apart | the debounce |
| "a ticket.N.pr.merged event triggers reconcile" | reconcile counter +1 | the Exchange binding |
| "hints reflect ordering" — two ready items with different downstream counts | `Hints.sort_key/1` values | the hints write |
| `src/test/aiur/application_test.exs` "build queue child absent when disabled" | child not in `Supervisor.which_children(Aiur.Supervisor)` | the gate |

Mutation check: drop the gate → the application test fails; remove the
capability check → test 1 fails.

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/build_queue/server_test.exs test/aiur/application_test.exs
```

## Completion and handoff

- [ ] Server supervised and gated; triggers; Hints ownership; status.
- Docs: none yet (behaviour visible from C3-T04 on).
- Dependents: C3-T04..T07, C4, C5, C6-T01, C7-T02, C8-T01.
