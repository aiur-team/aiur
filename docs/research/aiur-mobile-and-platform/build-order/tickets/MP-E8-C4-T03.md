---
ticket_id: MP-E8-C4-T03
feature_id: MP-E8
chunk_id: MP-E8-C4
bucket: 2-platform
title: Steady-state history feed and boot catch-up
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C4-T01]
complexity: 4
design_gate: DESIGN-E8
owns_edge_cases: [EC-10 (source side), EC-31, EC-32]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C4-T03 — Steady-state history feed and boot catch-up

> Cites code at `origin/main` `58854d4c8` (runtime checkout
> `aiur-worktrees/runtime/src`). Paths marked PROPOSED do not exist yet.
> This ticket writes through the C4-T01 store API as the C4-T01 ticket doc
> defines it (§4.1 row, §4.2 merge rule, §4.3 API). If C4-T01 merges with
> different names, follow the merged code and change this ticket's names only.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C4 (durable
  history store), ticket T03.
- **User value.** The home page history stays correct while the daemon runs and
  after a restart. A ticket that closes, reopens, merges or gets a new edge
  shows the change without a page reload. No new periodic GitHub poll pays for
  it.
- **Deliverable.** A feed process that keeps `Aiur.BuildOrder.History` (C4-T01)
  current from data the daemon already receives:
  1. ResourceStore change events for `:issue`, `:issue_labels`,
     `:issue_dependency` and `:sub_issue` (the webhook deposit, the conditional
     issue reads and Aiur's own write-through all land there);
  2. the open-issue poll (one new consumer call beside `OpenIssueSnapshot.put/3`);
  3. `RecentMergeStore` (`merged_at`, PR number);
  4. a local resync from `ResourceEvents`/`ResourceStore.list_type/2` when the
     feed starts;
  5. a boot-only scan of the run telemetry file for `dispatch` points;
  6. one "closed since the checkpoint" GraphQL catch-up per boot, plus a rate-
     limited re-run on the existing `webhook_recovered` and `view_state_diverged`
     signals and once when the backfill completes.
  Every write is an idempotent `History.apply/2` event. Every row it touches gets
  `observed_at` from that event (C4-T01 §4.2).
- **Non-goals.**
  - The store file, row struct, PubSub signal and fail-closed load (C4-T01).
    C4-T01's version-1 row already has `updated_at`, `dispatched_at`, merge
    rule 6, the `:catch_up` source and the closed/`:unknown` lifecycle (see
    "Contract with C4-T01"); this ticket changes nothing in C4-T01's files.
  - The one-time backfill and its checkpoint (C4-T02).
  - Start and end derivation, the live dispatch and label hooks, and "start
    unknown" (C4-T04). This ticket records raw facts only. It never writes
    `start` or `end`.
  - Edge semantics (`terminal_unsatisfied`, `missing`, cycles) (C4-T05).
  - `agent_model` and `agent_effort` (C4-T01 hand-off asks this ticket to feed
    them from telemetry `dispatch`; the `dispatch` point carries no model or
    effort, see decision 10).
  - Any rendering. No UI.
  - Multi-repository history. The feed follows the one tracker repository from
    `Transport.parse_repo/0`, as `AdHocSource` does.

## Dependencies and blockers

- **Blocked by DESIGN-E8** (every MP-E8 ticket, tickets/README.md rules). No
  sign-off item changes this ticket's behaviour.
- **Blocked by MP-E8-C4-T01.** This ticket calls `History.apply/2`,
  `rows/2`, `health/1`, `checkpoint/2` and `subscribe/0`, and extends
  `History.Row`.
- **Not blocked by C4-T02.** It can run in parallel. Until C4-T02 has completed
  (`health.complete?` false), the catch-up does not run and reports
  `:not_backfilled`; live events still apply (C4-T01 accepts writes while
  `complete?` is false).
- **Shared code with C4-T02.** Both parse a GraphQL issue node. C4-T02 names its
  normalizer PROPOSED `Aiur.BuildOrder.History.BackfillQuery` (C4-T02 step 2).
  If C4-T02 has merged, this ticket reuses its node normalizer for the shared
  fields. If not, this ticket creates PROPOSED `History.CatchUpQuery` with a
  `node_to_event/2`, and C4-T02 reuses it. The second ticket to merge removes
  the duplicate.
- **Successors.** C4-T04 (reads the facts this ticket records; reuses the
  `dispatched_at` field this ticket first writes), C8-T04 (subscribes to History's change
  signal and reads `Feeder.catch_up_status/1`; EC-10 needs at most one signal
  per committed change).
- **Concurrent with:** C4-T02, C4-T05, C5, C6, C7, all of the client track.
- **Read first:** `website/docs-app/apis/github.md` (AGENTS.md rule for any
  change that talks to GitHub). The view-state table at `:293-300` sets the
  rule this ticket follows: "Opening, focusing, or holding a page open: zero API
  calls" and "One listing per daemon boot establishes the baseline". `:531`:
  "A delayed delivery carrying older state: Refused."

## Verified starting point (`58854d4c8`)

**ResourceStore is the one place every GitHub writer meets.**
- `src/lib/aiur/github/resource_events.ex:39-48` — a write that leaves stored
  content identical publishes nothing; `:56-59` — "Deletions are silent".
  `:156-171` — `subscribe/1` (a key or a type) and `subscribe/2` (a type in one
  `"owner/repo"`). `:234-271` — `publish/2` and the `change` map: `key`,
  `resource_type`, `owner`, `repo`, `id`, `source`, `version`, `etag`, `data?`,
  `data_version`, `recorded_at_ms`. The body is not broadcast; read it from the
  store.
- `src/lib/aiur/github/resource_store.ex:264` — `@retention_ms 72 h`.
  `:447-463` `key/4` downcases owner and repo, so the per-repo topic uses the
  downcased full name. `:384-392` `@order_sensitive_types` include `:issue`,
  `:issue_labels`, `:sub_issue`, `:issue_dependency`. `:971-975` `drop_data/1`
  publishes a change with no body; readers call it to recover from a `304` too,
  so `data?: false` does **not** mean "deleted". `:1070` `data/1`. `:1208`
  `list_type/2` (only servable bodies). `:1274` `subscribe/1` delegates to
  `ResourceEvents`; there is no `ResourceStore.subscribe/2`.
- `src/lib/aiur/events/github_webhook/deposit.ex:165-214` — `deposit/4`; a
  delivery is deposited before it is published. `:562-588` — an `issues`
  delivery deposits GitHub's issue object under `:issue` and its labels under
  `:issue_labels`, both versioned by the issue `updated_at` (`:981-990`
  `version/1`); a `deleted` action drops both bodies (`:563-567`, `drop/3` at
  `:970-979` calls `drop_data/1`). `:700-710` — edge bodies: `:sub_issue` id
  `"parent:sub"` with `parent_issue_number`/`sub_issue_number`, and
  `:issue_dependency` id `"blocked:blocker"` with
  `blocked_issue_number`/`blocking_issue_number`, each with `"present"` true or
  false. `:712-719` — edges are versioned by arrival time (opt `:at`,
  `:737-742`). `:806-813`, `:866-881` — `deposit_unless_older/3` refuses an
  older version inside the store's swap, so a late edge or body never produces a
  change event.
- `src/lib/aiur/github/issues.ex:154-170` and `:784-800` — the conditional
  issue reads deposit raw bodies. `:975-1016` `normalize_issue/4` → `%Issue{}`
  with `labels` lowercased (`:1012`), `created_at`, `updated_at`; no
  `closed_at`, no `state_reason`. `:971` — listings drop pull requests.

**The open-issue poll.**
- `issues.ex:380-391` and `:393-428` — both listings call
  `record_open_issues/3` only after every page was read. `:433-438` —
  `record_open_issues/3` calls `OpenIssueSnapshot.put/3` and, as a second
  producer, `AllowedContributors.offer_open_issues/1`.
- `src/lib/aiur/github/open_issue_snapshot.ex:1-21` — absence from a complete
  listing is the close signal (#2714). `:37-47` `put/3`.
- `src/lib/aiur/allowed_contributors.ex:48-59` — the precedent for a third
  consumer: `GenServer.cast/2`, never a call, from the poll path.

**Merges.**
- `src/lib/aiur/recent_merge_store.ex:20` `@retention_limit 100`, `:30`
  `upsert/2`, `:35` `list/1` (sorted newest first, `:376-380`), `:382-386`
  `notify/0` → `AiurWeb.ObservabilityPubSub.broadcast_update/0`.
- `src/lib/aiur_web/observability_pubsub.ex:7` topic
  `"observability:dashboard"`, `:11` `subscribe/1` (default arg), `:17-21`
  `{:observability_updated, event_id}`. Many writers use this topic.
- `src/lib/aiur/recent_merge.ex:46-71` — `number` (the PR), `merged_at`,
  `repository`, `ticket_id` (from the `aiur/<n>` head branch,
  `TicketBranch.ticket_id/1`, `:181`).

**Run telemetry.**
- `src/lib/aiur/run_telemetry.ex:60-69` `telemetry_file/0`.
- `src/lib/aiur/config.ex:38-39` — retention default 64 MiB and 30 days.
- `src/lib/aiur/run_telemetry/writer.ex:486-497` — one JSON line per record:
  `kind`, `timestamp`, `recorded_at`, `attributes`.
- `src/lib/aiur/run_telemetry/lifecycle.ex:15-18` — the `dispatch` event;
  `:186-205` — attributes carry `ticket`, `event`, `boundary`.
- `src/lib/aiur/orchestrator/dispatcher.ex:2507-2515` — the `dispatch` `point`
  (`outcome: :requested`, `complexity`, `worker_host`, `remote`,
  `retry_attempt`; no model, no effort), `ticket` = `issue.identifier` (the bare
  number, `issues.ex:988`).
- There is no bus for telemetry records. `Aiur.RunTelemetry.Dataset.build/2`
  (`dataset.ex:40`) reads and reduces every file and is too heavy for a boot
  scan.

**Re-list signals and the projection precedent.**
- `src/lib/aiur/build_order/ad_hoc_source.ex:105-107` (boot fill),
  `:127-157` (handlers for `:webhook_degraded`, `:webhook_recovered`,
  `:view_state_diverged`, `:github_resource_changed`), `:387-394`
  (`subscribe_to_events/0`). Its comment at `:119-124`: a listing is a
  snapshot taken before the event, so the event must win.
- `src/lib/aiur/webhooks/mode_registry.ex:68` `subscribe/0` (degraded; it
  repeats every sweep), `:86` `subscribe_recovered/0`.
- `src/lib/aiur/github/view_state_sweep.ex:95` `@default_interval_ms` 15 min,
  `:120` `subscribe_diverged/0`, `:298-305` — divergence is broadcast on **every**
  sweep while GitHub's open head is newer than the store's, so it can repeat
  every 15 minutes when webhooks are off.

**GraphQL and budget.**
- `src/lib/aiur/github/transport.ex:558-575` `github_graphql/5`;
  `:581-611` — prices the document (`{:error, {:graphql_cost_ceiling, _}}`),
  adds `rateLimit { cost }`, bills `opts[:caller]`. `:180-214` — every request
  goes through `Budget.acquire/2`; a hold returns the **raw**
  `{:error, {:aiur, :locally_held, hold}}` (`:204-205`).
- `src/lib/aiur/github/errors.ex:47` `classify_error/1`; `:82-84` maps the raw
  hold to `{:github, :local_hold, %{reason: _, hold: hold}}`.
- `src/lib/aiur/github/local_hold.ex:104-110` `run/2` (opts `max_wait_ms`,
  `max_waits`, `sleep_fun`); `:236-251` `budget_layer_fault/1` matches only the
  **classified** shape. A raw `{:aiur, :locally_held, _}` passes through
  unwaited (`:251`).

**Store and supervision.**
- C4-T01 (PROPOSED): `History.apply/2`, `rows/2`, `health/1`, `checkpoint/2`,
  `subscribe/0`, checkpoint key `:closed_since`, `Row.merge/2`.
- `src/lib/aiur/build_order/lifecycle.ex:75-104` `Lifecycle.from_github/2`
  accepts REST lowercase and GraphQL uppercase; an unrecognised reason is
  `:unknown` (`:104`).
- `src/lib/aiur.ex:339` `Aiur.TaskSupervisor`; `:386-387` OpenIssueSnapshot and
  ResourceStore; `:391` RunTelemetry.Supervisor; `:429` RecentMergeStore;
  `:452` TicketHistoryProvider. C4-T01 puts History just before `:452`.

**Tests to copy.** `src/test/aiur/build_order/ad_hoc_source_test.exs`
(`ensure_resource_store!/0` `:325`, `ensure_pubsub!/0` `:333`, the degraded /
recovered / divergence tests at `:167-238`).

## Chosen design

Reuse the `AdHocSource` shape in a separate process: the feeder subscribes to
store events and the existing re-list signals, reads bodies from the store,
turns each observation into C4-T01 events, and calls `History.apply/2`. Ordering
guards live in one place, C4-T01's `Row.merge/2`, so the backfill (C4-T02) gets
the same protection.

Why a separate process: C4-T01's `apply/2` is a synchronous `GenServer.call`
(C4-T01 decision 6). Handlers inside `history.ex` would call their own server.
A separate feeder also leaves C4-T01's file untouched.

### Modules

- PROPOSED `src/lib/aiur/build_order/history/feed.ex` —
  `Aiur.BuildOrder.History.Feed`. Pure functions, one per source. Each takes the
  held row (or `nil`) and one observation and returns a list of C4-T01 events
  (`[]` when there is nothing to say).
- PROPOSED `src/lib/aiur/build_order/history/feeder.ex` —
  `Aiur.BuildOrder.History.Feeder`. GenServer, named by module. Subscriptions,
  boot steps, coalescing, catch-up scheduling, `catch_up_status/1`,
  `offer_open_issues/4`.
- PROPOSED `src/lib/aiur/build_order/history/catch_up.ex` —
  `Aiur.BuildOrder.History.CatchUp`. Builds the GraphQL page, calls
  `Transport.github_graphql/5` inside `LocalHold.run/2`, maps nodes to events.
  Runs in a `Task` under `Aiur.TaskSupervisor`; it never calls History. It sends
  `{:catch_up_result, ref, result}` to the feeder.
- PROPOSED `src/lib/aiur/build_order/history/catch_up_query.ex` (or reuse of
  C4-T02's `BackfillQuery`, see Dependencies).
- PROPOSED `src/lib/aiur/build_order/history/telemetry_scan.ex` — a streaming
  line filter over `RunTelemetry.telemetry_file/0`.
- No change to C4-T01's `src/lib/aiur/build_order/history/row.ex`: the fields
  and rule 6 below are in its version 1.
- `src/lib/aiur.ex`: one child line, `Aiur.BuildOrder.History.Feeder`, directly
  after C4-T01's `Aiur.BuildOrder.History`.

### Contract with C4-T01 (what this ticket consumes and adds)

| Need | C4-T01 interface used |
| --- | --- |
| Write | `History.apply([event], checkpoint: {:closed_since, map})`; event `%{number, observed_at, source, fields}` (C4-T01 §4.2) |
| `source` atoms | `:resource_store` (store events and resync), `:webhook` (when `change.source == :webhook`), `:poll` (open listing), `:recent_merge`, `:telemetry`, `:catch_up` (all in C4-T01's §4.1 list) |
| Fields written | `title`, `lifecycle` (`%Lifecycle{}` from `Lifecycle.from_github/2`), `created_at`, `closed_at` (`:none` when open), `labels` (lowercased), `label_events`, `parent` (`:none` when cleared), `blocked_by`, `sub_issues_added` (root rows), `merged_at`, `pr_number`, plus the two fields below |
| Read | `History.rows([n])` (ETS) for the label diff, edge sets and the listing diff; `History.health/1` for `complete?` and `state` |
| Checkpoint | `:closed_since` → `%{"watermark" => iso8601 | nil, "status" => string, "at" => iso8601, "reason" => string | nil, "pages" => n}` |
| Signal | `History.subscribe/0`: the feeder watches `health.complete?` flip from false to true |
| `updated_at` (C4-T01 v1) | `DateTime \| :unknown`, default `:unknown`. GitHub `updated_at` of the last applied issue body (this ticket's `version`). Written only by body-derived events |
| `dispatched_at` (C4-T01 v1) | `DateTime \| :unknown`, default `:unknown`. Earliest wins. C4-T04 reuses it instead of adding its own |
| Merge rule 6 (C4-T01 §4.2) | If `fields.updated_at` is a `DateTime`, the row's `updated_at` is a `DateTime`, and `fields.updated_at` is earlier, the event is treated as late (only `:unknown` fields are filled). Equal is not late. `dispatched_at` keeps the earlier of the two values |
| File version | Stays 1: C4-T01's version 1 already has these fields, so no migration |
| Lifecycle (C4-T01 v1) | `%Lifecycle{state: :closed, state_reason: :unknown}` is a valid stored value (an absence-close) |

Write refusals: C4-T01 accepts writes while rebuilding (`:history_corrupt`,
`:history_rebuilding`) and refuses them on `:version_unsupported`,
`:repository_mismatch`, `:state_dir_unavailable` (C4-T01 §4.4). The feeder
logs a refusal once per reason (`aiur_build_history_feed apply_refused
reason=…`) and drops the batch. It never retries in a loop and never crashes.

### Observation rules (`Feed`)

`now` is the feeder's clock (`now_fun`). Every event carries `observed_at` and
`source`; C4-T01 rules 1, 2, 5 and the new rule 6 decide what changes.

| Source | `observed_at` | Fields |
| --- | --- | --- |
| `:issue` body (store event or resync) | `now` | `title`, `lifecycle` (from `"state"`, `"state_reason"`), `created_at`, `closed_at` (parsed, or `:none` when open), `labels`, `updated_at`; `label_events` from the label diff |
| `:issue_labels` body | `now` | `labels`, `updated_at` = the change's `data_version` (the deposit uses the issue `updated_at`, `deposit.ex:579-584`); `label_events` from the diff |
| `:issue_dependency` body | `now` | the blocked issue's `blocked_by` = held list ± `blocking_issue_number` by `"present"`. Skipped when the held list is `:unknown` (one edge is not a full list, the `:issue_blocked_by` rule at `deposit.ex:773-784`) |
| `:sub_issue` body | `now` | the sub issue's `parent` = `parent_issue_number` when present; `:none` when absent and the held parent is that number; else nothing. When `"present"` is true, the root (parent) row also gets `sub_issues_added: [%{ref: %{owner, repository, number: sub}, at: now}]` (union; the deposit is versioned by arrival time, so `now` is the real join time to the second) |
| Open listing: issue named | `listed_from` | as an `:issue` body, from `%Issue{}`: `title`, `lifecycle` open, `closed_at :none`, `created_at`, `labels`, `updated_at` |
| Open listing: held open row not named | `listed_from` | `lifecycle` `%{state: :closed, state_reason: :unknown}`, `closed_at :unknown`. The true time is unknown until a body or the catch-up gives it |
| `RecentMergeStore` row | `now` | `merged_at`, `pr_number`, only when `repository` is this repo, `ticket_id` parses to an integer, and `merged_at` is later than the held value (or the held value is not a `DateTime`) |
| Telemetry `dispatch` point | `now` | `dispatched_at` (earliest wins, rule 6) |
| Catch-up node | `now` | as an `:issue` body, plus `node_id` (`id`), `parent` (`:none` when null) and `blocked_by` (full set). `labels` and `blocked_by` are omitted when their connection has `hasNextPage: true`, so a truncated list is never stored as complete |

- **Label diff.** When the held row's `labels` is a list, each label in the new
  set and not in the held set gives `%{label: l, action: :labeled, at:
  updated_at, actor: :unknown}`; each removed label gives `:unlabeled`. The
  body has no actor; a backfill item with a known actor wins on the same
  `{label, action, at}` key (C4-T01 rule 3). When the held labels are
  `:unknown`, no events are made (the first sighting is not a change). `at` is
  the body's `updated_at`, which a label change moves.
- **Labels are lowercased** in every source, as `normalize_issue/4` does
  (`issues.ex:1012`). Without this, the listing (lowercase) and a raw body
  (GitHub case) would flip a row on every poll.
- **Reopen after an absence-close.** The listing rule for a named issue writes
  `updated_at` equal to the held value. Rule 6 treats equal as not late, so a
  row closed only by absence reopens on the next listing that names it.
- **Why `listed_from`.** It is the time taken **before** the first page request
  of that listing. A row created or closed by a deposit after `listed_from` has
  a newer `observed_at`, so C4-T01 rule 2 stops the listing from closing or
  reopening it. This is the `AdHocSource` rule ("the event must win",
  `ad_hoc_source.ex:119-124`) carried by the store's own merge.
- Comparison is on parsed `DateTime`, never on strings. A body with an
  unparsable `updated_at` is applied without `updated_at` (rule 6 does not
  engage); it is logged once.

### Catch-up

```graphql
query HistoryCatchUp($owner:String!, $name:String!, $since:DateTime!, $after:String) {
  repository(owner:$owner, name:$name) {
    issues(first:100, after:$after, states:[CLOSED],
           filterBy:{since:$since}, orderBy:{field:UPDATED_AT, direction:ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes { id number title state stateReason createdAt closedAt updatedAt
              labels(first:30) { pageInfo { hasNextPage } nodes { name } }
              parent { number }
              blockedBy(first:100) { pageInfo { hasNextPage } nodes { number } } }
    }
  }
}
```

- **Floor.** `since` = `closed_since["watermark"] − 10 min` (clock-skew overlap;
  the merge rules make the overlap free of double effects). With no watermark
  yet, `since` = the backfill start (`checkpoint(:backfill)["started_at"]` in
  the History file, written by C4-T02). With neither, the run does not start and
  the status is `:not_backfilled` with `reason: :no_floor`. A floor is never
  guessed.
- **Precondition.** `History.health/1` is `:healthy` with `complete?: true`.
  Otherwise the status is `:not_backfilled` (backfill pending or rebuilding)
  and no request is made.
- **Hold handling.** The attempt function passed to `LocalHold.run/2` maps
  `{:error, reason}` from `github_graphql/5` through
  `Errors.classify_error({:error, reason})`. Without this, a budget hold arrives
  raw and `LocalHold` does not wait it out (see Verified starting point).
- `caller: "build_history_catch_up"`, so `aiur github-cost` shows it on its own
  line.
- Follows `hasNextPage` up to `@max_pages 5` per run. After the last page of a
  complete run, `watermark` = the time taken before the first request. After a
  capped run, `watermark` = the `updatedAt` of the last applied node and
  `status` is `"partial"`; the feeder schedules the next run at the end of the
  rate window (below), not at once.
- **Triggers.**
  - Feeder boot (once, after the resync).
  - `health.complete?` flips false → true (the backfill just finished; floor =
    backfill start, which covers changes made while a backfill was interrupted,
    C4-T02 "Interface mismatches" 8).
  - `{:webhook_recovered, repo}` and `{:view_state_diverged, repo}` for this repo
    (downcased compare, as `ad_hoc_source.ex` `maybe_relist/2` does).
  - **Not** `{:webhook_degraded, _}`: it repeats every sweep.
  - **Rate window.** Signal triggers run at most once per
    `@min_signal_interval_ms` (1 h) after the previous run started. A trigger
    inside the window sets one pending run at the window end; more triggers do
    not add runs. Divergence can repeat every 15 min (`view_state_sweep.ex:95`,
    `:298-305`), so without the window this would become a 15-minute poll.
  - One run at a time; a trigger while a run is in flight sets the same pending
    flag.
- Reopened issues are not in this query (`states:[CLOSED]`). The open-issue poll
  names them on its next tick and the listing rule reopens them.
- **Status** (`Feeder.catch_up_status/1`, GenServer call; also persisted in the
  `:closed_since` checkpoint except `:running`):
  `%{status: :ok | :partial | :held | :failed | :not_backfilled | :running,
  at: DateTime | nil, reason: term | nil, pages: non_neg_integer, watermark:
  DateTime | nil}`. When the feeder is not running the read returns
  `{:error, :not_running}`, never an `:ok` status. C8-T04 renders the status
  with its age (`at`).

### Boot order (Feeder `init/1` → `handle_continue(:boot, _)`)

`init/1` only resolves the repo and subscribes, so the supervisor is not
blocked; the rest runs in `handle_continue`.

1. Subscribe: `ResourceEvents.subscribe(type, full_name)` for the four types
   with the downcased repo, `History.subscribe/0`,
   `ObservabilityPubSub.subscribe/0`, `ModeRegistry.subscribe_recovered/0`,
   `ViewStateSweep.subscribe_diverged/0`.
2. Resync: build events from every `ResourceStore.list_type/2` body of the four
   types and apply them in one `History.apply/2` call (local, free). Bodies are
   applied before edges, so the `blocked_by`/`parent` steps see the held rows.
3. Apply `RecentMergeStore.list/0`.
4. Start the telemetry scan task.
5. Start the catch-up task, or set `:not_backfilled`.

Subscribing before the resync means an event during the resync is queued and
applied after it; the merge rules make the order safe.

### Merge-store coalescing

`{:observability_updated, _}` comes from many writers. The handler schedules
one `:scan_merges` message 1 s later if none is pending, then maps
`RecentMergeStore.list/0` through `Feed`. That is at most one local GenServer
call per second. Unchanged merges give `[]` or an unchanged C4-T01 result.

## Implementation steps

1. No `row.ex` change: `updated_at`, `dispatched_at`, merge rule 6, the
   `:catch_up` source atom and the closed/`:unknown` lifecycle are in C4-T01's
   version 1. C4-T01's suite must stay green.
2. `CatchUpQuery.node_to_event/2` (or C4-T02's normalizer) → a C4-T01 event
   with the catch-up fields above.
3. `Feed`: one public function per source in the table. Pure; takes
   `held_row | nil`, the observation and `now`.
4. `TelemetryScan.dispatches(path)` — `File.stream!/1`, a
   `String.contains?(line, "\"event\":\"dispatch\"")` prefilter, then
   `Jason.decode/1`; keep `attributes.boundary == "point"`; skip bad lines;
   return `%{number => earliest DateTime}` from `timestamp`. A missing file
   returns `%{}`.
5. `CatchUp.run(repo, since, opts)` with injected `graphql_fun` (default
   `&Transport.github_graphql/5`), `now_fun`, and `LocalHold` options.
6. `Feeder`: the subscriptions and boot steps; `handle_info` for
   `{:github_resource_changed, change}` (filter repo; ignore `data?: false`;
   read the body with `ResourceStore.data/1`), `{:build_order_history_changed,
   %{health: h}}`, `{:observability_updated, _}`, `:scan_merges`,
   `{:webhook_recovered, r}`, `{:view_state_diverged, r}`, `:catch_up_window`,
   `{:catch_up_result, ref, result}`, `{:telemetry_scan_result, map}`,
   `{:DOWN, …}` for a crashed task (status `:failed`, reason
   `{:task_down, reason}`); and `handle_cast({:open_listing, owner, repo,
   issues, listed_from})`.
7. PROPOSED `Feeder.offer_open_issues(owner, repo, issues, listed_from)` — a
   `GenServer.cast/2` to the registered name (a cast to a name that is not
   registered is dropped, so the poll path never fails). In `issues.ex`:
   capture `listed_from = DateTime.utc_now()` at the start of
   `do_fetch_candidate_issues/1` and `do_fetch_candidate_issues_conditional/2`,
   pass it to `record_open_issues/4`, and call the feeder there beside the
   other two producers. About five changed lines.
8. `lib/aiur.ex`: the Feeder child after `Aiur.BuildOrder.History`, with a
   one-line comment.
9. Docs: `website/docs-app/apis/github.md` — add a "Build history" row to the
   view-state table (`:293-300`): event-sourced from the store; one catch-up
   page per boot, on backfill completion, and at most hourly on webhook
   recovery or divergence; caller `build_history_catch_up`; measured points per
   page. Link to it; do not restate it elsewhere.

## Non-happy paths

- **Store refuses writes** (`:version_unsupported`, `:repository_mismatch`,
  `:state_dir_unavailable`). `apply/2` returns `{:error, reason}`; the feeder
  logs once per reason, drops the batch, runs no catch-up (health is not
  `:healthy`), and stays up. Test 13.
- **Store rebuilding** (corrupt file quarantined, C4-T01). Live events still
  apply, as C4-T01 allows; the catch-up waits for `complete?`. Test 13.
- **Not backfilled yet.** Live events create and update rows. The catch-up does
  not run and reports `:not_backfilled`. It must never report `:ok`. Test 11.
- **Out-of-order delivery.** The store refuses a late body or edge
  (`deposit_unless_older/3`), so no event fires. Across sources, rule 6 refuses
  a body older than the held `updated_at`, and `listed_from` stops a listing
  taken before a deposit. Tests 2, 6, 16.
- **Stale resync after a restart.** ResourceStore persists across a restart and
  may hold a body older than the row (the row was updated by last boot's
  catch-up). Rule 6 refuses it because the row keeps `updated_at` on disk.
  Test 20.
- **`data?: false` change.** Ignored. `drop_data/1` is also a reader's `304`
  recovery, so it is not a deletion signal. A deleted GitHub issue therefore
  stays in history (decision 6).
- **Close seen only by absence** (webhooks off, manual close). Row is closed
  with `closed_at: :unknown`, never `listed_from` or `now`. The next catch-up
  trigger or a later body fills the real time. C4-T04 decides how an unknown
  end renders. Test 5.
- **Budget hold.** `LocalHold.run/2` waits out a short hold. Past its bounds the
  run ends with `%{status: :held, at: now}`; no rows change; the next trigger
  tries again. Test 10.
- **GraphQL error, network error, cost-ceiling refusal, task crash.** `:failed`
  with the reason; watermark unchanged. Test 12.
- **Truncated connections.** More than 30 labels or 100 blockers: that field is
  omitted from the event, so the held value stays. Test 9.
- **Feeder crash and restart under its supervisor.** Events during the gap are
  recovered by the resync from the store (72 h retention). Test 14.
- **Daemon restart.** History reloads (C4-T01), the resync and the catch-up run
  again from the persisted watermark (EC-31). Rows lost in C4-T01's 2 s flush
  window are re-applied by the resync and the 10-minute overlap. Test 8.
- **Other repositories.** Store subscriptions are per repo; a merge, listing or
  signal for another repo is dropped. Tests 7, 15.
- **Untrusted text.** Titles and labels are stored as received (lowercased
  labels). C4-T01 checks UTF-8; escaping is the renderer's job (EC-30, C9). No
  body text is stored by this ticket.
- **Large telemetry file** (64 MiB default cap). The scan streams lines in a
  task and never blocks the feeder mailbox. A decode error skips the line.

## Compatibility and rollout

- No config key, CLI flag or operator env var. The only docs change is the
  `apis/github.md` row (AGENTS.md "Docs ship with the change" and the GitHub
  rule).
- **Migration.** None. The History file stays version 1 (C4-T01 has the
  fields).
- **GitHub cost (AGENTS.md "A claimed saving must be measured").** This adds a
  cost and claims no saving. The PR body states the measured points of one
  catch-up page from `aiur github-cost` (caller `build_history_catch_up`) and
  the number of pages the first boot read. Between triggers the feeder makes
  zero calls (test 18). Upper bound from the rate window: 24 runs a day while
  divergence repeats; one page each in the normal case. Expected order about
  3 points per page (C4-T02's estimate for the same node shape), so about
  72 points a day at worst; the PR replaces both numbers with measurements.
- Rollback: remove the Feeder child; the store keeps its last rows and stops
  updating. C8-T04 shows the catch-up age, so a frozen store is visible.

## Pixel parity

Not applicable. This ticket has no UI and no design element (row "Design
elements: —"). It feeds the design's `D.hist` rows, which the design sorts by
`end` (`J:381`) and lays out by `t.start`/`t.end` in `ganttHist`
(`J:424-440`). That is why `closed_at`, `merged_at` and `dispatched_at` are
kept as raw, explicit, possibly-`:unknown` facts for C4-T04 to turn into
`start`/`end`. C1-T02's side-by-side harness does not run for this ticket.

## Verification

ExUnit. PROPOSED `src/test/aiur/build_order/history/feed_test.exs` (pure rules)
and `src/test/aiur/build_order/history/feeder_test.exs` (the process, with
`ensure_resource_store!/0`, `ensure_pubsub!/0`, a C4-T01 store started on a
`tmp_root!/1` dir, a fake `graphql_fun` that counts calls, a temp telemetry
file). C4-T01's `history_test.exs` runs unchanged.

| # | Test | Expected | Fails without |
| --- | --- | --- | --- |
| 1 | `:issue` closed deposit closes the row | `Deposit.deposit("issues", closed payload, repo)` → row `lifecycle` closed/completed, `closed_at` = body time, `sources` contains `:webhook` | the `:issue` subscription and handler |
| 2 | late older body does not roll back | apply reopened body (`updated_at` v2), then a closed body with v1 through `Feed`/`apply` directly (bypassing the store guard) → row stays open | rule 6 |
| 3 | same deposit twice is a no-op | second identical deposit → zero `:build_order_history_changed` messages, `generation` unchanged | C4-T01 rule 7 plus no extra event fields (e.g. a `label_events` entry made on every apply) |
| 4 | listing reopens a closed row | `offer_open_issues` naming a closed row with newer `updated_at` → lifecycle open, `closed_at :none` | the `issues.ex` hook / listing rule |
| 5 | absence closes with unknown time | open row missing from a listing → lifecycle `closed`/`:unknown`, `closed_at == :unknown`. **Mutation:** set `closed_at: listed_from` in `Feed`; the test must fail | the listing rule |
| 6 | a listing taken before a deposit does not close or reopen | row created by a deposit at t1; listing with `listed_from` t0 < t1 not naming it → row stays open; listing at t0 naming a row closed by a deposit at t1 → stays closed | `listed_from` as `observed_at` (mutation: use `now` → fails) |
| 7 | merges | two merges for #7 in this repo → latest `merged_at` and its `pr_number`; a merge for `other/repo` → no change | the merge scan and repo filter |
| 8 | boot catch-up | watermark W, healthy complete store → request `since == W − 10 min`, `states [CLOSED]`, `caller "build_history_catch_up"`; nodes applied; watermark = time before the first request | `CatchUp` and the boot trigger |
| 9 | capped pages and truncation | 6 pages with `hasNextPage` → 5 requests, `:partial`, watermark = last node `updatedAt`; a node with `labels.pageInfo.hasNextPage` → held `labels` unchanged | the page cap; the truncation omit |
| 10 | budget hold | `graphql_fun` returns raw `{:error, {:aiur, :locally_held, %{reset_at: now + 1 s}}}` once, then a page → one wait, page applied, `:ok`; with `reset_at` past `max_wait_ms` → no row change, `status == :held` | the `Errors.classify_error/1` step (without it the short hold is `:failed`) |
| 11 | not backfilled | `complete?: false` → zero requests, `status == :not_backfilled`; complete but no watermark and no backfill `started_at` → zero requests, `:not_backfilled`, `reason: :no_floor`. **Mutation:** return `:ok` for this branch; the test must fail | the precondition and floor |
| 12 | failure is not ok | GraphQL error → `:failed`, `reason` set, `at` set, watermark unchanged. **Mutation:** map errors to `:ok`; the test must fail | error mapping |
| 13 | refusing and rebuilding store | store file with `"version": 3` + a deposit → feeder alive, one log line for two deposits, zero requests; rebuilding store + a deposit → row written, zero requests | the refusal handling; the precondition |
| 14 | resync | body in ResourceStore before the feeder starts → row present after start; zero requests other than the catch-up | the `list_type/2` resync |
| 15 | triggers and rate window | `webhook_recovered` for this repo → one run; a second signal 1 min later → no run until the window message; `view_state_diverged` for another repo → none; `webhook_degraded` → none; `complete?` flip → one run with `since` = backfill `started_at` | trigger filter and window |
| 16 | edges | dependency add, remove, then a late add, all through `Deposit.deposit/4` with `at:` → `blocked_by` empty; held `blocked_by :unknown` + one add → unchanged; sub-issue add → `parent` set; remove → `:none` | the edge handlers |
| 17 | telemetry | file with three `dispatch` points for #7 and a corrupt line → `dispatched_at` = earliest; an older stored value is kept | `TelemetryScan`; rule 6 earliest-wins |
| 18 | no steady-state polling (regression guard, named so) | after boot, 100 store events and 10 listings → request count unchanged | design guard; does not count as coverage for this change |
| 19 | one signal per committed change (EC-10 source) | one `issues` closed delivery (deposits `:issue` and `:issue_labels`) → exactly one `:build_order_history_changed` message naming that number | `:issue_labels` writing only fields that equal the `:issue` write (an extra field on the labels event makes a second change) |
| 20 | stale resync after restart | row with `updated_at` T2 on disk; ResourceStore holds an open body with T1 < T2 → after feeder start the row is unchanged | rule 6 persisted in the row (mutation: keep versions in feeder memory → fails) |
| 21 | label case | listing (lowercase) then a body with `"Agent:Done"` → zero changes on the second | label lowercasing |
| 22 | live sub-issue add records the join time | `Deposit.deposit/4` sub-issue add (parent #1, sub #12) at `at: t` → root #1 `sub_issues_added` contains `%{ref: %{…, number: 12}, at: t}`; a remove adds nothing. **Mutation:** drop the root append; the test must fail | the root `sub_issues_added` append |

Mutation discipline (AGENTS.md): for each test, revert the production hunk in a
worktree, confirm it fails, restore, confirm it passes; `git status --porcelain`
shows only the revert. Record the command and results in the PR body.

Command (isolated HOME, no GitHub tokens, per the "mix test clobbers
agent-token" note):

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/build_order/history/feed_test.exs \
  test/aiur/build_order/history/feeder_test.exs \
  test/aiur/build_order/history_test.exs \
  test/aiur/github/issues_test.exs
```

Then the full suite on CI for the head SHA (a new child is in the supervision
tree).

Live check (no UI): after `aiurdev restart`, `aiur github-cost` shows a
`build_history_catch_up` line with the page count of this boot, then no further
growth while idle. Close a test issue on GitHub and confirm the History row
closes within one delivery (`History.rows/2` over the control RPC).

## Decisions made without the owner

1. **Telemetry dispatches are read at boot only.** Telemetry has no bus, and
   C4-T04 journals live starts at the dispatcher. The README row lists
   telemetry among the steady-state feeds; this ticket reads the file at boot to
   fill `dispatched_at` for the 30 days on disk and the restart gap.
2. **`:sub_issue` deposits are consumed** although the README row names only
   `:issue` and `:issue_dependency`: C4-T01 stores `parent`, and the sub-issue
   deposit is its only live source.
3. **`:issue_blocked_by` lists are not consumed.** The edge deposits and the
   catch-up's full `blockedBy` set cover the same facts; one source is simpler.
4. **More than "one page at boot."** The README row says one page per boot. The
   catch-up follows up to 5 pages (a long downtime can close more than 100
   issues) and also runs on backfill completion and, at most hourly, on
   `webhook_recovered`/`view_state_diverged`. These are existing, rare signals
   of lost deliveries; `AdHocSource` re-lists on the same signals.
   `webhook_degraded` is excluded because it repeats.
5. **A close seen only by absence keeps `closed_at` `:unknown`.** No extra REST
   read is made (no new polling). The time arrives with the next body or
   catch-up.
6. **Deleted issues stay in history.** `data?: false` is not a reliable deletion
   signal.
7. **The watermark advances only from the catch-up**, never from live events, so
   a dropped delivery is never skipped by the next catch-up.
8. **One tracker repository**, as `AdHocSource` does.
9. **Page cap 5, overlap 10 minutes, merge debounce 1 s, signal window 1 h.**
   Fixed constants with one `ponytail:` comment; make them config only if a
   measurement shows a need.
10. **`agent_model`/`agent_effort` are not fed.** C4-T01's hand-off asks for
    them from the telemetry `dispatch` point, but that point carries no model
    or effort (`dispatcher.ex:2507-2515`), nor does `agent_spinup`
    (`agent_runner/session_lifecycle.ex:186-191`, `:413-417`). They stay
    `:unknown`. A source for them is a coordinator item.
11. **The ordering guard lives in C4-T01's `Row.merge/2`** (rule 6 plus a
    persisted `updated_at`), not in feeder memory. Feeder memory is lost on
    restart while ResourceStore keeps 72 h of older bodies, so an in-memory
    guard would let the boot resync roll rows back (test 20). In the row it
    also protects C4-T02's writes.
12. **A separate feeder process**, not handlers inside `history.ex`: C4-T01's
    `apply/2` is a synchronous call to the History server.
13. **`dispatched_at` is first written here** (the field is in C4-T01 v1).
    C4-T04 then reads it and `in_progress_at` (or derives start from
    `label_events`, which this ticket keeps current).
14. **Labels are lowercased** in the feed, matching the poll's `%Issue{}`.

## Completion and handoff

- [ ] `Feed`, `Feeder`, `CatchUp`, the node parser and `TelemetryScan` merged;
      tests 1–22 pass; the mutation checks for 5, 6, 11, 12, 20, 22 fail as
      stated.
- [ ] `issues.ex` gets the `listed_from` capture and one producer call; no
      other poll changes.
- [ ] `apis/github.md` row added, with the measured points per page.
- [ ] PR body: measured catch-up cost, first-boot page count, "no saving
      claimed".
- **Dependents:** C4-T04 (reads `closed_at`, `merged_at`, `label_events`,
  `dispatched_at`), C8-T04 (History change signal; `Feeder.catch_up_status/1`
  with its age), C4-T02 (shares the node parser; protected by rule 6).
- **Interface items for the coordinator:**
  - C4-T01: Settled 2026-10-08: `:catch_up`, the closed/`:unknown` lifecycle,
    `updated_at`, `dispatched_at` and rule 6 are in C4-T01 version 1.
  - C4-T01/C4-T02: Settled 2026-10-08: the floor is `:backfill.started_at` in
    the History file; the watermark is the `:closed_since` checkpoint; there is
    no separate backfill file.
  - C4-T02: Settled 2026-10-08: C4-T02 sends `updated_at` in its events. Still
    open: lowercase label names in C4-T02's events.
  - C4-T04: Settled 2026-10-08: C4-T04 reuses `dispatched_at` and its `Timing`
    replaces the start/end merge in its PR.
  - C8-T04: read `Feeder.catch_up_status/1`; it already expects one
    `changed: [n]` message per batch (C8-T04 "Interface" item 4).
  - `agent_model`/`agent_effort` have no source (decision 10).
- **Sources:** tickets/README.md C4-T03 row; plan.md §5, §5.1, §8 (EC-10,
  EC-31, EC-32); chunks.md C4; C4-T01 §4; C4-T02 "Checkpoint" and "Interface
  mismatches"; C4-T04 "Signals"; `website/docs-app/apis/github.md:293-300, 531`.
- **Remaining blocker:** DESIGN-E8 sign-off only.

## Review log

Adversarial review, 2026-10-08, against the live code at `58854d4c8` and the
now-written C4-T01, C4-T02, C4-T04 and C8-T04 docs.

1. Replaced the assumed C4-T01 contract (`commit(state, [row])`, `version`,
   `watermark`, `catch_up`, `state`/`state_reason` strings, nil values,
   `source` field) with C4-T01's real API: `apply/2` events, `lifecycle`,
   `:none`/`:unknown` sentinels, `sources`, checkpoint `:closed_since`.
2. Moved the handlers out of `history.ex` into a new `Feeder` process:
   `apply/2` is a call to the History server, so in-process handlers could not
   use it.
3. Moved the ordering guard into `Row.merge/2` with a persisted `updated_at`
   (new test 20). The original in-row `version` had no home in C4-T01; a
   feeder-memory guard would let the boot resync roll rows back.
4. Renamed `first_dispatch_at` → `dispatched_at` (C4-T04's name);
   `first_in_progress_seen_at` → `label_events` (C4-T01's field);
   dropped `close_observed_at` (`closed_at: :unknown` plus `observed_at` carry
   it).
5. Budget hold: `github_graphql/5` returns the raw `{:aiur, :locally_held, _}`
   and `LocalHold` matches only the classified shape; added the
   `Errors.classify_error/1` step and a test that fails without it.
6. Added a 1 h window for signal triggers: `view_state_diverged` repeats every
   15 min while the head is newer, which would have made the catch-up a poll.
   Added the worst-case cost bound.
7. Floor: no longer asks C4-T02 to write T03's watermark; uses the backfill
   `started_at` C4-T02 defines, runs on the `complete?` flip, and reports
   `:no_floor` instead of guessing.
8. Listing race: `listed_from` (time before the first page) replaces the
   cast-time `taken_at`, so a deposit made during the listing wins; added test 6
   cases and the absence-close reopen rule.
9. Lowercased labels (the poll lowercases them; raw bodies do not) and added
   test 21; omit truncated `labels`/`blockedBy` connections.
10. Unavailable store: aligned with C4-T01 (writes accepted while rebuilding,
    refused in three states); test 13 rewritten.
11. Recorded that `agent_model`/`agent_effort` (asked of this ticket by C4-T01)
    have no telemetry source.
12. Corrected citations: `ResourceStore.subscribe/2` does not exist (use
    `ResourceEvents.subscribe/2`); order-sensitive list is `:384-392` and
    includes `:sub_issue`; dispatcher point `:2507-2515`; `ganttHist` `J:424`;
    `apis/github.md` table `:293-300`, `:531`; removed the unused `JsonStore`
    and `decision_state_dir` cites; `GenServer.cast/2` to an unregistered name
    does not exit, so no `:exit` catch is needed.
13. Telemetry scan: dropped the cutoff (earliest-wins makes it unnecessary);
    filter on `boundary == "point"`.
14. Added the file version 2 migration and test 22; `init` defers work to
    `handle_continue` so the supervisor is not blocked.
- Reconciliation 2026-10-08 (coordinator): no `row.ex` change and no file version 2 (fields, rule 6, `:catch_up`, closed/`:unknown` lifecycle are in C4-T01 v1); test 22 now covers the live `:sub_issue` append to the root row's `sub_issues_added` with the arrival time; label diff items carry `actor: :unknown`; catch-up reads `id` into `node_id`; floor named as `:backfill.started_at` in the History file; test 3 cites rule 7; interface items settled except C4-T02 label lowercasing.
