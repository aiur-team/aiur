---
feature_id: MP-E8
title: Continuous build history (provisional)
artifact: baseline (verified current state)
base_main_sha: b62d6d05938f3e5a6c91f0901c9b06f3ae099384
date: 2026-10-06
bucket: 2-platform
owner_gate: a Claude Design owner task (not yet written; coordinator writes it after the brainstorm)
---

# MP-E8 — Continuous build history: baseline

All code citations are against `origin/main` at `b62d6d059`, read with
`git show b62d6d059:<path>`. Paths are repository-relative. Abbreviations:
`occ/` = `src/lib/aiur_web/components/operator_control_center/`,
`occw/` = `src/lib/aiur_web/operator_control_center/`, `css` =
`src/priv/static/dashboard.css`, `hook` = `src/priv/static/build-order-grid-hook.js`.

GitHub counts were taken on 2026-10-06 with read-only `gh` (no token from `.env`).
The census data (1,344 issues) is in `~/.aiur/research-scratch-e8/issues.ndjson`.

Options and recommendations are in [options.md](options.md).

## 1. The request

Kevin wants one page that merges the Units page and the Build Order view:

- One continuous, vertically scrolling build history. The past holds every ticket
  ever worked on. The future holds every ticket that is planned (queued or
  ordered). A last, separate section holds the open tickets that are not queued.
- The DAG stays close to today's Build Order DAG.
- **Epic model (decided by Kevin):** a fixed list of general epics (for example
  Bugs, Improvements, Infra, Docs) plus short-lived per-feature epics. Each ticket
  belongs to exactly one epic. Epic columns appear and hide based on the tickets in
  the viewport.
- **Feature tagging (added by Kevin):** tickets can be tagged with a feature name. A
  feature is a package of tickets plus the DAG part that builds it, and it grows
  over time. A **feature view** highlights its tickets with the grey-out/focus UI. A
  **compact mode** removes the unrelated rows and pulls the feature into a shorter
  vertical span.
- Tickets with active agents are marked. The Units columns move into the
  ticket/agent modal.
- Filters highlight ticket types, agent types and similar, using grey-out/focus.
- Implementation is blocked on a Claude Design owner task.

The time axis is **open**. This pack does not assume an answer.

## 2. The Build Order page today

### 2.1 Routes and LiveView

- There are two routes: `/build-orders` (catalog) and `/build-orders/:root_number`
  (one selected root) (`src/lib/aiur_web/router.ex:144-145`).
  - The edge hook is served separately at `/build-order-grid-hook.js` (`router.ex:116`).
- `src/lib/aiur_web/live/build_order_live.ex`:
  - **mount (41-67):** the data source is configurable, default
    `AiurWeb.BuildOrder.DataSource` (44). Mount wires `RouteState`,
    `SourceRuntime`, `ContextRuntime`, `UsageRuntime` and `AnalyticsRuntime`. A 1 s
    UI tick runs on connect (38, 64, 115-118).
  - **handle_params (70-90):** reads only `root_number`.
  - **handle_info:**
    - GraphProjection generation and health snapshots (93, 98).
    - `:ticket_activity_changed`, `:running_changed` and
      `:build_order_adhoc_updated` trigger a reload (120-127).
  - **render (236-292):** `BuildOrderCatalog` for `:catalog`, `BuildOrderSelected`
    for `:selected`, and the `BuildOrderTicketContext` modal.
- `DataSource.subscribe_sources` subscribes to TicketActivity, the running set and
  AdHocSource (`src/lib/aiur_web/build_order/data_source.ex:82-85`).
- `PlanningSource` renders a local planning-pack JSON with provisional
  identities and never writes to GitHub
  (`src/lib/aiur_web/build_order/planning_source.ex:2-18`).

### 2.2 Roots, members, epics and waves

| Concept | Defined by | Evidence |
| --- | --- | --- |
| Root (a Build Order) | an issue with the `build-order` label | `src/lib/aiur/build_order/github_graph/queries.ex:56`; `catalog_store.ex:27,57-60` |
| Member (ticket) | a **direct** GitHub sub-issue of the root; grandchildren are not read | `queries.ex:64,93`; `member.ex:14,70` |
| Epic (column) | the member's `build-lane:<slug>` label, any slug; none → `:unassigned` | `src/lib/aiur/build_order/metadata.ex:5,47-56,109-119` |
| Wave (row) | the `phase:N` label; none → `:unphased`, shown as "TBD" | `metadata.ex:25-45`; `occ/build_order_grid_model.ex:319-323` |
| Complexity | `complexity:1..5` | `metadata.ex:25-45` |
| Ad Hoc | `build-lane:adhoc` issues that are not root members | `src/lib/aiur/build_order/ad_hoc_source.ex:2-9,54` |

- **Built-in lanes** are `plan-graph runtime dashboard-ui accounting platform`
  (`metadata.ex:5`).
- **Not used:** there is no `epic:*` label, no `Epic:` title prefix, and no epic
  sub-issue level.
  - `IssueSync` exempts `epic:*` from the zero-label heal (MP-E1 findings F5), but
    the Build Order code never reads it.
  - `aiur-build` keeps "promoted `Epic:` containers" undispatched
    (`.claude/skills/aiur-build/SKILL.md:234`), but no code groups by them.
- **Depth is two levels:** root → members.
- **There is no feature concept** beyond "a Build Order root". A root is the only
  package of tickets with a name, a fixed member list (its sub-issues), and a
  progress figure.

### 2.3 DAG layout

- **The layout is not a computed DAG layout.** It is a CSS grid:
  - columns are epic lanes, rows are waves, and each card sits in its
    (lane, phase) cell (`occ/build_order_grid_model.ex:2-6,207-256`;
    `occ/build_order_graph.ex:30`);
  - column order is the built-in lanes, then other lanes in first-appearance
    order, with `adhoc` last (`grid_model:228-235`).
- `GraphAnalysis.topological_order` is computed but not used by the grid. It also
  silently truncates at 100 nodes (`src/lib/aiur/build_order/graph_analysis.ex:10,33`).
- **Rendering is server-side** with no geometry computed on the server
  (`build_order_graph.ex:2-6`):
  - cards are 108 px wide;
  - a column holds up to 3/2/1 cards across for ≤4 / ≤7 / more epics
    (`build_order_graph.ex:203-235`);
  - there is a sticky 52 px wave gutter (220) and sticky lane headers
    (`css:8046-8049`).
- **The viewport is a bounded pan box, not page scroll:** `.bo-grid-viewport
  { max-height: min(78vh, 780px); overflow: auto }` (`css:8005-8010`). The hook
  owns zoom (0.1–1.6, kept in sessionStorage), pan and fit (`hook:10-12,116-205`).
- **Edges:**
  - the server emits a hidden `<ul data-bo-grid-edge-data>` and an empty `<svg>`
    (`build_order_graph.ex:126,145-152`);
  - the `BuildOrderGrid` hook (registered at `src/lib/aiur_web/components/layouts.ex:256-257`)
    measures each card and draws a Bézier curve from the bottom of the blocker to
    the top of the blocked card (`hook:276-317`);
  - edge states are `planned`, `cleared` and `blocking` (`grid_model:350-353`).
- **Caps:**

| Cap | Value | Where |
| --- | --- | --- |
| SelectedRoot members | 1,000 | `selected_root.ex:6` |
| Catalog roots | 100 | `catalog.ex:11` |
| Graph edges | 10,000 | `graph.ex:4` |
| Labels per member | 100 | `metadata.ex:7` |
| GraphAnalysis nodes | 100 | `graph_analysis.ex:10` |

### 2.4 Graph projection and catalog store

- `GraphProjection` is an in-memory GenServer. It holds the catalog and the
  selected roots, and on failure keeps the last-known-good generation
  (`graph_projection.ex:2-8`).
  - `demand/2` is free (49-59). `refresh/2` is an explicit, coalesced read (61-78).
- Defaults (`graph_projection_options.ex:17-45`):
  - `catalog_refresh_ms` 60 s;
  - `catalog_labels_refresh_ms` 600 s;
  - `max_selected_roots` 32 (100 at most);
  - `delivery_staleness_ms` 900 s.
  - A selected root has no timer. It is read on a write or an explicit refresh.
- `CatalogStore` builds the catalog from the webhook-fed `ResourceStore` at zero
  GraphQL cost, reading up to 100 members per root (`catalog_store.ex:2-21,28,126`).
- **GraphQL:**
  - The catalog query reads `subIssues(first:100)` with `state`/`stateReason`.
  - The selected query adds labels, `blockedBy(first:100)` and
    `blocking(first:100)` (`queries.ex:52-116`).
  - **Neither query reads `closedAt`.** Only `createdAt`/`updatedAt` are read
    (`queries.ex:97`).

### 2.5 "Tickets completed %"

There are two different figures today.

- **Catalog ("Tickets completed" column, `occ/build_order_catalog.ex:69`):**
  - completed = closed with `stateReason: completed`;
  - the denominator is members whose lifecycle can be read, so a `not_planned`
    close counts as not done;
  - the result is `:resolved` or `:partial` (`github_graph/normalizer.ex:159-182`,
    mirrored at `catalog_store.ex:125-150`).
- **Selected grid:**
  - a complexity-weighted figure, Σ(weight × fraction) / Σ weight over resolved
    cards (`grid_model:274-296`);
  - merged or closed-completed = 100 %, other closed = 0 %, an open card uses its
    worker percent (`grid_model:383-398`);
  - Ad Hoc cards are excluded (82, 239-266).
- `ProgressRenderer` fails closed to `:unknown` (`progress_renderer.ex:2-18`).
  `RootSummary` carries `progress`, `epic_count` and `phase_count`
  (`root_summary.ex:6,19-22`).

### 2.6 Grey-out and focus (the only implementation)

- **The mechanism exists only on the Build Order grid, and only on the client.**
- Hovering a card highlights its transitive dependency chain by hop distance
  (`is-hl-source`, `is-hl-linked`, `is-hl-indirect`) and dims all other edges
  (`hook:401-434`).
- Clicking a card's "blocks" tag (`[data-bo-pin]`) pins the chain and sets
  `is-locked` (`hook:358-397`).
  - CSS fades the other cards to `opacity: .3` (`css:8238-8253`) and dims edges to
    `.12` (`css:8490-8492`).
- The state is not in the URL. It is re-applied after LiveView patches
  (`hook:437-442`).
- A second variant exists in `src/priv/static/aiur-dom-svg-layout/interaction.js:328-365`
  (`is-graph-dimmed`/`is-graph-chain`). It has a forced-colors fallback that removes
  the fade (`css:1802-1862`).
- **No filter drives grey-out anywhere today.** The Units filters hide rows (§3.2).

### 2.7 Ticket context modal

- Opened by `phx-click="open-ticket-context"` on a card
  (`build_order_graph.ex:176-177`; `build_order_live.ex:181-183`). It has **no URL
  parameter**, and keeps a Back/replace history of up to 100 entries
  (`ticket_context_selection.ex:17-22`).
- **Base component** `occ/ticket_context.ex:45,127-212`:
  - Description, Dependencies, Ticket facts (State, Progress, Last activity,
    Dependency count), Progress, a sortable Logs table, Unavailable destinations,
    and links such as "Open pull request".
- **Build Order wrapper** (`occ/build_order_ticket_context.ex:39,47-135`): adds
  "Blocked by" and "Blocking" edge tables and metadata warnings.
- Its data comes from `TicketDetailCoordinator` and `TicketHistoryProvider` via
  `ContextRuntime`.

### 2.8 Other panes on the page

- **Breakdown:** wave and epic tables, plus KPIs (members, points, ready-at-start,
  longest chain) (`occ/build_order_breakdown.ex:2-21,217-226`).
- **Analytics:** current-session analytics scoped to the root
  (`occ/build_order_analytics.ex:2-18`).
- **Usage:** cost scoped to "this build" (`occ/build_order_usage.ex:2-13`).

## 3. The Units page today

### 3.1 Route, rows and columns

- `/` is `DashboardLive :index` (`router.ex:140`). `/chat/:owner/:repository/:identifier`
  and `/commands` use the same LiveView (`router.ex:141-143`).
- The Units card is at `src/lib/aiur_web/live/dashboard_live.ex:969-990`. The
  Tickets panel (backlog) sits below it (`:996`).
- **Data:** `UnitsPresenter.load` (`occw/payload_loader.ex:152`) joins five sources:
  current-run membership, the StatusReport fleet, TicketActivity, decisions and
  issue facts (`occw/units_presenter.ex:18-54`; `occw/units_row/sources.ex:26-44`).
- **Rows** are current-run membership plus a status floor
  (`occw/units_row/projection.ex:10-31`). **There is no history beyond the current
  run.**
- **Scope:** the default is `:live`; the others are `:unfinished`, `:all` and `:none`
  (`occw/units_policy.ex:9,29,82-97`).

| Column | Content | Source |
| --- | --- | --- |
| ID | TrackerIdentity identifier | `occ/units_table.ex:67-76`; `projection.ex:35-37` |
| Unit | Agent family pill (provider colour), `Cx:` complexity, model version, priority HIGH/MED/LOW | `units_table.ex:78-87,352-367`; `occw/units_presentation.ex:96-171`; issue first, then status (`occw/units_row/fields.ex:20-33`) |
| Ticket | Title and build-lane chip (else tracker state) | `units_table.ex:89-97` |
| Latest | Evidence emoji and text (including resume declined/dropped), progress bar and %, runtime, turns and context (running rows only) | `units_table.ex:99-120,377-385`; `units_presentation.ex:60-80`; `occw/units_row/resume_reason.ex:7`; `projection.ex:105-115` |
| Command | Pause/resume/lock, chat (opens the conversation drawer), Remote Control link | `units_table.ex:122-146,237-239`; `occw/units_control_policy.ex:55-117` |

- **Row tone:** paused, queued, blocked and alert (`units_table.ex:288-307`;
  `css:4492-4535`).
- **Click a cell** → `inspect-unit` → the same `TicketContext` the Build Order page
  uses (`dashboard_live.ex:436-443,1884-1893`).
- **Sort:** client-side `SortableTable`; the server accepts `id unit ticket latest`
  (`dashboard_live.ex:96`).
- **URL state:** `?v=1&scope=…&conditions=a,b` (`occw/units_url.ex:8,24-63`;
  `dashboard_live.ex:201-206,1163-1177`).
- **Nav:** the items are Units `/`, Commands, Build Order, Analytics and
  Streamdeck+ (`occw/route_registry.ex:5-56`). The Units badge is the active count
  (`dashboard_live.ex:1152-1154`).

### 3.2 Units filters

- The only dimension is a lifecycle condition: active, alert, paused, stuck (no
  chip), queued, finished (`units_policy.ex:10,26`).
  - Conditions combine with OR inside the scope (`units_policy.ex:56-65`).
  - Matching rows are **hidden**, not greyed (`units_presenter.ex:61,67`).
- **No filter by model, agent type, label or ticket type** exists.
- `occ/fleet_filters.ex` and `FleetTable` are dead code (only tests render them;
  `toggle-fleet-filter` is a no-op at `dashboard_live.ex:391`).

### 3.3 Modals and drawers (all in DashboardLive, `dashboard_live.ex:998-1026`)

| Surface | Content | How it opens |
| --- | --- | --- |
| TicketContext | §2.7 | Click on a Units row |
| ConversationDrawer `occ/conversation_drawer.ex` | Agent, Backend, Requested and Resolved model (`occw/conversation_drawer/presenter.ex:168-171`), agent log, composer, Pause | Units chat button; `/chat/...` |
| AgentLogModal `occ/agent_log_modal.ex:20-54` | Transcript, composer | Only from the dead FleetTable. Its builder still feeds the drawer composer (`dashboard_live.ex:2176-2184`) |
| TicketDetailModal `occ/ticket_detail_modal.ex:28-55` | State, Assignee, Created, Updated, "Would route to" | Tickets panel |
| AddAgentModal `occ/add_agent_modal.ex:29-110` | Start an agent on a ticket | Tickets panel (writable sessions) |

**TicketContext does not show** the Units-only fields: agent/model/Cx/priority, runtime,
turns, context, pause control, chat, Remote Control. `BuildOrderLive` does not load
`payload.units`.

### 3.4 Responsive behaviour

- **481–760 px:** Units rows become a grid; Ticket and Latest share a column
  (`css:3638-3678`).
- **≤480 px:** cells wrap (`css:3680-3720`).
- MP-N1 counts 39 `@media` rules in the dashboard, and its device check DV-P6
  loads `/build-orders` at 430 px
  ([../../bucket-3-mobile-watch/MP-N1/device-validation.md](../../bucket-3-mobile-watch/MP-N1/device-validation.md):47).

### 3.5 Stream Deck

- `AiurWeb.StreamDeckGrid` builds its own agent list from the Orchestrator snapshot
  (`src/lib/aiur_web/stream_deck_grid.ex:2-77,156`). It does not use
  `UnitsPresenter`.
- Build Order data appears there only as the lane icon and a dependency-ready flag
  (`stream_deck_grid.ex:172`; `live/streamdeck_live.ex:393`).
- **MP-E8 does not change the Stream Deck** unless a shared projection is wanted.

### 3.6 aiur-style

- `packages/aiur-style` is a scaffold: 33-line `base.css`, an empty JS barrel,
  v0.0.0 (`packages/aiur-style/README.md`, `CHANGELOG.md:8-15`).
- The dashboard loads only `/dashboard.css` (`layouts.ex:290`).
- The component plan is umbrella aiur-team/aiur#2792 (open), plan
  `docs/aiur-style/plan.md` (PR #2766).

## 4. History data: what exists to render the past

| Source | What a past ticket gets | Retention | Evidence |
| --- | --- | --- | --- |
| Closed issues | **Nothing.** No repo-wide closed-issue fetch exists; the only `state=all` listing is `build-lane:adhoc` | — | `ad_hoc_source.ex:54,265`; `github/open_issue_snapshot.ex:2-21` (open numbers, memory only) |
| `ResourceStore` (`github_resources.json`) | Issue, labels, `blocked_by`, sub-issue records | **72 h**, 100k entries, checkpointed every 30 s | `github/resource_store.ex:262-268` |
| `RecentMergeStore` (`recent_merges.ndjson`) | `merged_at`, ticket (from the `aiur/<n>` branch), merged_by | **Newest 100 merges** | `recent_merge_store.ex:18-21`; `recent_merge.ex:2-45` |
| Run telemetry (`telemetry.ndjson`) | Per ticket and attempt: dispatch, spin-up, implement, build/test, PR opened/merged, review, rework, pause, with times, backend, complexity, outcome | **30 days or 64 MB** (defaults) | `run_telemetry/lifecycle.ex:15-46`; `config/schema/observability.ex:18-21`; `run_telemetry/retention.ex:18-34` |
| Usage aggregate | Tokens and cost per ticket per pricing date | Long-term (aggregate survives compaction) | `usage_aggregate/key.ex:27-41,66`; `usage_compaction/policy.ex:20-26` |
| Pack `status.json` | Completion per pack member, with no timestamps | Permanent, per pack | `build_order/pack_status.ex:50,375-406` |
| Workspace `logs/agent.ndjson`/`agent.md` | Full transcript | **Deleted with the workspace** when the ticket closes | `agent_event_log.ex:2-30`; `orchestrator/workspace_cleanup.ex:2-24` |
| IssueLog and `event-publications.ndjson` | Per-launch logs | Oldest session deleted above 1,000 MB | `issue_log.ex:2-11`; `logs/retention.ex:2-26` |
| Event exchange | — | **No replay, no store** | `events/exchange.ex:2-30` |
| AlertLedger | Alerts only | Compacted at 8 MiB | `alert_ledger.ex:2-46` |
| TicketHistoryProvider | 50 entries per ticket, 100 identities | **Memory only**, reset on restart | `build_order/ticket_history_provider.ex:2-12`; `ticket_history_provider_options.ex:8-11` |
| `GitHubEnricher` | `pulls?state=all` with `merged_at`/`closed_at` (≤ 20 pages) | Not stored; runs only for the HTML telemetry report | `run_telemetry/github_enricher.ex:16,91,188-202` |

### 4.1 Signals that could order "time" for a past ticket

| Signal | Available for | Cost to get |
| --- | --- | --- |
| Issue `closedAt` | All closed issues (1,226) | Not fetched today; 1 GraphQL point per 100 issues (measured) |
| PR `merged_at` | Merged agent PRs (1,309 merged PRs total) | `pulls?state=all`: 1 REST call per 100 PRs |
| Agent start (`dispatch`) | Last 30 days only | Free (telemetry on disk) |
| First `agent:in-progress` label | Any ticket (timeline) | Same GraphQL timeline page as below |
| Ticket joined a feature (`feature:` label added) | Any ticket (timeline `LabeledEvent.createdAt`) | Included in the timeline page |
| Sub-issue added to a root | Any root (`SubIssueAddedEvent.createdAt`, verified on #2573) | Included in the timeline page |
| `createdAt` | All | Free in existing queries |

### 4.2 GitHub API cost

Policy (from `website/docs-app/apis/github.md`):

- The backlog and the Build Order catalog are event-sourced, with one listing per
  boot (`:296`). The divergence check reads one page, "never a paged listing"
  (`:297`).
- ResourceStore "is a cache, never the system of record" (`:516`).
- The agent `gh` wrapper refuses `gh api graphql` (`:540-564`). A backfill must
  therefore be daemon-owned.

Measured on 2026-10-06:

- **A full 1,344-issue census costs 14 pages at 1 GraphQL point each.** It reads
  `state, stateReason, createdAt, closedAt, labels(30), parent,
  subIssues.totalCount, issueDependenciesSummary`.
- **A page of 100 closed issues with `timelineItems(first:50)` filtered to
  LABELED/UNLABELED/CONNECTED/CLOSED events also costs 1 point.** The longest
  filtered timeline was 51 items, so one extra page is needed for a few issues.
- **Total for a one-time history backfill with label-event times: about 30 GraphQL
  points.**
  - Steady state can be event-sourced from the existing webhook and poll feed plus
    one listing per boot.
  - A daily `closed since <date>` page is optional.
- `blocked_by` edges for history: only 31 issues are blocked (73 edges). Read them
  with GraphQL `blockedBy(first:100)` in the same backfill. The per-issue REST call
  (`github/bounded_blocked_by.ex:5,164`) is not needed for this.
- **Writes:** feature tagging by label costs one `POST …/labels` per ticket.
  - The secondary limit is 80 content writes per minute and 500 per hour (MP-E1
    findings F11).
  - Tagging a 60-ticket feature fits in one minute. Retro-tagging 1,000 historical
    tickets takes at least 2 hours of paced writes.

## 5. Scale: aiur-team/aiur over its life (counted 2026-10-06)

| Measure | Count |
| --- | --- |
| Issues (all time, #1 created 2026-05-18) | **1,344**: 118 open, 1,226 closed (1,165 completed, 61 not planned) |
| PRs / merged PRs | 1,672 / 1,309 |
| Closed issues that ever carried an `agent:*` label | 847 (600 still `agent:done`) |
| Build Order roots (`build-order` label) | 8 (3 open). Their sub-issues are the only parent links: **116 issues (8.6 %) have a parent**; maximum depth is 1 |
| Standalone issues (no parent, no children) | **1,222 (91 %)** |
| Issues with any `build-lane:*` label | **137 (10 %)**, 15 distinct lanes. Largest: `adhoc` 30, `dashboard-ui` 20, `accounting` 16, `runtime` 14 |
| Issues with `phase:N` | 200 |
| Native `blocked_by` | 31 blocked issues, 42 blocking, 73 edges in total |
| Type labels | `bug` 411, `enhancement` 194, `refactor` 94, `documentation` 5; 659 (49 %) have none of these |
| Title contains "Epic" | 10, all closed, none with sub-issues. Epics have never been containers here |
| Umbrella-in-body pattern | aiur-team/aiur#2792 (aiur-style) lists its tickets in a body table, with no sub-issues and no `build-order` label |
| Throughput (closed) | median 38 a week (maximum 190); median 12 a day (p90 36, maximum 76) over 21 weeks |
| Open, by agent state | none 63, `todo` 30, `ci-wait` 13, `rework` 7, `in-progress` 3, `human-review` 2; `needs-triage` 23, `human:todo` 5, `agent:paused` 7 |

**What this means for rendering:**

- **History is about 1.2k nodes today**, growing by about 40 a week. That is too many
  to measure every card in one DOM, and small enough to keep the metadata in memory.
- **About 90 % of tickets carry no epic signal.** Kevin's general-epic list must
  absorb most of history, so a classification rule (or backfill) is required.
- **Edges are sparse:** 73 native edges over 1,344 issues. Most of the DAG is
  isolated nodes, so the layout is driven by time and epic, not by edges.
- **Features today are only the 8 Build Order roots** (116 members). There is no
  `feature:` label.

## 6. Planned-feature context from other packs

- **MP-E1 (build queue)** supplies the forward order: the rank key
  `{-downstream_open, priority, list_position, created_at, number}`, the item states
  (`waiting`, `promoted`, `claimed`, `held`, …), and the read model of
  `aiur queue show --json`
  ([../../contracts/queue-readiness-and-build-progress.md](../../contracts/queue-readiness-and-build-progress.md) §2.3, §3).
  - DESIGN-E1 E1-PLACE recommends a read-only queue panel on `/build-orders`
    ([../../owner-design-tasks/DESIGN-E1.md](../../owner-design-tasks/DESIGN-E1.md) §4).
- **MP-E4 (conversations):**
  - Transcripts of closed tickets are not retained today (§4).
  - MP-E4 adds a durable journal and event anchors (progress, PR opened/merged,
    Commands), and links into conversations "from the units table … build-order
    ticket context" (DESIGN-E4 line 54).
- **MP-R1:** `build-orders` owns `AiurWeb.BuildOrder*`, `Aiur.BuildProgress` and the
  16-callback `DataSource`. `dashboard-ui` owns the Units page. `aiur-style` is
  listed unchanged
  ([../../bucket-1-refactor/MP-R1/component-map.md](../../bucket-1-refactor/MP-R1/component-map.md):118-119,143,159).
  - MP-R1-C10 adds a `features[]` array to `components.json`, with IDs matching
    `^MP-(E|N)[0-9]+$`, a public flag, and `extends`/`adds` component IDs, rendered
    as the public "Planned" section (MP-R1-C10-T01 lines 31-47, 141-156).
- **MP-N1/N3:**
  - The phone opens the instance dashboard in a WebView. MP-N3 shows per-root
    build-order progress (`RootSummary.progress`), not a single instance figure.
