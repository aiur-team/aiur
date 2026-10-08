---
ticket_id: MP-E8-C8-T04
feature_id: MP-E8
chunk_id: MP-E8-C8
bucket: 2-platform
title: Ticket index assembler, live diffs, history by day
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C3-T02, MP-E8-C4-T02, MP-E8-C4-T03, MP-E8-C4-T04, MP-E8-C4-T05, MP-E8-C5-T02, MP-E8-C5-T03, MP-E8-C6-T05, MP-E8-C7-T01, MP-E8-C7-T04, MP-E8-C8-T01, MP-E8-C8-T02, MP-E8-C8-T03]
complexity: 4
design_gate: DESIGN-E8
owns_edge_cases: [EC-09, EC-10, EC-11]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C8-T04 — Ticket index assembler, live diffs, history by day

> **Wave 0b. The join point of the server track.** Paths are cited at
> `58854d4c8` (runtime worktree `aiur-worktrees/runtime/src`). Paths marked
> PROPOSED do not exist yet. `J` = `design-source/assets/build.js`. This ticket
> draws nothing. It is the real `AiurWeb.Build.DataSource`: it joins the C4–C8
> sources into the one ticket index the page renders and keeps it live.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C8 (live state,
  usage, daemon status, ticket index), ticket T04.
- **User value.** The home page shows the real repository: every closed ticket
  by day, the agents that run now, the build queue and the open tickets that
  are not queued, in the design's epic columns. A change (a label, a dispatch,
  a merge) reaches every open tab in less than one second, as one diff. A source
  that fails shows as unavailable in its section. It never shows as an empty
  section or a zero count, and it never crashes the page.
- **Deliverables.**
  1. PROPOSED `src/lib/aiur/build_order/index.ex` (`Aiur.BuildOrder.Index`):
     pure functions `assemble/2` (joins the parts into the index), `diff/2`
     (compares two indexes), `window/3` and `earlier/4` (cut day pages) and
     `resolver_context/2` (public, for C13-T01). It also holds the **core-side
     I/O** that the C3-T01 seam scan forbids in `lib/aiur_web/build/`:
     `read_core_parts/2`, `subscribe_sources/0` (every core signal),
     `subscribe/0` and `broadcast/1` on the `"build-home:index"` topic.
  2. PROPOSED `src/lib/aiur_web/build/index.ex` (`AiurWeb.Build.Index`): one
     GenServer per daemon. It calls `Aiur.BuildOrder.Index` to subscribe and
     read, reads the two web parts (C7-T01 planned, C8-T01 now), keeps the
     current index, coalesces changes for 250 ms and broadcasts one
     `{:build_changes, changes}` message per window.
  3. PROPOSED `src/lib/aiur_web/build/index_source.ex`
     (`AiurWeb.Build.IndexSource`): the `AiurWeb.Build.DataSource` callbacks
     (`snapshot/1`, `earlier/3`, `subscribe/1`) over the Index process, plus the
     per-socket blocks: `usage` (C8-T02) and `daemon` (C8-T03). It becomes the
     default source. If C11-T01 has merged first, it also implements C11-T01's
     `ticket/2` (C11-T01 interface note 1).
  4. Two small wiring edits: the Index child in `src/lib/aiur.ex` (after
     `cli_children`, see step 4), and one allowlist entry in C3-T01's seam scan
     (`AiurWeb.OperatorControlCenter.PayloadLoader`, step 6). No BuildLive edit:
     C3-T02 already owns the stale-change filter, the `resync: true` rule and
     `days` on `load-earlier` (C3-T02 step 3).
  5. ExUnit tests, a seeded parity fixture and one fixture-server route.
- **Non-goals.**
  - No new GitHub reads, no new polling. Every input comes from a store or a
    signal that a predecessor ticket provides.
  - No row producers. Now rows are C8-T01, usage is C8-T02, the daemon block
    is C8-T03, planned rows are C7-T01, not-queued rows are C7-T04, start and
    end are C4-T04, edges are C4-T05, the epic rule is C5-T02, feature figures
    are C6-T05.
  - No unfiled pack rows. C7-T02 is blocked by this ticket and plugs its rows
    into the assembler itself (C7-T02 "Assembler hook-up").
  - No usage or daemon in the shared index, and no subscription to provider
    meters or `ObservabilityPubSub` by the Index. C8-T02 and C8-T03 own those
    per socket; `IndexSource` only calls their functions (C8-T02 handoff,
    C8-T03 handoff).
  - No BuildLive protocol change (C3-T02 owns it).
  - No rendering. Day paging on the client and the scroll anchor are C9-T03.
    Empty and unavailable markers are C9-T13.
  - No websocket compression (C12-T06 decides).

## Dependencies and blockers

- **Blocked by DESIGN-E8** (feature gate E8-D6).
- **Predecessors in the row:** C3-T02 (payload v1, `Payload.validate/1`, the
  BuildLive protocol), C4-T03 (History change signal and `catch_up` status),
  C5-T02 (`Epic.resolve/2`, `Epic.unsorted/0`), C6-T05 (feature figures),
  C7-T01 (planned rows), C7-T04 (not-queued rows), C8-T01 (now rows).
- **Predecessors added by this ticket** (the neighbours' tickets ask for them,
  see "Interface notes"):
  - C4-T02, for the `:backfill` checkpoint and `History.mark_complete/1`
    (read through C4-T01 `History.health/1`). Without it, an incomplete
    history reads as a short, complete one (C4-T02 interface note 7).
  - C4-T04, for `Timing.to_payload/1` (`start`, `end`, `start_src`) (C4-T04
    interface notes).
  - C4-T05, for `Edges.build/2` and `Edges.to_payload/2` (C4-T05 interface notes).
  - C5-T03, for the epic override store. Without it, the override input is
    `:unknown`, never `:none`.
  - C8-T02 and C8-T03, because the row joins usage and the daemon block, and
    these two tickets produce them.
- **Successors:** C10-T02 (reads `status: "not_planned"`), C12-T01 (cutover on
  real data), C9-T03 (pages history with `load-earlier`), C9-T13 (reads
  `sources`), C12-T06 (measures this index at 10,000 tickets), C7-T02 (adds
  pack rows to this assembler), C7-T03 (lands after this ticket and wires
  `est`/`override`/`capacity`/`sources.estimates` into it, R-G12), C13-T01
  (calls `resolver_context/2`).
- **May run concurrently with** all of C9, C10 and C11. They build against the
  fixture source (C3-T01). This ticket does not edit
  `lib/aiur_web/live/build_live.ex`. C11-T01 and this ticket both touch
  `index_source.ex` for `ticket/2`; whichever merges second adds the clause.
- **Owner questions.** None block this ticket. It follows the written defaults
  of S-9 (unavailable is distinct from empty), S-17 (`not_planned`) and E8-R1
  (all closed tickets are in history).

## Verified starting point (`58854d4c8`)

- **No home index exists.** `AiurWeb.Build.*`, `Aiur.BuildOrder.History`,
  `.Features`, `.Epic`, `Aiur.BuildQueue` do not exist on main. They are
  PROPOSED by C3-T01, C4-T01, C6-T01, C5-T02 and MP-E1-C6-T01.
- **Source signals that exist today:**
  - `src/lib/aiur/ticket_activity.ex:17` `@topic "ticket-activity:changed"`,
    `:39` `subscribe/0`, `:227-231` broadcasts
    `{:ticket_activity_changed, payload}`.
  - `src/lib/aiur/agent_pubsub.ex:41-42` `subscribe_running/0` on
    `Aiur.AgentEvents.running_topic/0` (`agent_events.ex:319-320`,
    `"agents:running"`); `:121-123` broadcasts `{:running_changed, summaries}`.
  - `src/lib/aiur/build_order/pack_status.ex:51` `@topic`, `:79` `subscribe/0`,
    `:226-231` `broadcast_changed/1` guarded by `Process.whereis(Aiur.PubSub)`.
    C4-T01 and C6-T01 copy this shape for
    `"build-order-history:changed"` and `"build-order-features:changed"`.
- **Coalescing pattern.** `src/lib/aiur_web/live/dashboard_live.ex:81`
  `@run_summary_flush_ms 250`; `:1412-1434` (`stash_run_summary/2`,
  `flush_run_summary/1`) keeps the latest pending value and flushes once per
  window; `:1449-1454` (`schedule_run_summary_flush/0`) takes the timer from
  `Endpoint.config(:run_summary_flush_timer)` (a 3-arity function) so a test
  can fire it.
- **Shared payload pattern.** `src/lib/aiur_web/control_center_cache.ex:1-10`:
  "Every connected dashboard receives the same PubSub notifications. Without a
  shared cache, one event fans out into one Orchestrator and provider read per
  browser." The same reason applies here, and it is why the index is one
  process, not a computation per tab.
- **Financial gate.** `dashboard_live.ex:1458-1461`: a locked connection "never
  queries, subscribes to, caches, or assigns" a protected usage value;
  `:1486-1495` `authorized_context/1` is the single gate. `:1754-1770`
  (`assign_initial_provider_meters/2`): provider meters are loaded and
  subscribed only for an authorized context.
  `src/lib/aiur_web/financial_data_access.ex:115` `context/1`, `:123`
  `authorize/1`, `:144` `locked_capability/0`.
- **Time zone.** `src/lib/aiur.ex:35` sets `Tz.TimeZoneDatabase`
  (`mix.exs:172` `{:tz, "~> 0.27"}`). `dashboard_live.ex:1158-1163`
  `browser_time_zone/1` reads the zone from the connect params and falls back
  to `"Etc/UTC"`. `src/lib/aiur/claude/reset_time.ex:37-44` `candidates/3`
  handles `{:ambiguous, first, second}` and `{:gap, _before, after_gap}` from
  `DateTime.new/4`. This ticket uses the same handling for local midnight.
- **Supervision.** `src/lib/aiur.ex` (`Aiur.Application`): `:86-110` explain
  the `:rest_for_one` strategy (`:125`), so a child's crash restarts every
  child after it. `:262` `child_specs/1` is pure and is what
  `test/aiur/application_test.exs` asserts on. `:486-488` start the dashboard
  children (`ControlCenterCache`, `FinancialData.Supervisor`, `HttpServer`)
  only when `dashboard?`. `:495-499`: `Aiur.AllowedContributors` is the last
  entry of the main list "so a restart of it can never cascade". **But it is
  not the last child:** `:503` appends `cli_children` (`:278-289`:
  `Aiur.Tmux`, `Aiur.PaneManager`, `Aiur.Opencode.PrewarmSupervisor`,
  `Aiur.AgentList.App`, `Aiur.AgentList.Input`, `Aiur.LauncherWatchdog` in an
  interactive run), and `:108` appends `Aiur.SupervisionHealth` after all of
  them (`:506-508`).
- **Now-band input.** `src/lib/aiur_web/operator_control_center/payload_loader.ex:15-31`
  `PayloadLoader.load(:cached)` goes through `ControlCenterCache`; `:150-155`
  builds `:units` with `UnitsPresenter.load/2`
  (`units_presenter.ex:15-18`). C8-T01 `NowRows.build/2` takes that `:units`
  value. `PayloadLoader` is not on the C3-T01 seam allowlist.
- **Reusable pieces:**
  - `src/lib/aiur/build_order/lifecycle.ex:1-62` `ProviderHealth` (`state`,
    `complete?`, `observed_at`, `failure`); `:65-105` `Lifecycle.from_github/2`
    (`state_reason` `:completed | :not_planned | :duplicate | :reopened | :none
    | :unknown`).
  - `src/lib/aiur/build_order/metadata.ex:21-58, 99` `Metadata.parse/1` returns
    `complexity: 1..5 | :unknown` from `complexity:N` labels.
  - `src/lib/aiur/github/config.ex:54-73` `configured_repo/0` →
    `{:ok, {owner, name}}` or an error. It is the source of `repo.url` (EC-29).
  - `src/lib/aiur_web/build_order/runtime.ex:6-19` `safe_source_call/4` (rescue
    and catch exit, log, fallback). `:24-34` `display_now/0` with the
    `:build_order_display_clock` override.
- **Design data shape** (J:113–297): `build(kind)` returns `{ kind, epics,
  features, order, all, byId, hist, now, plan, nq, children, counts, failedId }`
  (J:294).
  - `epics`: general epics with `general: true` (J:115), `unsorted` (J:116),
    and one entry per feature epic `{key, label, hue: <feature hue>, icon:
    "layers", feature: k, temp: true}` (J:120).
  - `order`: the general keys in config order, then the features sorted by
    `from`, each with its epics, then `"unsorted"` (J:289–292).
  - `counts`: per epic key over **all** rows, `t.epic || "unsorted"` (J:293).
    The lane header prints `D.counts[k] || 0` (J:788). The epic filter lists
    only keys with a count (J:1100).
  - History rows have `status: "done"` (or `"failed"` for one demo row, J:198),
    `pct: 100`, and `agent: {model, state: null, effort}` (J:191).
  - The card icon comes from `type`: `bug`, `docs`, `chore`; any other type
    gets `pen` in the `design` epic and `feature` elsewhere (J:840).
    `PTS = [1, 2, 3, 5, 8]` (J:93).
- **Design paging** (client only):
  - `histDays()` is the sorted set of local midnights of `t.end`
    (`setHours(0,0,0,0)`, J:744);
  - `initHistFrom()` keeps the last two days, or one for `D.kind === "dense"`
    (J:746);
  - `moreHistory()` is true when `S.histFrom` is after the first day (J:745);
  - `loadEarlier()` moves back one day and keeps the scroll anchor (J:747–754);
  - a span greater than 1 moves `S.histFrom` back to cover `span` days (J:642);
    `SPANS = [1, 2, 3, 5, 7, 10, 14, 21, 30]` (J:302);
  - the history header prints "since <day> — scroll up to load earlier days" and
    "<shown> of <hc> loaded", where `hc = D.hist.length` is the total (J:657–658).
  With paging, the client holds only the loaded rows, so the total must come
  from the server.

## Chosen design

### Three layers

```text
History · Feeder · Features · FeatureStats · EpicOverrides ·
Edges · Timing · Config epics · NotQueued (C7-T04) · repo       (core, read by Aiur.BuildOrder.Index)
PlannedRows (C7-T01) · NowRows (C8-T01) over PayloadLoader      (web, read by AiurWeb.Build.Index)
          │ read on a signal (each read is a "part")
          ▼
AiurWeb.Build.Index (GenServer, one per daemon)
  parts cache → Aiur.BuildOrder.Index.assemble/2 → index
  diff(old, new) → Aiur.BuildOrder.Index.broadcast/1 on "build-home:index"
          │                                    ▲
          ▼                                    │ call {:window, tz} / {:earlier, …}
AiurWeb.BuildLive (per tab)  ◄── IndexSource ──┘
  + per socket: usage (C8-T02 Usage.load/2 + block/3, only when authorized)
  + per socket: daemon (C8-T03 Freshness.read_daemon/1, Freshness.subscribe/1)
```

- **Why one process:** the join and the diff cost the same for every tab. One
  process does them once, as `ControlCenterCache` does for the Operator Control
  Center. Each tab keeps only its window, not the whole index (10,000 rows).
- **Why usage is not in the index:** the index broadcasts to every tab. A
  locked tab must never receive a usage value, even in its mailbox
  (`dashboard_live.ex:1458-1461`). So usage is read and subscribed per socket,
  only for an authorized context, through C8-T02.
- **Why daemon is not in the index:** C8-T03 reads it per socket with its own
  10 s tick and `push_daemon?/2` rule, and its daemon diffs bypass the
  coalescer (C8-T03 handoff). A second daemon path in the Index would send the
  same block twice with two different clocks.
- **Layering and the seam scan.** C3-T01 rule 1 lets files in
  `lib/aiur_web/build/**` reference only `AiurWeb.Build.*`,
  `Aiur.BuildOrder.*`, `Aiur.BuildQueue` and a short list of web modules.
  `Aiur.PubSub`, `Aiur.TicketActivity`, `Aiur.AgentPubSub`,
  `Aiur.BuildProgress`, `Aiur.OpenTicketSource`, `Aiur.Config` and
  `Aiur.GitHub.Config` are not on it. So every reference to them lives in
  `Aiur.BuildOrder.Index` (under `lib/aiur/`, which rule 1 does not scan and
  rule 2 does not cover). The web GenServer calls only `Aiur.BuildOrder.Index`,
  `AiurWeb.Build.{PlannedRows, NowRows}` and `PayloadLoader`. `PayloadLoader`
  is the one module that needs an allowlist entry (step 6, decision 16).
  `Aiur.BuildOrder.Index` never calls a web module.

### Parts and their failure states

Each part is read with a safe call (rescue, catch exit). A failed read keeps no
old value: the part becomes `{:error, reason}`.

| Part | Read | Signal | On failure |
| --- | --- | --- | --- |
| history | `History.snapshot/1` → `{:ok, %{rows, health}} \| {:error, health}` (C4-T01 §4.3); `History.health/1` (C4-T01; `complete?: false` with `:backfill_pending` until C4-T02 calls `mark_complete/1`); `Feeder.catch_up_status/1` (C4-T03; `{:error, :not_running}` when down) | `History.subscribe/0`, `{:build_order_history_changed, %{changed, generation, health}}` | `sources.history = unavailable`; `sections.hist = []`; `history = {from: null, more: false, total: null, undated: null}`; `counts = null` |
| features | `Features.snapshot/1` → `{:ok, %{features, owners, also, generation, health}} \| {:error, health}` (C6-T01); `FeatureStats.fact/3` + `compute_all/3` + `to_json/1` (C6-T05) | `Features.subscribe/0`, `{:build_order_features_changed, _}` | `sources.features = unavailable`; `features = {}`; each row `feature: null`, `also: []`, and the resolver gets `owning_feature: :unknown` |
| overrides | `EpicOverrides.all/1` → `{:ok, map, health} \| {:error, health}` (C5-T03; configured keys from `settings.build_order.epics`) | `EpicOverrides.subscribe/0` (`"build-order-epic-overrides:changed"`) | the resolver gets `override: :unknown` |
| epics | C5-T01 config (`Config.settings/0` → general epics) | read on every flush | the whole index is unavailable: `snapshot/1` returns `{:error, :epic_config_unavailable}`. Never the defaults (C5-T01 handoff 4; decision 14) |
| planned | `AiurWeb.Build.PlannedRows.read/1` → `%{rows, source}` (C7-T01), with `:history_snapshot` (the history part's copy), `:active` (now ids) and `:todo_label` | PROPOSED `Aiur.BuildProgress.subscribe/0` (contract §5, fed by MP-E1-C7-T02 through C7-T01's blocker; C7-T01 has no subscribe) | `sources.queue` = C7-T01's `source` as is (`disabled` or `unavailable` with its reason); `sections.plan = []` |
| not-queued | `Aiur.BuildOrder.NotQueued.build/3` over `OpenTicketSource.snapshot/1` and the queue read model (C7-T04) | `OpenTicketSource.subscribe/0` (`open_tickets:changed`), plus the history and queue signals | `sources.open_tickets` = C7-T04's `state`/`reasons`/`observed_at` (decision 17); `:unsupported` → `"unsupported"`, reason `"tracker_unsupported"`; `truncated` = C7-T04's `truncated?` (decision 18); `sections.nq = []` when `rows` is `[]` |
| now | `AiurWeb.Build.NowRows.build(PayloadLoader.load(:cached).units, repository: repo)` → `%{rows, source}` (C8-T01) | `TicketActivity.subscribe/0`, `AgentPubSub.subscribe_running/0` | `sources.agents` = C8-T01's `source`; a raise gives `unavailable`; `sections.now = []` |
| edges, timing | `Edges.build(history_snapshot, repository)`, `Edges.to_payload(by_ticket, number)` (C4-T05); `Timing.to_payload(row)` (C4-T04) | follow history | `Edges.build/2` → `{:error, :unavailable}`: every row `deps: []`, `children: []`, `dep_states: {}`, `deps_missing: null` |

`sources.history` and `sources.features` are built with C8-T03's
`Freshness.source/1` from the part's `ProviderHealth` (one mapping owner,
C8-T03 handoff). Two history overrides apply after it: `History.health/1`
with `complete?: false` gives `state: "incomplete"`, reason the health
`failure` (`"backfill_pending"`); a
catch-up status of `:failed`, `:held` or `{:error, :not_running}` on a
healthy store gives `state: "stale"`, reason `"catch_up_<status>"`, and
`observed_at` = the older of the health time and the catch-up `at` (C4-T03:
"C8-T04 shows the catch-up age, so a frozen store is visible").

Every `sources` entry carries `observed_at` (the part's own time, never the
flush time) and `reason`. The keys `history`, `features`, `queue`, `agents`,
`index` and `open_tickets` are always present (`sources.index` is the Index
process's own health: `observed_at` is its last successful flush; `estimates` and `packs` are added by C7-T03 and
C7-T02 when they wire into this assembler); a missing key fails
`Payload.validate/1` (C3-T02). The client renders the age (C9-T13, AGENTS.md
"a computed age is rendered").

### Section rule (one row per ticket)

A ticket id appears in exactly one section. Precedence:

1. `now`, when C8-T01 emits a row for it;
2. `hist`, when its History lifecycle is `closed` and its `end` is known. A
   closed row with an unknown `end` is in no section and counts in
   `history.undated`; a hist row is never sent with `end: null` (C3-T02);
3. `plan`, when C7-T01 or C7-T02 emits a row for it;
4. `nq`, when C7-T04 emits a row for it.

Every open ticket in the open-ticket snapshot appears in exactly one section
(test I16, C7-T04 handoff). A ticket that moves (plan → now → hist) is one upsert with the new `sec`. It is
never a remove plus an upsert (EC-10).

### Row assembly (fields of the C3-T02 ticket row)

| Field | Source | Unknown |
| --- | --- | --- |
| `id`, `num` | issue number (`"123"`, `123`); `pack:<slug>`/`null` for C7-T02 rows | — |
| `title`, `created` | History row | `title: ""` (no invented text, decision 9); `created: null` |
| `type` | labels: `bug` → `bug`; `documentation`, `docs` → `docs`; `chore`, `refactor` → `chore`; else `feature` | `feature` (decision 7) |
| `cx`, `pts` | the producer's `cx`/`pts` when it sends them (C7-T04); else `Metadata.parse(labels).complexity` and `FeatureStats.points/1` (C6-T05, one copy of `PTS`, J:93) | `null`, `null` (`:unknown` → `null`) |
| `epic` | `Epic.resolve/2` key (C5-T02). Inputs: labels and `labels_complete` from the C4-T01 row, the C6-T01 owner **record** (`%{feature, epic}`, not the slug) as `owning_feature`, the override; `:unknown` (never `[]` or `:none`) when a part failed (C5-T02 handoff) | always a key |
| `feature`, `also`, `added` | C6-T01 `owners` and `also`; `added?` | `null`, `[]`, `false` with `sources.features` unavailable |
| `start`, `end`, `start_src` | `Timing.to_payload/1` (C4-T04); for `now` rows, C8-T01's `start` | `null` with `start_src: "unknown"` |
| `status` | `now` → `running`; `plan` → `queued`; `nq` → `open`; `hist`: `completed` → `done`, `not_planned` → `not_planned`, any other reason → `closed` (decision 6) | — |
| `pct` | `hist` + `done` → 100; other `hist` → `null`; `now` → C8-T01; `plan`/`nq` → 0 (design, J:261, 274) | `null` |
| `agent` | `now` → C8-T01; `hist` → `{model: agent_model, state: null, effort: agent_effort}` when `agent_model` is a string | `null` |
| `wave`, `qpos`, `cue` | C7-T01 (plan); `qpos: null` on filed rows | as C3-T02 |
| `est`, `override` | not sent by this ticket: C7-T03 wires them (and `capacity`, `sources.estimates`) into the assembler in its PR (R-G12); no pack rows either (C7-T02 wires them) | `null` until C7-T03 |
| `deps`, `children`, `dep_states`, `deps_missing` | plan rows keep C7-T01's queue `deps`; otherwise `Edges.to_payload/2` (C4-T05) | see parts table |
| `pr` | `{num: pr_number, state: "merged"}` only when `merged_at` and `pr_number` are known | `null` (never invented, J:1310) |
| `ord` | `hist`: `start`, else `end`; `plan`: C7-T01's `ord`; `nq`: C7-T04's `ord` (number ascending, C7-T04 decision 2, which overrides C3-T02's `−created`); `now`: C8-T01 | — |

The section producers give only their own fields (the column "Source" above).
Everything else comes from the join, so a field has one owner. When a producer
sends a field that the join could also derive (`title`, `created`, `cx`, `pts`
on C7-T04 rows), the producer value wins: it read the fresher source.

### Catalogue blocks

- `epics`: each configured general epic with `general: true`; each feature epic
  as `{key, label, hue: <feature hue>, icon: "layers", feature: slug, temp:
  true}` (J:120); `Epic.unsorted/0` (J:116).
- `order`: general keys in config order, then features sorted by `from`
  (a `null` `from` sorts last, ties by slug), each feature's epic keys in order,
  then `"unsorted"` (J:289–292).
- `counts`: rows per epic key over the whole index, all four sections (J:293).
  `counts` is `null` when the history part is unavailable or incomplete
  (`History.health/1` `complete?: false`). A partial count
  must not print as a real one in the lane header (J:788).
- `features[k]`: `{key, label, hue, epics, from, to, stats}`, where `stats` is
  the C6-T05 output (`null` fields stay `null`).
- `repo`: `{url: "https://github.com/<owner>/<name>/"}` from
  `GitHub.Config.configured_repo/0`; `null` on an error (EC-29).
- `history`: `{from, more, total, undated}`:
  - `total` = the number of history rows that have an `end` (all statuses);
  - `undated` = closed rows whose `end` is unknown (C4-T04 T9). They are on no
    day page, and the count says so;
  - both are `null` when the history part is unavailable.

### Day pages (EC-09)

- **Day:** the local calendar day of `end` in the socket's time zone. Local
  midnight is `DateTime.new(date, ~T[00:00:00], zone, Tz.TimeZoneDatabase)`:
  `{:ok, t}` → `t`; `{:ambiguous, first, _}` → `first`; `{:gap, _, after}` →
  `after` (the `reset_time.ex:37-44` handling). A zone the database does not
  know becomes `"Etc/UTC"`, and the reply says which zone it used
  (`history.tz`).
- **Active day:** a day with at least one history row.
- **Initial window** (`snapshot/1`): all `now`, `plan` and `nq` rows, and the
  history rows on the last **two** active days. `history.from` = local midnight
  of the earlier of those two days; `more` = an earlier active day exists.
  The design's one-day rule is for the `dense` demo dataset (J:746), not for
  real data (decision 3).
- **Earlier page** (`earlier/3`): the history rows on the `days` active days
  strictly before `before` (`days` default 1, range 1..31). The client asks for
  `days = span - loaded` when a span is wider than the loaded days (J:642).
- History rows are kept sorted by `end` in the Index state. A page is one pass
  over that list (`ponytail:` linear scan; switch to a day index if C12-T06
  measures it above budget at 10,000 rows).

### Changes and the BuildLive protocol (EC-10, EC-11)

`AiurWeb.Build.Index` broadcasts on `"build-home:index"`:

```elixir
{:build_changes, %{index_generation: pos_integer(), now: ms,
                   upsert: [row], remove: [id], set: %{optional(block) => value},
                   resync: false}}
# block ∈ :epics | :features | :order | :counts | :sources | :history_meta | :repo
# (C3-T02 also allows :daemon, :usage, :writable; C8-T03, C8-T02 and BuildLive send those per socket)
{:build_changes, %{index_generation: g, resync: true}}   # sent once after the Index (re)starts
```

The message shape, the stale-change filter and the `resync: true` rule are
C3-T02's (its "Epoch and generation" section and step 3). This ticket only
produces the messages; it changes no BuildLive code.

- **Coalescing:** the first signal of a window starts a 250 ms timer (the
  `dashboard_live.ex:81` value). Later signals in the window only mark parts
  dirty. On the timer, the Index re-reads the dirty parts, assembles, diffs and
  broadcasts at most one message. The timer is injectable (`:timer` option, the
  `:run_summary_flush_timer` pattern).
- **Diff:** `upsert` = rows that are new or not equal to the old row; `remove`
  = ids no longer in the index, in the same message as any upsert of the same
  flush (C7-T02 uses this for a filed `pack:` row, EC-23); `set` = top-level
  blocks that changed. An unchanged result broadcasts nothing.
- **`history_meta`** carries `total` and `undated` only. `from` and `more` are
  per socket; BuildLive keeps them in `:build_history` (C3-T02 step 3, rule 5).
- **Stale changes:** `snapshot/1` returns the `index_generation` it was cut at.
  C3-T02's BuildLive stores it in `:build_index_generation` and drops any
  change with `index_generation ≤` that value. It is not sent to the browser.
- **Index restart:** the new process starts at `index_generation` 1 and sends
  `resync: true` from `handle_continue(:load, _)`. C3-T02's BuildLive applies
  the `resync` rule **before** the stale filter, pushes an empty `build-diff`
  with its generation advanced by 2, and the client resyncs (C3-T02 decision
  table, "gap → resync"). The new snapshot resets `:build_index_generation`
  to the new, lower value.

### DataSource callbacks (`AiurWeb.Build.IndexSource`)

```elixir
@spec subscribe(keyword()) :: :ok | {:error, term()}
# Aiur.BuildOrder.Index.subscribe/0 ("build-home:index"), then
# AiurWeb.Build.Freshness.subscribe(opts) (C8-T03), then C8-T02's
# Usage.subscribe(opts[:financial]) for an authorized socket only. This runs in
# the LiveView process, so usage stays per socket and never on the Index topic.
@spec snapshot(keyword()) :: {:ok, map()} | {:error, term()}
# opts: :time_zone, :financial. GenServer.call(Index, {:window, zone}, 4_000), then
#   usage:  C8-T02 Usage.block/3 (Usage.load/2 only when opts[:financial] is
#           {:ok, %FinancialDataAccess.Context{}}; the locked block otherwise)
#   daemon: C8-T03 Freshness.read_daemon(opts)
@spec earlier(integer(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
# opts: :days (1..31). GenServer.call(Index, {:earlier, before, zone, days}, 4_000).
```

A call to a missing or dead Index returns `{:error, :index_not_running}`; a
call that does not answer in 4 s returns `{:error, :timeout}`. The 4 s bound is
below C3-T02's 5 s `safe_read/1` limit, so the source answers before BuildLive
kills the task. The C3-T01 page then shows its unavailable state.

## Implementation steps

1. **`Aiur.BuildOrder.Index`** (PROPOSED `src/lib/aiur/build_order/index.ex`):
   - `read_core_parts(dirty, opts)`: the core reads in the parts table
     (history, backfill, catch-up, features, overrides, epics, not-queued,
     repository, todo label), each through a local `safe/2` (rescue and catch
     exit, as `AiurWeb.BuildOrder.Runtime.safe_source_call/4` does,
     `runtime.ex:6-19`). Every dependency is an injectable option (the
     `AiurWeb.BuildOrder.DataSource` pattern).
   - `subscribe_sources/0`: `History.subscribe/0`, `Features.subscribe/0`,
     `EpicOverrides.subscribe/0`, `Aiur.BuildProgress.subscribe/0`,
     `Aiur.OpenTicketSource.subscribe/0` (`open_ticket_source.ex:88`,
     `open_tickets:changed`),
     `Aiur.TicketActivity.subscribe/0` (`ticket_activity.ex:39`),
     `Aiur.AgentPubSub.subscribe_running/0` (`agent_pubsub.ex:42`).
     `EpicOverrides.subscribe/0` is `build-order-epic-overrides:changed`
     (C5-T03); C7-T03 adds `build-estimates:changed` here in its PR.
   - `subscribe/0` and `broadcast/1` on `"build-home:index"`; `broadcast/1` is
     guarded by `Process.whereis(Aiur.PubSub)` (`pack_status.ex:226-231`).
   - `assemble(parts, opts)`: catalogue blocks, then rows by the section rule,
     then per-row fields by the table. Tests check rows with C3-T02's
     `Payload.row/1` and messages with `Payload.validate/1`; runtime does not.
   - `resolver_context(parts, number)`: public, `@doc false`, the
     `Epic.resolve/2` input for one ticket (C13-T01 calls it).
   - `diff(old, new)`, `window(index, zone, now)`, `earlier(index, before,
     zone, days)`, `local_midnight(date, zone)`.
   - A `@spec` on every public `def` (`mix lint` runs `specs.check`).
2. **`AiurWeb.Build.Index`** (PROPOSED `src/lib/aiur_web/build/index.ex`):
   - `init/1`: `Aiur.BuildOrder.Index.subscribe_sources/0`, then
     `{:ok, state, {:continue, :load}}`. `handle_continue(:load)` reads all
     parts, assembles and broadcasts `resync: true`.
   - `handle_info/2`: one clause per signal marks parts dirty and starts the
     250 ms timer if none runs; a catch-all clause ignores other messages.
   - `:flush` starts **one** read task (`Task.async/1`; the function catches
     every error, so it always returns a parts map). The web parts are read in
     the task too: `AiurWeb.Build.PlannedRows.read/1` and
     `AiurWeb.Build.NowRows.build(PayloadLoader.load(:cached).units, …)`.
     While the task runs, the GenServer keeps answering `{:window, _}` and
     `{:earlier, …}` from the last index, and new signals only mark parts
     dirty. On `{ref, parts}`: assemble, diff, broadcast at most one message,
     and start the next window if parts became dirty meanwhile. On
     `{:DOWN, ref, …}`: mark the read parts unavailable and assemble.
   - `handle_call({:window, zone}, …)` and `handle_call({:earlier, …}, …)`.
3. **`AiurWeb.Build.IndexSource`** (PROPOSED): the three callbacks above.
   Change C3-T01's `DataSource.source/0` default from `__MODULE__` to
   `AiurWeb.Build.IndexSource` (C3-T01 `data_source.ex` line `def source`). The
   fixture source stays selectable with `:build_data_source`. If C11-T01 is on
   main, add `ticket/2` as `GenServer.call(Index, {:ticket, id}, 4_000)` over
   the full index.
4. **Supervision** (`src/lib/aiur.ex`, `Aiur.Application.child_specs/1`):
   append the Index **after** `cli_children`, so that only
   `Aiur.SupervisionHealth` (appended at `:108`) follows it:

   ```elixir
   |> Kernel.++(cli_children)
   |> Kernel.++(List.wrap(if(dashboard?, do: AiurWeb.Build.Index)))
   ```

   Placing it after `Aiur.AllowedContributors` (`:499`) is not enough: in an
   interactive run `cli_children` (the TUI: `Aiur.Tmux`, `Aiur.PaneManager`,
   `Aiur.AgentList.App`, …) come after that line, and under `:rest_for_one`
   an Index crash would restart the operator's terminal UI. Restarting
   `Aiur.SupervisionHealth` is harmless: it is a monitor that is always last
   (decision 4).
5. **BuildLive:** no change. Check, before starting, that C3-T02's
   `build_live.ex` has `source_opts/1`, the `resync`-before-stale order and
   `days` on `load-earlier`. If one is missing, stop and report it to C3-T02;
   do not add a second copy here.
6. **Seam allowlist:** add `AiurWeb.OperatorControlCenter.PayloadLoader` to
   rule 1 of C3-T01's PROPOSED `src/test/aiur_web/build/seam_test.exs`, with a
   comment that names this ticket and C8-T01 (decision 16).
7. **Fixture route:** PROPOSED `GET /build-fixture/index-live` in
   `src/test/browser/fixture_server.exs` (next to C3-T01's PROPOSED
   `/build-fixture/:dataset`). It starts an Index over stores seeded from
   `live.json` in a temp directory (see "Pixel parity").
8. **Docs:** none. No config key, CLI flag, environment variable or new
   surface (AGENTS.md "Docs ship with the change"). The PR says so.

## Non-happy paths

| Case | Concrete input | Expected | Test |
| --- | --- | --- | --- |
| History corrupt | `History.snapshot/1` → `{:error, %ProviderHealth{state: :unavailable, failure: :history_corrupt}}` | `sources.history.state = "unavailable"`, reason `"history_corrupt"`; `hist = []`; `history.total = null`; `counts = null`; `plan`, `now`, `nq` still filled | I9 |
| History incomplete | `History.health/1` `complete?: false`, failure `:backfill_pending` | `sources.history.state = "incomplete"`; rows sent; `counts = null` | I10 |
| Catch-up stopped | healthy, complete store; `Feeder.catch_up_status/1` → `{:error, :not_running}`, or `%{status: :failed, at: t}` | `sources.history.state = "stale"`, reason `"catch_up_not_running"` / `"catch_up_failed"`; `observed_at` = the older time; rows and `counts` still sent | I13 |
| Not-queued source states | C7-T04 result `state: :unsupported`; `state: :stale, reasons: [:open_tickets_stale, :queue_stale]` | `sources.open_tickets` = `"unsupported"` / `"tracker_unsupported"`; `"stale"` / `"open_tickets_stale,queue_stale"` (every cause kept) | I14 |
| No history yet | complete, zero closed rows | `hist = []`, `from: null`, `more: false`, `total: 0`, state `ok` (C9-T13 shows "No history yet", J:419) | W8 |
| Feature store down | `Features.snapshot/1` → `{:error, _}` | `sources.features` unavailable; rows `feature: null`; resolver source `"unknown"`, never `"default"` | I11 |
| Epic config error | `Config.settings/0` → `{:error, _}` | `snapshot/1` → `{:error, :epic_config_unavailable}`; no default epics | I12 |
| Part raises | C8-T01 read raises `RuntimeError` during a flush | `sources.agents` unavailable; Index alive; one broadcast with `set.sources` | D7 |
| Index crash | kill the Index process | supervisor restarts it; it sends `resync: true`; BuildLive pushes a gap; the client resyncs | D8 |
| Index crash in an interactive run | kill the Index with the TUI children running | no TUI child restarts; only `Aiur.SupervisionHealth` follows it | A1 |
| Slow part | `PayloadLoader.load/1` stub blocks 2 s during a flush | `snapshot/1` from a new tab answers from the last index in < 100 ms | D9 |
| Index down at mount | no registered Index | `snapshot/1` → `{:error, :index_not_running}` | S3 |
| Section move | #12 in `plan`, then C8-T01 emits #12 | one message; `"12"` once in `upsert` with `sec: "now"`; not in `remove` | D2 |
| Two parts claim a ticket | #12 in C7-T01 and C8-T01 | one row, `sec: "now"` | I2 |
| Burst | 40 signals in 100 ms | one broadcast after the window | D1 |
| No change | a signal whose re-read gives equal rows | no broadcast | D3 |
| Late change | a change with `index_generation` 5 after a snapshot cut at 6 | dropped by BuildLive | D6 |
| Row leaves, another arrives in one window | #41 leaves every section, #640 enters `plan` | one message: `remove: ["41"]`, `upsert` #640 (the mechanism C7-T02 uses for a filed pack row, EC-23) | D4 |
| Day boundary | row `end` 2026-10-07T06:30Z | Oct 6 in `America/Los_Angeles`, Oct 7 in `Etc/UTC` | W2 |
| DST and midnight gap | `America/Los_Angeles` 2026-11-01 (25-hour day); a zone and date where local midnight does not exist (check `America/Santiago` 2026-09-06 with `Tz` first) | day start is the first instant after the gap; no row is lost or counted twice | W3 |
| Unknown zone | `"Mars/Base"` | pages in `Etc/UTC`; `history.tz = "Etc/UTC"` | W4 |
| Undated closed row | closed, `end: nil` | on no page; `history.undated = 1`; not in `total` | W7 |
| Bad `days` | `0`, `32`, `"3"` | `invalid_params`; view alive | W6 |
| Locked usage | `financial` absent or `:locked` | usage is the locked block; `Usage.load/2` not called; the Index topic never carries usage | F1, F2 |
| Hostile title | History title `<img src=x onerror=…>` | sent raw; `Payload.validate/1` ok (escaping is the client's, C3-T02) | P2 |

- **Security and privacy:** no new external read. The Index topic carries ticket
  facts that every dashboard viewer already sees; usage stays per socket. The
  `PayloadLoader` payload that the Index reads for now rows also holds provider
  facts; the Index keeps only `NowRows.build/2`'s output and drops the rest in
  the read task, so no provider value enters the index or the topic (F2).
- **Concurrency:** the Index is the only writer of the index. The read task
  returns parts; only the GenServer assembles and swaps the index, so a
  `{:window, _}` call sees the old index or the new one, never half of it.
- **Idempotency:** `diff/2` of equal indexes is empty, so a repeated signal
  costs one read and no broadcast.
- **Memory:** one index per daemon (measured in the V-bench test). Each tab
  holds its window only.

## Compatibility and rollout

- No configuration, CLI, environment variable or migration. No GitHub budget
  change: every part is a local store or projection (AGENTS.md "A claimed saving
  must be measured": this ticket claims none).
- `/build` (temporary route, C3-T01) shows real data after merge. `/` is
  unchanged until C12-T01.
- The Index starts only with the dashboard (`dashboard?`), like
  `ControlCenterCache`. A `--no-dashboard` run has no Index and no cost.
- **Rollback:** set `:build_data_source` to the fixture source, or revert. No
  data is persisted by this ticket.

## Pixel parity

This ticket draws nothing. Its parity is data parity: the same inputs must give
the payload that the design's `build()` gives, so the C1-T02 screenshots of the
real source match the design.

- **Design elements:** the `D` object (J:294) and its blocks `epics` (J:115–120),
  `order` (J:289–292), `counts` (J:293), the four sections and `children`
  (J:288); `histDays`/`initHistFrom`/`moreHistory`/`loadEarlier` (J:744–754);
  the history header text (J:657–658); the lane count (J:788).
- **What must match exactly:** the epic keys, labels, hues, icons and their
  order; every count; the section of each ticket; the order of rows inside a
  section; the two-day initial window and its `from` day; the "N of M loaded"
  numbers (`M` = `history.total`).
- **Check 1 (ExUnit, P1):** a test helper seeds History, Features, the override
  store and stub C7/C8 parts from PROPOSED `src/test/fixtures/build_home/live.json`
  (C1-T01/C3-T02 fixture, `TZ` `America/Los_Angeles`, `now` 2026-10-07 14:20).
  `IndexSource.snapshot/1` must equal the fixture snapshot except this
  allowlist: `epoch`, `generation`, `sources.*.observed_at`, the per-socket
  blocks `usage`, `daemon` and `writable` (stubbed; C8-T02, C8-T03 and C3-T02
  check them), and the fields the
  fixture does not carry (`start_src`, `dep_states`, `deps_missing`,
  `history.total`, `history.undated`, `features.*.stats`). Repeat for
  `noqueue` and `newrepo`.
- **Check 2 (C1-T02):** `expectDesignParity(pair, { name: "index-live" })` with
  the design at `?example=live` and the product at
  `/build-fixture/index-live`, at 1440, 1024 and 390 px, dark and light,
  Gruvbox and default palettes. Region checks on `.bd-lanes` (counts and
  order) and on the history header `.bd-sech`. Zero difference above the
  recorded anti-aliasing floor.
- **`dense` is not compared on the real source.** Its one-day window is a rule
  of the demo dataset (J:746). The fixture source keeps it for C1-T02's dense
  cells (decision 3).

## Verification

ExUnit (PROPOSED `src/test/aiur/build_order/index_test.exs`,
`src/test/aiur_web/build/index_server_test.exs`,
`src/test/aiur_web/build/index_source_test.exs`; A1 goes in the existing
`src/test/aiur/application_test.exs`, which already asserts on
`child_specs/1`; S4 is C3-T01's PROPOSED `src/test/aiur_web/build/seam_test.exs`). Every part is a stub module
passed by option. No test reads `~/.aiur` or a live store: stores use
`tmp_dir`.

| Test | Input | Expected | Fails without (mutation) |
| --- | --- | --- | --- |
| I1 join | History #7 closed completed, merged PR 233, labels `bug`, `complexity:2`; owner feature `pag` | row: `sec hist`, `status done`, `pct 100`, `type bug`, `cx 2`, `pts 2`, `feature "pag"`, `pr {233, merged}` | any field mapping |
| I2 precedence | #12 in C7-T01 and C8-T01 parts | one row, `sec "now"` | reverse the precedence list |
| I3 not planned | closed `not_planned` | `status "not_planned"`, `pct null` | map it to `"done"` |
| I4 other closure | closed `duplicate`; closed `:unknown` | `status "closed"` for both | map them to `"not_planned"` or `"done"` |
| I5 unknown model | History `agent_model: :unknown` | `agent: nil` (no `"claude"`) | a default model |
| I6 unknown complexity | no `complexity:` label | `cx: nil`, `pts: nil` | `cx || 1` |
| I7 catalogue | 4 general epics, features `khala` (from 09-16) and `pag` (from 09-29) | `order` = `bugs design infra docs f-khala-srv f-khala-ui f-pag-api f-pag-ui unsorted`; feature epics `icon "layers"`, `temp true`, feature hue | sort by slug instead of `from` |
| I8 counts | rows in every section | `counts` per key over all sections; `null` when history incomplete | count only loaded rows; count anyway when incomplete |
| I9–I12 | the four failure rows above | as the Non-happy table | map the error to `"ok"`, `[]` with state ok, or default epics |
| I13 catch-up | the "Catch-up stopped" row | `state "stale"`, reason `catch_up_*`, older `observed_at` | ignore the catch-up status; take the newer time |
| I14 open-tickets source | the "Not-queued source states" row; and `truncated?: true` | as the Non-happy table; `truncated: true` | send C7-T04's `:unsupported` as `"unavailable"` or `"disabled"`; keep only the first reason; hard-code `truncated: false` |
| I16 one section | open snapshot with #50 `agent:todo` missing from History, #51 `human-review` with no agent, #52 queued, #53 plain open | each open id in exactly one of `now`, `plan`, `nq` | a ticket in two sections or in none |
| E1 epic defaults | default config general epics (C5-T01) vs the design's `epics` (J:115–116) from the vendored `design-source/assets/build.js` | equal keys, labels, hues, icons, order (owned here, moved from C5-T01) | a default epic drifts from the design |
| I15 producer wins | C7-T04 row `cx 3` while the History labels say `complexity:2` | `cx 3`, `pts 3` | let the join overwrite producer fields |
| W1 window | rows on 5 active days, `America/Los_Angeles` | hist rows from the last 2 days only; `from` = midnight of the 2nd-last; `more true`; `total` = all dated rows | `window/3` returns all rows |
| W2–W4 | day boundary, DST, gap, unknown zone | as the Non-happy table | UTC days for every zone; `DateTime.new!` |
| W5 earlier | `before = from` with an empty calendar day between | the previous **active** day; `more false` at the first day | step one calendar day |
| W6 days | `days: 3`; `0`; `32` | 3 active days; two `invalid_params` | no range guard |
| W7 undated | closed row with `end: nil` | on no page; `undated 1` | put it on day 0 or on `created` |
| W8 empty | complete, no closed rows | `total 0`, state ok | — (guard for the `null`-vs-0 rule; named "guard" in the test) |
| D1 coalesce | 40 signals, injected timer | one `{:build_changes, _}` | flush per signal |
| D2 move | plan → now | id once in `upsert`, not in `remove` | remove-then-upsert |
| D3 no change | equal re-read | no message | broadcast always |
| D4 leave and enter | #41 leaves, #640 enters in one window | one message with `remove ["41"]` and the #640 upsert | two messages |
| D5 set blocks | a count changes, epics do not | `set` has `counts` only | send all blocks |
| D6 stale change | LiveView over the real `IndexSource`: snapshot cut at 6, change 5 arrives | no `build-diff` pushed | `snapshot/1` leaves out `index_generation` (C3-T02's filter then never drops) |
| D7 part raises | stub raises in a flush | `sources.agents` unavailable; Index alive | remove `safe/2` |
| D8 restart | `Process.exit(index, :kill)` with a mounted BuildLive | `assert_push_event "build-diff"` with generation + 2 | `handle_continue(:load)` without the `resync: true` broadcast |
| D9 slow part | `PayloadLoader` stub sleeps 2 s in a flush; `snapshot/1` from a second caller | answers in < 100 ms with the previous index | do the reads inline in `handle_info(:flush)` |
| A1 child order | `Aiur.Application.child_specs(interactive_cli?: true, headless?: false, dashboard?: true)`; and `dashboard?: false` | `AiurWeb.Build.Index` is the last module (`Aiur.SupervisionHealth` is added later by `start/2`); absent without the dashboard | put the child after `Aiur.AllowedContributors` (`cli_children` then follow it) |
| S4 seam | C3-T01's `seam_test.exs` over the three new web files | green with only the `PayloadLoader` entry added | reference `Aiur.PubSub` or `Aiur.TicketActivity` from `lib/aiur_web/build/index.ex` |
| F1 locked snapshot | `financial: :locked` | usage block `state "locked"`; no `providers`, `apis`; a `Usage.load/2` spy is not called | call `Usage.load/2` without the gate |
| F2 topic has no usage | subscribe to `"build-home:index"`, run 10 flushes | no message has a `usage` key | put usage in the index |
| S3 down | no Index | `{:error, :index_not_running}` | let the exit crash the caller |
| P1 parity | seeded `live`, `noqueue`, `newrepo` | equal to the fixture (allowlist above) | any join rule |
| P2 contract | every message of D1–D9 and P1 | `Payload.validate/1 == :ok` | — (contract guard) |
| V-bench | 1,400 and 10,000 synthetic tickets (tagged `:perf_regression`) | records flush time and Index memory; asserts flush ≤ 250 ms at 1,400 | — (measurement; numbers in the PR body) |

Mutation check (AGENTS.md "Tests must fail without the production change"):
for each row with a mutation, apply it in a worktree, confirm `git status
--porcelain` shows only that hunk, run the test, see it fail, restore, see it
pass. Put the exact commands in the PR body.

Commands (isolated HOME, per the "mix test clobbers agent-token" note):

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/build_order/index_test.exs test/aiur_web/build/index_server_test.exs \
  test/aiur_web/build/index_source_test.exs test/aiur_web/live/build_live_protocol_test.exs \
  test/aiur/application_test.exs test/aiur_web/build/seam_test.exs
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test --include perf_regression --only perf_regression \
  test/aiur_web/build/index_server_test.exs
env -C src/browser npm run parity:matrix -- --grep index-live
```

**Manual check** (AGENTS.md "Manual testing", memory "Executor owns e2e
verification"): from the Executor repo root, launch `scripts/aiurdev --test`
with the wrapper-tmux recipe. Open `/build` on the printed dashboard port with
Playwright and take a screenshot: the sandbox tickets are in the right
sections and columns, and the history header shows "N of M loaded". Move one
sandbox ticket's label to `agent:in-progress` from the TUI path; within one
second the card leaves Planned and enters the Now band (one `build-diff` in the
browser's websocket log). Stop with `aiurdev stop`.

## Completion and handoff

- [ ] `Aiur.BuildOrder.Index`, `AiurWeb.Build.Index` and
      `AiurWeb.Build.IndexSource` exist; the Index is appended after
      `cli_children` (only `Aiur.SupervisionHealth` follows it), dashboard only.
- [ ] `DataSource.source/0` defaults to `IndexSource`.
- [ ] No BuildLive edit; C3-T02's filter, resync and `days` rules pass D6, D8
      and W6 against the real source.
- [ ] Seam scan green with the one `PayloadLoader` allowlist entry.
- [ ] Every test above passes; every listed mutation fails its test.
- [ ] P1 passes for `live`, `noqueue`, `newrepo`; the C1-T02 `index-live` cells
      have no difference above the floor.
- [ ] The PR body gives the V-bench numbers (flush time and memory at 1,400 and
      10,000 tickets) and says "no saving claimed".
- **Dependents:** C9-T03 (`load-earlier` with `days`, `history.total`), C9-T04
  (`counts: null`), C9-T13 (`sources` states incl. `incomplete`, `features`),
  C10-T02 (`not_planned`, `closed`), C10-T03 (`features.*.stats`), C12-T01
  (real data at `/`), C12-T06 (10,000-ticket measurement), C7-T02 (pack rows
  through this assembler), C11-T01 (`ticket/2`), C13-T01
  (`resolver_context/2`).
- **Sources:** tickets/README.md row C8-T04; chunks.md MP-E8-C8; plan.md §5,
  §5.1, §8 (EC-03, EC-07, EC-09, EC-10, EC-11, EC-20, EC-21, EC-23, EC-29),
  §9 (K-3, K-8); C3-T01, C3-T02, C4-T01, C4-T02, C4-T03, C4-T04, C4-T05, C5-T01,
  C5-T02, C5-T03, C6-T01, C6-T05, C7-T01, C7-T02, C7-T04, C8-T01, C8-T02, C8-T03,
  C9-T13, C10-T03, C11-T01, C13-T01 ticket docs; DESIGN-E8 S-9, S-17; the code and J lines cited above.
- **Remaining blocker:** DESIGN-E8 sign-off, then the predecessors.

### Interface notes for neighbours

State at review time (2026-10-08): most of the first draft's requests are
already in the neighbour docs. What is still open is marked **open**.

1. **C3-T02 (payload schema) — taken.** Its schema now has `sources.features`
   and the `incomplete` state, `counts: null`, `history.total`/`undated`/`tz`,
   status `closed`, `start_src`, `children`/`dep_states`/`deps_missing`,
   `features[k].stats`, `days` on `load-earlier`, and the stale-filter and
   `resync` rules in BuildLive (C3-T02 step 3). This ticket edits no BuildLive
   code.
2. **C3-T01 — taken** (arity): C3-T02 changes the behaviour to `subscribe/1`,
   `snapshot/1`, `earlier/3`. **Open:** the seam allowlist needs
   `AiurWeb.OperatorControlCenter.PayloadLoader` (step 6); this ticket adds the
   line.
3. **C4-T01 / C4-T02 / C4-T03 — taken.** Settled 2026-10-08: this ticket reads
   `History.snapshot/1`, `History.health/1` and
   `Feeder.catch_up_status/1`. History sends one `changed: [n]` message per
   batch (C4-T03 handoff).
4. **C7-T01, C7-T04, C8-T01 — taken, with their own shapes.** C7-T01 and
   C8-T01 return `%{rows, source}` (not `{:ok, rows}`); C7-T04 returns
   `%{state, reasons, observed_at, truncated?, skipped, rows}`. None of them
   subscribes; this ticket subscribes for them. Settled 2026-10-08: the
   not-queued state goes to `sources.open_tickets` with the `unsupported`
   state and a `truncated` flag (C7-T04's additive fields, R-G1); this ticket
   subscribes to `open_tickets:changed` and asserts one section per open
   ticket (I16).
5. **C7-T02 — taken.** It is blocked by this ticket and adds pack rows to the
   assembler itself.
6. **C8-T02 / C8-T03 — taken.** Usage and daemon stay per socket.
   `IndexSource.snapshot/1` puts `Usage.block/3` and
   `Freshness.read_daemon/1` in the reply; `IndexSource.subscribe/1` calls
   `Freshness.subscribe/1`; no provider-meter subscription here.
   Settled 2026-10-08: C8-T03 maps a healthy but incomplete `ProviderHealth`
   to state `incomplete`; `sources.agents` is C8-T01's `source`.
7. **C9-T04 and C10-T02 — taken:** both handle `counts: null`.
8. **C9-T13 — taken here:** `queue` and `index` are always filled (parts
   table).
9. **C10-T03.** Settled 2026-10-08: C10-T03 adds `features[k].oldest` to
   `assemble/2` in its own PR (R-G4).
10. **C11-T01 — open, ordered by merge:** `ticket/2` on `IndexSource`; the
    second of the two tickets to merge adds the clause.
11. **C13-T01 — taken:** `resolver_context/2` is public with `@doc false`.
12. **C7-T03 / C5-T01.** Settled 2026-10-08: C7-T03 lands after this ticket
    and wires estimates (R-G12); the design-vs-defaults epic test is E1 here.

## Decisions made without the owner

1. **One shared Index process,** not a join per tab. Reason: the same work for
   every tab, and 10,000 rows per tab is too much memory
   (`control_center_cache.ex:1-10` states the same rule).
2. **Usage and daemon stay per socket and out of the Index topic.** A locked
   tab must not receive a usage value at all (`dashboard_live.ex:1458-1461`),
   and C8-T03 already owns the daemon block with its own tick and diff rule.
3. **The real source always loads two active days first.** The design's one-day
   rule belongs to the `dense` demo (J:746). `dense` parity stays on the fixture
   source. A wider span loads more days with `days`.
4. **The Index is appended after `cli_children`.** Under `:rest_for_one`, its
   crash then restarts only `Aiur.SupervisionHealth` (a monitor that is always
   last); the `resync` message repairs the tabs. "After
   `Aiur.AllowedContributors`" would still restart the TUI in an interactive
   run (`aiur.ex:503`).
5. **250 ms coalescing window** (the dashboard's existing value, inside the
   row's 500 ms limit).
6. **`closed` is a new, cause-neutral status** for a closure that is neither
   completed nor not planned (`duplicate`, a missing reason). Mapping it to
   `not_planned` or `done` would name a cause we do not know (AGENTS.md "a
   collapsed cause names the collapse"). Census 2026-10-06 (baseline.md:368):
   1,226 closed issues = 1,165 completed + 61 not planned, so the population is
   0 today.
7. **`type` falls back to `feature`.** For any type that is not bug, docs or
   chore, the design's card picks the icon from the epic (`pen` in `design`,
   `feature` elsewhere, J:840), so the fallback changes no pixel.
8. **No history row gets `failed`.** The History row has no PR close state, so
   "failed" (contract §2.1: "latest ticket PR closed unmerged") cannot be told
   from a manual close. A failed open ticket is a now or not-queued row with
   agent state `error`. C4-T01 asked C8-T04 to define this.
9. **An unknown title is sent as an empty string with no fallback text.** A
   History row with `title: :unknown` is rare (a backfill gap); the card shows
   `#num` and no invented title. C9-T05 renders the empty title as-is.
10. **`pr` is sent only for a merged PR.** The state of an unmerged PR is not
    stored, and C3-T02 forbids inventing one.
11. **`counts` is `null` while history is incomplete or unavailable,** because
    the lane header would print a partial count as the real one (J:788).
12. **The stale-change filter and the restart resync are C3-T02's.** This
    ticket only produces `index_generation` and `resync: true`, so there is one
    copy of each rule.
13. **Six predecessors were added** to the row's list (C4-T02, C4-T04, C4-T05,
    C5-T03, C8-T02, C8-T03), because this ticket calls their interfaces and
    their own docs name C8-T04 as the caller.
14. **An epic config error makes the whole snapshot unavailable,** not only
    the catalogue. C5-T01 handoff 4 says "mark the epic catalogue
    unavailable", but `sources` has no `epics` key, and without the catalogue
    every row's `epic` fails C3-T02's referential rule. The page shows C3-T01's
    unavailable state with the reason `epic_config_unavailable`.
15. **Flush reads run in one task.** `PayloadLoader.load/1` can wait on the
    Orchestrator. If the GenServer read inline, a new tab's `snapshot/1` would
    wait behind the flush and time out (C3-T02 kills a read at 5 s). The task
    keeps the Index answering from the last index (D9).
16. **One seam allowlist entry (`PayloadLoader`).** C8-T01 takes the
    `UnitsPresenter.load/2` result, and `PayloadLoader.load(:cached)` is the
    one shared, cached way to get it (`payload_loader.ex:15-31, 150-155`).
    A second loader would bypass `ControlCenterCache` and cost one
    Orchestrator read per flush.
17. **`sources.open_tickets` describes the not-queued section** (C7-T04's
    state over the open-ticket index and the queue; settled 2026-10-08).
    C9-T13's `degraded` case reads it ("not-queued header has `stale, read 3 h
    ago`").
18. **`truncated?` is sent as the `truncated` flag** (C7-T04's additive
    field), not folded into a reason (settled 2026-10-08).

## Review log

Adversarial review, 2026-10-08, against the runtime at `58854d4c8`, the design
source and the neighbour ticket docs.

1. **Supervision placement was wrong.** "Last child, after
   `AllowedContributors`" still had `cli_children` (the TUI) after it
   (`aiur.ex:278-289, 503`). Moved the child after `cli_children`; added test A1
   and rewrote decision 4.
2. **Seam scan would fail.** The web GenServer was to subscribe to
   `TicketActivity`, `AgentPubSub`, `BuildProgress`, `OpenTicketSource` and
   broadcast on `Aiur.PubSub`, none of which C3-T01 rule 1 allows; the draft
   said "no allowlist entry". Moved core I/O into `Aiur.BuildOrder.Index`,
   added the one `PayloadLoader` entry, test S4 and decision 16.
3. **BuildLive edits duplicated C3-T02.** C3-T02 step 3 already has the
   stale filter, the `resync` rule, `source_opts/1` and `days`. Removed
   deliverable 4's BuildLive edits and step 5; D6 and D8 now test the real
   source against C3-T02's rules (decision 12).
4. **Daemon and usage conflicted with C8-T03 and C8-T02.** Removed the daemon
   part and its 15 s tick from the Index; `IndexSource` now calls
   `Freshness.read_daemon/1`, `Freshness.subscribe/1` and `Usage.block/3`
   per socket, with no provider-meter subscription.
5. **C7-T02 was read as an input,** but C7-T02 is blocked by this ticket and
   plugs itself in. Removed it from the parts; D4 now tests the generic
   leave-and-enter diff.
6. **Parts table used invented shapes.** Replaced with the neighbours' real
   APIs (`PlannedRows.read/1`, `NotQueued.build/3`, `NowRows.build/2` over
   `PayloadLoader`, `EpicOverrides.all/1`, `Feeder.catch_up_status/1`,
   `FeatureStats`), marked `Aiur.BuildProgress` PROPOSED, and said that
   `PlannedRows` and `NowRows` are web modules.
7. **`sources.queue`/`index` and the catch-up status had no rule.** Defined
   `sources.index` (decision 17, 18), the catch-up override and test I13/I14.
8. **Row fields:** `nq` order now follows C7-T04 (`num` ascending), `pts`
   uses C6-T05's `points/1`, the resolver gets the owner record and
   `labels_complete` (C5-T02 handoff), and producer fields win (I15).
9. **Blocking flush.** Added the read task, its failure path and test D9
   (decision 15); `IndexSource` calls use a 4 s timeout under C3-T02's 5 s.
10. **Citations corrected:** `dashboard_live.ex` 1158-1163, 1412-1434,
    1449-1454, 1458-1461, 1486-1495, 1754-1770; `financial_data_access.ex:144`;
    `reset_time.ex:37-44`; `aiur.ex` 86-110, 125, 262, 503, 506-508; J:198
    (not 196) for the failed demo row; J:840 icon rule (`pen` in `design`).
11. **Neighbour notes refreshed:** marked what the neighbours already took
    and listed what is still open (C8-T03 `incomplete`, C10-T03 `oldest`,
    C11-T01 `ticket/2`, C7-T04 fields). Added C7-T02, C11-T01 and C13-T01 as
    successors and `resolver_context/2` for C13-T01.

Residual risks: C8-T03's `incomplete` mapping is still a cross-ticket
mismatch; the `Tz` gap date for W3 (`America/Santiago` 2026-09-06) is
unverified until the test probes it; the Index restart relies on C3-T02
applying `resync` before the stale filter (a lower new `index_generation`
would otherwise be dropped until the tab resyncs).
- Reconciliation 2026-10-08 (coordinator): `Backfill.status/0` -> `History.health/1`, not-queued state -> `sources.open_tickets` with `unsupported` and `truncated` (decisions 17/18), `open_tickets:changed` and `build-order-epic-overrides:changed` named, `build-estimates:changed` left to C7-T03, `est`/`override` and pack rows left to C7-T03/C7-T02 (R-G12), plan rows keep queue `deps`, `qpos: null` on filed rows, no hist row with `end: null`, one-section test I16, epic defaults test E1 (from C5-T01), `:bench` -> `:perf_regression`, C7-T03 added to successors, Interface notes 3/4/6/9/12 settled.
