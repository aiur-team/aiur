---
ticket_id: MP-E8-C4-T04
feature_id: MP-E8
chunk_id: MP-E8-C4
bucket: 2-platform
title: Start and end times for Gantt
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C4-T02, MP-E8-C4-T03]
complexity: 3
design_gate: DESIGN-E8
design_signoff_items: [S-5]
owns_edge_cases: [EC-22]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C4-T04 — Start and end times for Gantt

## Identity and outcome

- Bucket 2, feature MP-E8 (home page "Continuous build history"), chunk C4
  (durable history store).
- **User value:** in Gantt mode every past ticket is a bar from the moment an
  agent started it to the moment it merged or closed. A ticket whose start
  nobody recorded shows as "start unknown". It never gets a made-up start
  (`createdAt`, the end time, or `0`).
- **Deliverable:**
  1. PROPOSED pure module `src/lib/aiur/build_order/history/timing.ex`
     (`Aiur.BuildOrder.History.Timing`). It owns the merge rules of the start
     and end signals and derives `start`, `start_source` and `end` on a History
     row.
  2. One call of `Timing.derive/2` inside the C4-T01 store's merge, so every
     feeder (C4-T02, C4-T03, the two hooks below) gets the same rule.
  3. Two write-time journal hooks that record a new start the moment it
     happens: a successful `in-progress` state write
     (`Aiur.GitHub.Tracker.update_issue_state/2,3`) and a confirmed worker spawn
     (`Aiur.Orchestrator.Dispatcher`).
  4. `Timing.to_payload/1` for the ticket row that C3-T02 defines and C8-T04
     assembles (`start`, `end` in epoch ms or `null`; `start_src`).
- **Non-goals:**
  - No Gantt drawing. Interval merge, idle-gap compression, lanes, the
    minimum-height clamp in pixels and the S-5 card are C9-T09.
  - No new GitHub reads. Timeline label events come from C4-T02 (backfill) and
    C4-T03 (steady-state feed). This ticket adds no polling and spends no
    GraphQL or REST points.
  - No subtraction of paused time or rework. The design draws one bar per
    ticket (J:426, J:442).

## Dependencies and blockers

- **DESIGN-E8**, sign-off item **S-5** (owner-design-tasks/DESIGN-E8.md:105).
  This ticket follows the written default: an end-anchored minimum-height card
  with a "start unknown" title tooltip. Kevin's answer may reopen the client
  half (C9-T09). The server contract here (an explicit `unknown`) holds for any
  answer.
- **C4-T02** (backfill): writes `in_progress_at` (first `<prefix>:in-progress`
  `LabeledEvent`), `closed_at`, `merged_at`/`pr_number` and `reopened_at` for
  every issue (C4-T02 "Field | From" table). It ships an interim
  `put_signals/2` that this ticket replaces with `Timing.merge/3`.
- **C4-T03** (steady-state feed): writes `closed_at` (`:unknown` when a close
  is seen only by absence), `merged_at` (`RecentMergeStore`), `label_events`
  (label diff; `at` = a webhook/deposit body's `updated_at`) and
  `dispatched_at` (boot scan of telemetry `dispatch` points, 30 days)
  (C4-T03 "Contract with C4-T01").
- **C4-T01** (store, transitive): the row with `:none`/`:unknown` sentinels (no
  `nil` stored), the event merge rule (§4.2), `apply/2`, the PubSub signal, the
  fail-closed corrupt-file rule (§4.4). Its version-1 row already has every
  field this ticket reads or writes (`in_progress_at`, `dispatched_at`,
  `last_closed_at`, `label_events`, `start`, `start_source`, `end`).
- C4-T05 depends on this ticket for `end` (C4-T05 front matter).
- Successors: **C9-T09** (Gantt mode) consumes the fields and the S-5 rule;
  **C8-T04** (index assembler) calls `to_payload/1`; **C4-T05** reads `end`.
- Rule source: plan.md §10 item 8; tickets/README.md row C4-T04;
  decisions.md "What 'start' and 'end' mean for a past ticket" (line 30, open
  question, answered by plan §10.8).

## Verified starting point (`58854d4c8`, `/home/everdred/github/everdred/aiur-worktrees/runtime/src`)

- **No start/end exists for a closed ticket today** (baseline.md §4, line 325:
  telemetry `dispatch` covers the last 30 days only).
  `Aiur.BuildOrder.History` is PROPOSED by C4-T01.
- **State write seam:** `lib/aiur/github/tracker.ex:170-174`
  `update_issue_state/2` and `:176-191` `update_issue_state/3` call
  `client_module()` (`:203-205`, swappable with the `:github_client_module` app
  env). Every daemon-process state write on a GitHub tracker reaches it through
  the facade `Aiur.Tracker.update_issue_state/2,3` (`lib/aiur/tracker.ex:80-101`),
  whose `adapter/0` (`:161-168`) returns `Aiur.GitHub.Tracker` for
  `tracker.kind == "github"`. Writers of `in-progress` that pass here:
  - the agent tool `aiur_set_ticket_state`
    (`lib/aiur/codex/dynamic_tool/ticket_state.ex:32` settable states include
    `in-progress`; `:76-94` `execute/3`) through
    `lib/aiur/agent_runner/tool_executor.ex:140-142` and `:184-204`, whose
    default writer is `&Tracker.update_issue_state/2` (`:76`, `Tracker` =
    `Aiur.Tracker`, alias at `:13-23`);
  - the CI handoff `ci-wait → in-progress`
    (`lib/aiur/orchestrator/ci_lifecycle.ex:30` `@active_handoff_state`;
    writes at `:1160` and `:1518`);
  - the lifecycle fence heal (`lib/aiur/orchestrator/lifecycle_fence.ex:357`,
    restores an authoritative state, which can be `in-progress`).
- **Dispatch seam:** `lib/aiur/orchestrator/dispatcher.ex:2503`
  `spawn_issue_on_worker_host/6`. `:2508-2516` records the telemetry `dispatch`
  point (`outcome: :requested`) **only when `TelemetryLifecycle.enabled?()`**.
  `:2518-2529` starts the worker; `{:ok, pid}` at `:2530` is the confirmed
  spawn. The runner is injectable (`:2504`, `runner:` option).
- **Why journal at the write (MP-E1 F2):** `lib/aiur/events/publisher.ex:405-423`
  drops events whose actor is the daemon account (`bot_self_loop?/1`,
  `filtered_bot_self_loop?/3`). A daemon-written `in-progress` label never
  reaches the bus, so a bus subscriber cannot see it.
- **Telemetry:** `lib/aiur/run_telemetry/lifecycle.ex:15-19` event names
  (`dispatch`, `agent_pause`, `agent_resume`, `rework_start`, `pr_merged`);
  `:72-97` `record/6` never raises. An existing reader prefers the dispatch
  time for wall clock:
  `lib/aiur_web/operator_control_center/analytics/presenter.ex:801-820`
  `ticket_wall_clock_ms/1`.
- **Merge facts:** `lib/aiur/recent_merge.ex:22-45` (`ticket_id`, `merged_at`
  as `DateTime`); `RecentMergeStore` keeps the newest 100
  (`lib/aiur/recent_merge_store.ex:18-21`).
- **Identifier shape:** GitHub issues use `id` and `identifier` =
  `to_string(number)` (`lib/aiur/github/issues.ex:987-988`), the same string
  `update_issue_state` takes. History rows are keyed by `pos_integer` (C4-T01
  §4.1), so the hooks parse it.
- **State slug:** `Aiur.Orchestrator.DispatchPolicy.state_slug/1`
  (`lib/aiur/orchestrator/dispatch_policy.ex:1177-1187`) normalises
  "In Progress"/`in_progress` to `in-progress`.
- **Tests to extend:** `test/aiur/orchestrator/dispatcher_test.exs` (spawn
  cases pass `runner:`, for example `:195`). No `test/aiur/github/*tracker*`
  test exists; this ticket adds one.

### Design source (`design-source/assets/build.js`, read-only)

- J:10 `H = 36e5`. J:11 `NOW = new Date(2026, 9, 7, 14, 20)` (local time).
- J:172, J:190 history rows carry `start` and `end` as epoch ms; J:255 running
  rows carry `start` only. In the `live` dataset these are non-integer ms
  (C1-T01, 184 rows).
- J:426-427 `ganttHist` builds intervals `[t.start, t.end]` for history and
  `[t.start, NOW]` for running tickets.
- J:442 card `y = tY(start)`, `h = Math.max(tY(end) - tY(start) - 1,
  span <= 2 ? CH.mini : 4)`; J:364 `CH.mini = Math.max(24, 2.3 * fs)` with
  `fs = 13` (J:358), so 29.9 px at span ≤ 2 and 4 px above.
- J:845-847 card body: `hrs = (t.end - t.start) / H`; full Gantt `.bd-time`
  shows `fmtD(start) fmtT(start)<br>→ [fmtD(end) ]fmtT(end)` and
  `.bd-badges span.h` shows `fmtH(hrs)`; other tiers show `fmtH(hrs)` in
  `.bd-status`. J:19 `fmtH` floors at "5m". CSS: `.bd-time` C:247,
  `.bd-badges` C:248-250, `.bd-status` C:242.
- Other `t.start` readers and their owners: J:427 running interval (C9-T09,
  "Running row with `start === null`"), J:658 history header date (C9-T03,
  test "first start unknown"), J:1161 list-row duration (C9-T12, U4), J:1308
  mock conversation span (`convo(t)`, replaced by C11-T03/T04 real data).
- The design has **no** unknown start. With `start` absent, J:426 pushes
  `[undefined, end]` and J:845 gives `NaN`. So the server sends an explicit
  `null`, and each reader above branches on it.

## Chosen design

### Signals (stored on the History row)

All fields use C4-T01's sentinels: a value, `:none` or `:unknown`; `nil` is
never stored (C4-T01 §4.1). A feeder's `nil` is normalised to `:unknown` by
C4-T01's decoder of events.

| Field | Type | Merge rule (owned by `Timing`) | Writers |
| --- | --- | --- | --- |
| `in_progress_at` | `DateTime \| :unknown` | earliest wins | C4-T02 timeline; this ticket's tracker hook |
| `label_events` (`<prefix>:in-progress` `:labeled` items) | list \| `:unknown` | union (C4-T01 rule 3); the earliest `at` is the candidate | C4-T03 label diff (body `updated_at`) |
| `dispatched_at` | `DateTime \| :unknown` | earliest wins | C4-T03 boot telemetry scan; this ticket's dispatcher hook |
| `merged_at` | `DateTime \| :none \| :unknown` | latest `DateTime` wins; `:none`/`:unknown` never replace a `DateTime` | C4-T02 closing PR; C4-T03 `RecentMergeStore` |
| `closed_at` | `DateTime \| :none \| :unknown` | C4-T01 rule (newest event replaces; a reopen writes `:none`) | C4-T02; C4-T03 |
| `last_closed_at` | `DateTime \| :none \| :unknown` | latest `DateTime` ever seen in `closed_at` (C4-T01 v1 field) | C4-T02 (`closedAt`); `Timing.derive/2` |

`last_closed_at` exists because C4-T01 rule 1 and C4-T03 clear `closed_at` on
a reopen. Without it, a reopened ticket would lose its end, which the README
row forbids. Earliest/latest makes every signal write idempotent and order-free:
a replay, a duplicate webhook, or the backfill arriving after the live hook
gives the same signals.

### Derived fields (computed by `Timing.derive(old_row, new_row)`, stored)

- **End:** `merged_at` if it is a `DateTime`; else `last_closed_at` if it is a
  `DateTime`; else `:none` when the row has never been closed (open, running);
  else `:unknown` (closed, time not yet known: C4-T03 "absence closes with
  unknown time"). A reopened ticket keeps its latest end; a second close or a
  second merge moves it forward.
- **Start:** the first valid candidate in the order: label =
  `earliest(in_progress_at, earliest in-progress :labeled at)` (`:label`), then
  `dispatched_at` (`:dispatch`). Else `:unknown` (`start_source:
  :unknown`). **Never `created_at`.**
  - A candidate is valid when `end` is not a `DateTime` or `candidate <= end`.
  - A candidate later than `end` by at most `@skew_ms` (300 000 ms) is clock
    skew between the daemon and GitHub: start = end (duration 0).
  - A candidate later than `end` by more than `@skew_ms` is evidence about a
    later event (a heal re-applied the label after close). It is skipped and
    the next candidate is tried.
- **Paused time and rework stay inside the bar.** `agent_pause`,
  `agent_resume`, `rework_start` are not inputs.
- Only `start`, `start_source` and `end` are stored as derived fields. The
  clamp and the end's source are not stored: no consumer reads them.

```elixir
# PROPOSED src/lib/aiur/build_order/history/timing.ex
@skew_ms 300_000
@earliest ~w(in_progress_at dispatched_at)a

# Called once by the C4-T01 store after its own field merge (C4-T01 §4.2).
def derive(old, new) do
  row =
    new
    |> keep_earliest(old, @earliest)
    |> keep_latest_time(old, :merged_at)
    |> Map.put(:last_closed_at, latest_time([old.last_closed_at, new.closed_at]))

  end_at = pick_end(row)
  label = earliest_time([row.in_progress_at, first_in_progress_label_at(row.label_events)])

  {start, src} =
    [{label, :label}, {row.dispatched_at, :dispatch}]
    |> Enum.find_value({:unknown, :unknown}, &valid_start(&1, end_at))

  %{row | start: start, start_source: src, end: end_at}
end
```

### Payload mapping (for the C3-T02 ticket row)

`Timing.to_payload(row)` returns
`%{start: ms | nil, end: ms | nil, start_src: "label" | "dispatch" | "unknown"}`
(`DateTime.to_unix(dt, :millisecond)`; `:none` and `:unknown` become `nil`).
`start: nil` always comes with `start_src: "unknown"`; the contract test
asserts the pair. Times are UTC on the server; the browser formats them in its
zone (EC-20, owned by C9-T09).

### Journal at the write

- PROPOSED `History.note_start(identifier, :label | :dispatch, %DateTime{})`,
  added to the C4-T01 store. It parses `identifier` with `Integer.parse/1`
  (a non-numeric or non-positive id returns `:ok` and does nothing) and sends a
  `GenServer.cast` of one C4-T01 event: `%{number: n, observed_at: at, source:
  :write, fields: %{in_progress_at: at}}` or `%{dispatched_at: at}`. A
  cast to an unregistered name returns `:ok`, so a run without the store (a
  memory or Linear tracker, a test) is a no-op. When the store is running, C4-T01's
  health table decides: writes are accepted while rebuilding and refused on
  `:version_unsupported`/`:repository_mismatch`; a refused cast is dropped. It
  never raises into the caller and never blocks it (C4-T01's `apply/2` is a
  synchronous call; the hooks must not wait on it).
- `GitHub.Tracker.update_issue_state/2,3`: when the client returns `:ok` and
  `DispatchPolicy.state_slug(state_name) == "in-progress"`, call
  `History.note_start(issue_id, :label, DateTime.utc_now())`, then return the
  client's result unchanged. On `{:error, _}` or any other value, nothing is
  noted.
- `Dispatcher.spawn_issue_on_worker_host/6`: in the `{:ok, pid}` branch
  (`:2530`), call `History.note_start(issue.identifier, :dispatch,
  DateTime.utc_now())`. This is **outside** the `TelemetryLifecycle.enabled?()`
  guard, so a run with telemetry off still records starts.
- The earliest-wins rule makes the later `in-progress` writes (the CI handoff,
  a fence heal, a rework round) no-ops for `start`.

## Implementation steps

1. Add `timing.ex` with `derive/2`, `merge/3` (the signal earliest/latest
   rules for a feeder's fields), `to_payload/1`, the private earliest/latest
   helpers and the `@skew_ms` constant (one `ponytail:` comment: fixed
   tolerance, revisit if C4-T03 measures larger skew).
2. In the C4-T01 store (no new row fields, no file version bump; C4-T01 v1
   has them):
   - call `Timing.derive(old_row, merged_row)` once at the end of the per-row
     merge (C4-T01 §4.2, before rule 7's "unchanged" check); this replaces the
     store's own start/end merge (R-G4), so rule 1 cannot move an earliest
     signal later or drop a merge time;
   - add `note_start/3`.
   A row with no signals reads start `unknown` until a feeder writes them. It
   never reads a guessed value.
3. Replace C4-T02's interim `put_signals/2` with `Timing.merge/3`. C4-T03
   keeps writing raw facts and sets no `start`/`end`.
4. Add the tracker hook in `lib/aiur/github/tracker.ex` (one private
   `note_in_progress/3` used by both arities, ≤ 10 lines).
5. Add the dispatcher hook (one line in the `{:ok, pid}` branch).
6. `to_payload/1` is used by C8-T04 for the ticket row (C8-T04 already lists
   it, line 245). Per R-G1, add `start_src` and nullable `start` to
   `Payload.validate/1` and to the C3-T02 fixture mapper in this PR.
7. Docs: none in this PR. The fields are not visible until C9-T09 renders them,
   and no config key, CLI flag or env var changes. Put two sentences for C12-T07
   (Documentation) in the PR body: "A past ticket's Gantt bar starts at its
   first `agent:in-progress` label, else its first dispatch, and ends at its PR
   merge, else its close. With neither start, the card shows 'start unknown';
   it never uses the creation time." C12-T07 adds them to
   `website/docs-app/concepts/build-orders.md`.

## Non-happy paths

| EC-22 case | Concrete input | Expected | Test |
| --- | --- | --- | --- |
| Start unknown | closed 2026-09-01T10:00Z, no label, no dispatch, `created_at` 2026-08-20 | `start: :unknown`, `start_source: :unknown`; payload `start: nil, start_src: "unknown"` | T1 |
| Never `createdAt` | same row | `start != created_at` and `start != end` | T1 (mutation M1) |
| Label beats dispatch | label 09:10, dispatch 09:00, merged 12:00 | `start` 09:10, `:label` | T2 |
| Label event is a label candidate | in-progress `:labeled` event at 09:20, `in_progress_at` 09:10 | `start` 09:10 (earliest) | T2 |
| Dispatch fallback | no label, dispatch 09:00, closed 11:00, no merge | `start` 09:00, `:dispatch`; `end` 11:00 | T3 |
| Zero duration | label 10:00, merged 10:00 | start = end, `:label`; C9-T09 draws `CH.mini` | T4 |
| Clock skew | label 10:03, closed 10:00 | start = end = 10:00, `:label` | T5 |
| Negative beyond skew | label 2026-09-05 (heal after close), dispatch 09-01 09:00, closed 2026-09-01 11:00 | label skipped; `start` = dispatch | T6 |
| Negative, no fallback | label only, 2 days after close | `start: :unknown` | T6 |
| Reopened, not yet closed again | closed 09-01, then a reopen event (`closed_at: :none`) | `end` stays 09-01 (`last_closed_at`) | T7 |
| Reopened, merged later | closed 09-01, reopened, merged 09-04 | `end` 09-04; start still the first label | T7 |
| Late older close | `closed_at` 09-04 applied, then a replay of 09-01 with an older `observed_at` | `end` stays 09-04 | T7 |
| Late older label | live hook 09:10, then backfill label 09:05 | `start` 09:05 | T10 |
| Paused / rework | label 09:00, pause 10:00–14:00, rework 15:00, merged 18:00 | bar 09:00–18:00 | T8 |
| Multi-day | label 09-01 22:00, merged 09-03 02:00 | stored verbatim; no split per day | T8 |
| Closed, no close time | C4-T03 absence close (`closed_at: :unknown`), never closed before, no merge | `end: :unknown`; payload `end: nil`; C8-T04 counts it as `undated` | T9 |
| Running | label 13:00, open, never closed | `start` 13:00, `end: :none`; payload `end: nil`; client uses `NOW` (J:427) | T2 |
| Duplicate writes | same event applied twice | second apply: row unchanged, no broadcast (C4-T01 rule 7) | T10 |
| Failed label write | client returns `{:error, :boom}` | no note; `{:error, :boom}` returned | T11 |
| Other state | client `:ok` for `human-review` | no note | T11 |
| Non-numeric id | `note_start("ABC-12", :dispatch, t)` (Linear identifier) | `:ok`, nothing sent | T11 |
| Telemetry off | `TelemetryLifecycle.enabled?()` false, spawn ok | `dispatched_at` recorded | T12 |
| Spawn failed | `Task.Supervisor.start_child` returns `{:error, _}` | no dispatch note | T12 |
| Store down | `History` not running | hooks return `:ok`; the state write result and the dispatch are unchanged | T11, T12 |
| Daemon restart between note and flush | a cast is applied in memory but the coalesced write is lost | start falls back to C4-T03's boot telemetry scan (30 days) or the next backfill/feed write, or reads `unknown`; never a guess | covered by T1 + C4-T03 test 17 |

- **Security/privacy:** only timestamps and issue numbers. No new secrets, no
  new GitHub calls, no change to the agent environment.
- **Concurrency:** the store GenServer serialises merges; the signal rules are
  commutative, so the order of feeds does not matter. The hooks cast, so the
  orchestrator and agent runner never wait on the store.

## Compatibility and rollout

- No config, CLI or env change. No GitHub budget change.
- Store file: no new fields and no version bump (C4-T01 v1 has them).
  Rollback to a build without this ticket leaves the derived fields as last
  written; nothing else reads `Timing`.
- Rows written before this ticket read `start_src: "unknown"` until the backfill
  or feed rewrites them. That is honest, not a regression.

## Verification

Tests (PROPOSED `src/test/aiur/build_order/history/timing_test.exs` unless
named). Each builds rows with `DateTime` literals; no clock reads.

| # | Test | Expected | Fails without |
| --- | --- | --- | --- |
| T1 | "unknown start is :unknown, never created_at or end" | `start == :unknown`, `start_source == :unknown`, payload `%{start: nil, start_src: "unknown"}` | the unknown branch (M1) |
| T2 | "earliest label beats dispatch; running row has end :none" | 09:10 `:label` (with an in-progress label event at 09:20 present); `end == :none`, payload `end: nil` | the candidate order, the earliest helper |
| T3 | "dispatch fallback; a close without merge ends at closed_at" | 09:00 `:dispatch`; `end == closed_at` | the fallback / `pick_end` |
| T4 | "zero duration is kept, not widened" | `start == end`, `:label` | — (future-regression guard, named so: the server must not pad) |
| T5 | "skew within 5 min sets start to end" | `start == end == closed`, `start_source == :label` (without the clause the label is skipped and the result is `:unknown`) | the skew clause |
| T6 | "start after end beyond skew is skipped" | dispatch used; with no dispatch, `:unknown` | the validity check |
| T7 | "reopen keeps the latest end; older replay does not move it" | after `closed_at: :none`, `end` 09-01; after merge 09-04, `end` 09-04; after the 09-01 replay, still 09-04 | `last_closed_at`, latest-wins on `merged_at` |
| T8 | "pause and rework stay inside the bar" | 09:00–18:00 with telemetry pause/rework events present in the input | — (future-regression guard, named so: pause events are not inputs) |
| T9 | "closed without closed_at has unknown end" | `end == :unknown` (not `:none`), payload `end: nil` | `pick_end`'s `:unknown` clause |
| T10 | "signals are order-free; a replay changes nothing" | live 09:10 then backfill 09:05 gives `start` 09:05, and the reverse order gives the same row; a second identical apply returns `changed: []` and no PubSub message (store test with a temp dir) | `keep_earliest` (M4) |
| T11 | `test/aiur/github/tracker_history_start_test.exs` (`async: false`; stub client via `:github_client_module`; temp store started under a test name) "a successful in-progress write notes a label start; an error, another state or a non-numeric id does not" | one `in_progress_at` on `:ok` + `"in-progress"`; none on `{:error, :boom}`, on `"human-review"`, or for `"ABC-12"`; with no store running, the call returns the client's result | the tracker hook (M2) |
| T12 | `dispatcher_test.exs` "spawn notes a dispatch start with telemetry disabled" | `dispatched_at` set after `{:ok, pid}`; no note when the runner's spawn fails | the dispatcher hook, or a hook placed inside the telemetry guard (M2) |
| T13 | contract test with C3-T02 schema | `start: nil` only with `start_src: "unknown"`; integer ms otherwise | `to_payload/1` |

**Mutation checks (AGENTS.md "Tests must fail without the production
change"):**
- M1: replace the unknown fallback `{:unknown, :unknown}` with
  `{row.created_at, :label}`, then with `{end_at, :label}`. T1 must fail both
  times.
- M2: remove the tracker hook → T11 fails. Move the dispatcher hook inside the
  `enabled?()` guard → T12 fails.
- M3: replace `last_closed_at` in `pick_end` with `closed_at` → T7 fails.
- M4: replace `keep_earliest` with "new value wins" → T10 fails.
- Run each in a worktree. `git status --porcelain` must show only the reverted
  hunk. Put the commands and results in the PR body.

Command (isolated HOME per the "mix test clobbers agent-token" note):

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/build_order/history/timing_test.exs \
  test/aiur/github/tracker_history_start_test.exs \
  test/aiur/orchestrator/dispatcher_test.exs
```

All stores in tests use a temp `decision_state_dir`. No test reads `~/.aiur`.

## Pixel parity

This ticket draws nothing, but its values set the geometry C9-T09 draws.

- **Design elements fed:** `ganttHist` (J:424-470, card `y`/`h` at J:442),
  `.bd-time` and `.bd-badges span.h` (J:846, C:247-250), `.bd-status` duration
  (J:847, C:242).
- **Check 1 (value fidelity):** the C1-T02 parity screenshots load C1-T01's
  fixture payload, which keeps the design's non-integer ms on purpose (C1-T01
  "not rounded"). That payload does not pass through `Timing`, so `Timing`
  cannot break those pixels, and must not be made to. `Timing`'s duty is that
  real data reaches the client unchanged: a fixture test builds rows from every
  `live` and `dense` history row (`in_progress_at` = `start`, `merged_at` =
  `end`, via `DateTime.from_unix!(trunc(ms * 1000), :microsecond)`) and asserts
  `to_payload/1` returns `trunc(start)` and `trunc(end)` (integer ms) for every
  row, and `start_src: "label"`.
- **Check 2 (S-5, no design baseline):** one extra fixture row with
  `start: null, start_src: "unknown"`. C9-T09 renders it; C1-T02's element mode
  captures it for Kevin's DESIGN-E8 sign-off. Until signed off, that
  screenshot is the baseline, and a change to it is a failing check.
- Any difference not approved by Kevin in writing is a failing test.

## Completion and handoff

- [ ] `Timing` derives start/end by the rule above; T1-T10, T13 pass.
- [ ] The store calls `derive/2` once per merged row; C4-T02's interim
      `put_signals/2` is replaced by `Timing.merge/3`.
- [ ] Tracker and dispatcher hooks journal starts at the write; T11, T12 pass.
- [ ] M1-M4 fail as stated; commands in the PR body.
- [ ] Pixel-parity check 1 passes; check 2 fixture row handed to C9-T09.
- [ ] Docs sentences in the PR body for C12-T07 (step 7).
- **Dependents:** C9-T09 (Gantt), C8-T04 (payload), C4-T05 (`end`).

### Interface notes for neighbours

- **C4-T01** Settled 2026-10-08: the row fields are in C4-T01 v1; this ticket
  owns `Timing.derive/2` and `note_start/3` and adds the `derive/2` call to the
  store merge in its PR.
- **C4-T02** Settled 2026-10-08: its interim `put_signals/2` is replaced by
  `Timing.merge/3` (step 3). `reopened_at` is not an input here: the reopen is
  seen through `closed_at: :none` and `last_closed_at` keeps the end.
- **C4-T03** Settled 2026-10-08: it writes `dispatched_at` and `label_events`
  (no `first_in_progress_seen_at`, no `first_dispatch_at`); an absence-close is
  `closed_at: :unknown`.
- **C3-T02** Settled 2026-10-08: `start_src` and nullable `start` are accepted
  additive fields owned by this ticket (R-G1, step 6).
- **C4-T05** Settled 2026-10-08: `end` may be `DateTime`, `:none` or
  `:unknown`; C4-T05 treats both atoms as "end unknown".
- **C9-T09** does not need `start_src` (`start === null` is the marker). C9-T03
  (J:658) and C9-T12 (J:1161) already branch on `start: null`.

## Decisions made without the owner

1. **Clock-skew tolerance of 5 minutes.** A start up to 5 min after the end
   becomes start = end. Beyond that, the signal is skipped. Reason: daemon and
   GitHub clocks differ by seconds; hours mean a later event.
2. **A start after the end (beyond skew) is skipped, not clamped.** The row says
   "clamp to the design's minimum height". Clamping a heal-written label would
   draw a confident zero-length bar at the wrong moment. Skipping falls back to
   dispatch or `unknown`. Both still draw a minimum-height card (C9-T09), so the
   visible result matches the row's intent.
3. **The label beats the dispatch even when the dispatch is earlier,** as the
   row orders them. The analytics presenter (`presenter.ex:801-820`) prefers
   dispatch. Kevin may want one rule for both. Recorded here, not changed.
4. **The live dispatch note is taken on a confirmed spawn (`{:ok, pid}`),** and
   it ignores the telemetry switch. C4-T03's boot scan reads the telemetry
   `:requested` point, which also exists for a spawn that failed; for those
   tickets the dispatch start can be earlier by the retry delay. Earliest-wins
   keeps it; the label start, when present, wins anyway.
5. **End uses `merged_at`, else the latest close,** as the row says. A ticket
   that merged, reopened, and then closed without a second merge keeps the
   merge time as its end.
6. **C4-T03's in-progress `label_events` item counts as a label start.** Its
   `at` is an upper bound (a body's `updated_at`), not the label time. Earliest-wins lets
   an exact time from the hook or the backfill replace it.
7. **The journal hook sits in `GitHub.Tracker`,** not in the `Aiur.Tracker`
   facade. History is per GitHub repository; the memory and Linear trackers
   have no History. The dispatcher hook is tracker-agnostic and relies on
   `note_start/3` being a no-op without the store.
8. **Derivation runs inside the store, not in each feeder.** One call site
   instead of three keeps C4-T02 and C4-T03 unchanged and makes the rule
   impossible to bypass. The README row's "journaled at the write" is met by
   the two hooks.
9. **S-5 default followed** (end-anchored minimum-height card, "start unknown"
   tooltip). Kevin's sign-off may change the client card; the server marker
   stays.

## Review log

Adversarial review, 2026-10-08 (feasibility, coherence, design, scope):

1. Aligned the row with C4-T01's sentinels (`:none`/`:unknown`, no stored
   `nil`); running rows now have `end: :none`, closed rows without a time
   `end: :unknown`.
2. Field names now match the feeders: `first_dispatch_at` (C4-T03) replaces
   `dispatched_at`; added C4-T03's `first_in_progress_seen_at` as a label
   candidate.
3. Added `last_closed_at`: C4-T01 rule 1 and C4-T03 clear `closed_at` on
   reopen, so the old "latest wins on `closed_at`" could not keep the end.
4. Moved derivation into one `derive/2` call inside the store merge instead of
   `Timing.merge/3` calls in every feeder (C4-T01's newest-event-replaces rule
   would otherwise move earliest signals later). Removed C4-T02 `put_signals/2`.
5. Dropped the stored `end_source` and `clamped` fields (no reader); T3/T5
   assert the values instead.
6. `note_start/3`: identifier parse, non-numeric drop, non-blocking cast,
   C4-T01 health rules instead of "drop when corrupt" (C4-T01 accepts writes
   while rebuilding).
7. Corrected citations: the telemetry guard is `dispatcher.ex:2508-2516`; the
   tool writer goes through the
   `Aiur.Tracker` facade (`tracker.ex:161-168`); added the other `in-progress`
   writers (`ci_lifecycle.ex:1160, 1518`, `lifecycle_fence.ex:357`).
8. Fixed T10 (a backfill after the hook changes `sources`, so "no broadcast"
   was false); added M4, spawn-failure, other-state and non-numeric cases.
9. Rewrote pixel-parity check 1: the design data is non-integer ms and the
   parity screenshots do not pass through `Timing`; the check now asserts
   truncated integer ms.
10. Interface notes: C8-T04 already lists C4-T04 (old note was wrong); J:658,
    J:1161 and J:427 readers are owned by C9-T03, C9-T12, C9-T09; added C4-T05.
11. Docs step now targets C12-T07 and `concepts/build-orders.md` (exists);
    rollback text now matches C4-T01's `:version_unsupported` rule.
- Reconciliation 2026-10-08 (coordinator): removed the C4-T05 concurrency line; row fields now come from C4-T01 v1 (no field adds, no version bump); `first_dispatch_at` -> `dispatched_at`, `first_in_progress_seen_at` -> earliest in-progress `label_events` item; `note_start/3` source `:write`; `Timing.merge/3` replaces C4-T02's interim `put_signals/2`; `derive/2` replaces the store start/end merge (R-G4); R-G1 `start_src` step; interface notes settled; rule 5 -> rule 7.
