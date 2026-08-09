# Dashboard CLI Page-Parity Research

Research for #1590 at `cbc23239`. This is a design contract for the four
page-command tickets, not a CLI implementation. The source-of-truth rule is
strict: each command reads the same projection/provider as its page, never
`/api/v1/state` and never GitHub independently.

## Findings and reusable seams

| Page / route | Mount and refresh path | CLI seam | Extraction needed? |
| --- | --- | --- | --- |
| Units `/` | `DashboardLive.mount/3` calls `PayloadLoader.load/1` ([dashboard_live.ex:75-139](../../src/lib/aiur_web/live/dashboard_live.ex#L75-L139)); `PayloadLoader.load_uncached/1` calls `ControlCenterPresenter.state_payload/3`, then `UnitsPresenter.load/2` ([payload_loader.ex:133-152](../../src/lib/aiur_web/operator_control_center/payload_loader.ex#L133-L152)). The LiveView projects its selected filters with `UnitsPresenter.project/2` ([dashboard_live.ex:919-926](../../src/lib/aiur_web/live/dashboard_live.ex#L919-L926)), and observability, membership, and activity events debounce back through `reload_payload/2` ([dashboard_live.ex:163-182](../../src/lib/aiur_web/live/dashboard_live.ex#L163-L182), [785-799](../../src/lib/aiur_web/live/dashboard_live.ex#L785-L799)). | `PayloadLoader.load(:fresh)` followed by `UnitsPresenter.project/2`; both have no socket dependency. A command should inject the same endpoint-configured providers as the loader. | No. `UnitsPresenter.load/2` and `project/2` are data/presentation functions; socket work is only assignment, subscriptions, and debounce. |
| Commands `/decisions` | `handle_params/3` calls `assign_decision_page/3` and `assign_selected_decision/2` ([dashboard_live.ex:143-153](../../src/lib/aiur_web/live/dashboard_live.ex#L143-L153)). Those call `PayloadLoader.decisions/1` / `detail/1`, which delegate to `DecisionProvider.list/2` / `detail/2` ([payload_loader.ex:31-55](../../src/lib/aiur_web/operator_control_center/payload_loader.ex#L31-L55)); the provider reads `DecisionQuery` and attaches `DecisionMetrics` latency ([decision_provider.ex:21-59](../../src/lib/aiur_web/operator_control_center/decision_provider.ex#L21-L59)). Decision PubSub schedules the same payload refresh ([dashboard_live.ex:172-178](../../src/lib/aiur_web/live/dashboard_live.ex#L172-L178)). | `DecisionProvider.list/2`, `detail/2`, and `counts/1`. They already return dashboard-presented rows and health without a socket. | No. Reuse the provider rather than the partial overview in `PayloadLoader` or the REST controller. |
| Build Orders `/build-orders` | `BuildOrderLive.mount/3` initializes `SourceRuntime` with `DataSource`; when connected, `SourceRuntime.connect/1` subscribes and reads the catalog ([build_order_live.ex:39-63](../../src/lib/aiur_web/live/build_order_live.ex#L39-L63), [source_runtime.ex:26-34](../../src/lib/aiur_web/build_order/source_runtime.ex#L26-L34)). Route changes call `SourceRuntime.apply_effects/2` then `assign_model/1` ([build_order_live.ex:67-84](../../src/lib/aiur_web/live/build_order_live.ex#L67-L84)); projection notifications call `accept_projection/2` ([build_order_live.ex:90-97](../../src/lib/aiur_web/live/build_order_live.ex#L90-L97)). `assign_model/1` calls `BuildOrderPresenter.present/3` with the selected graph snapshot plus execution/activity source snapshots ([source_runtime.ex:138-165](../../src/lib/aiur_web/build_order/source_runtime.ex#L138-L165)). `DataSource` exposes the exact graph `catalog/0`, `selected/1`, `demand/1`, and runtime-source reads ([data_source.ex:30-78](../../src/lib/aiur_web/build_order/data_source.ex#L30-L78)). | Catalog: `DataSource.catalog/0`. Selected root: `DataSource.demand/1` (or `selected/1`) + `DataSource.load_sources/0` + `BuildOrderPresenter.present/3`. This preserves the graph projection's own authority, generation, health, and last-known-good semantics. | No extraction for the data contract. `SourceRuntime` is intentionally socket/async orchestration, so a CLI must not reuse it; call the listed data seams directly. The selected page is composite: graph model, optional telemetry and usage panes remain separately sourced. |
| Analytics `/analytics` | `AnalyticsLive.handle_params/3` calls its private `load_model/1` ([analytics_live.ex:48-50](../../src/lib/aiur_web/live/analytics_live.ex#L48-L50)); range changes call it again ([analytics_live.ex:83-85](../../src/lib/aiur_web/live/analytics_live.ex#L83-L85)). `load_model/1` selects current/cross-session scope, range, and configured telemetry file before it calls `Analytics.Presenter.load/1` ([analytics_live.ex:245-285](../../src/lib/aiur_web/live/analytics_live.ex#L245-L285)). The presenter reads the durable telemetry stream and returns either a model or `{:unavailable, reason}` ([analytics/presenter.ex:40-76](../../src/lib/aiur_web/operator_control_center/analytics/presenter.ex#L40-L76)). | Session scope: `Analytics.Presenter.load/1` with the page's `range`, `session`, and configured `telemetry_file`. Build Order scope additionally uses private `analytics_scope/1` and `telemetry_scope_opts/1` to resolve catalog, demand the selected root, and derive `tickets`/`scope_total` ([analytics_live.ex:393-430](../../src/lib/aiur_web/live/analytics_live.ex#L393-L430)). | **Yes, for Build Order scope only.** Extract those two private functions into a small non-LiveView scope resolver in the Analytics ticket, then pass its result to the existing presenter. Session scope is reusable now. The page has no PubSub refresh; it obtains a snapshot when parameters/range change. |

`GraphProjection` is the authority for Build Order planning data, not
`BuildOrderPresenter`; the latter joins that authority with execution/activity
snapshots. Conversely, the command-page provider is already the query and
presentation boundary for Commands. Downstream tickets must retain these
differences instead of forcing them through a generic dashboard facade.

### Separate display-derived state

The Units route is not only its table. Its header also independently reads
current-run summary, current-run outcomes, authorized usage, and provider-meter
data during mount ([dashboard_live.ex:113-116](../../src/lib/aiur_web/live/dashboard_live.ex#L113-L116)). These are supplemental display cards; they are not a second derivation of the Units rows. The protected meter source reads a redacted `ProviderMeterProjection` snapshot through the financial-data facade ([provider_meter_source.ex:1-10](../../src/lib/aiur_web/operator_control_center/provider_meter_source.ex#L1-L10), [35-59](../../src/lib/aiur_web/operator_control_center/provider_meter_source.ex#L35-L59), [82-94](../../src/lib/aiur_web/operator_control_center/provider_meter_source.ex#L82-L94)); the same strip separately reads durable `ModelAvailability` records for a fallback governing window ([run_summary_strip.ex:229-245](../../src/lib/aiur_web/components/operator_control_center/run_summary_strip.ex#L229-L245)). Neither is input to the Units catalog. A Units command that includes those cards must expose their distinct authority and observation states, never merge them into a confident unit value.

Analytics has the same important boundary: its primary model is durable run
telemetry, while the optional Provider spend KPI is separately authorized and
projected from usage aggregation ([analytics_live.ex:341-391](../../src/lib/aiur_web/live/analytics_live.ex#L341-L391)). It must remain a separately marked auxiliary value. Build Order telemetry/usage panes are likewise separate from the graph model in the selected template ([build_order_selected.ex:73-91](../../src/lib/aiur_web/components/operator_control_center/build_order_selected.ex#L73-L91)).

## Page-parity inventory

This inventory is from HEEx/components, not a reconstructed API shape.

### Units

- Filters: condition chips are **active**, **alert**, **paused**, **queued**, and
  **finished** (the policy's `stuck` condition is deliberately excluded); the
  only scope is **unfinished**, and **All**/**None** are bulk selection actions
  ([units_filters.ex:13-71](../../src/lib/aiur_web/components/operator_control_center/units_filters.ex#L13-L71)). The projected table can have a valid zero-result state with a reset action ([units_table.ex:62-65](../../src/lib/aiur_web/components/operator_control_center/units_table.ex#L62-L65)).
- Columns: **ID**; **Unit** (provider, complexity, model, priority); **Ticket**
  (title plus lane or tracker state); **Latest** (evidence, progress, runtime);
  and **Command** (pause/resume, chat, optional remote control)
  ([units_table.ex:67-158](../../src/lib/aiur_web/components/operator_control_center/units_table.ex#L67-L158)). A report command is read-only: it reports command capability/state, not an interactive control.
- States: loading; unavailable table with “No active agents”; known-empty; stale
  last-known catalog; partial/truncated lower-bound counts; and filtered-empty
  ([units_table.ex:25-65](../../src/lib/aiur_web/components/operator_control_center/units_table.ex#L25-L65)).

### Commands

- Visible filter chips are **Open**, **Blocking**, **Resolved**, and **All**,
  with counts; retained-unavailable, partial-prefix, and no-match/Resolved-in-
  history empty states are explicit ([decision_inbox.ex:8-13](../../src/lib/aiur_web/components/operator_control_center/decision_inbox.ex#L8-L13), [39-63](../../src/lib/aiur_web/components/operator_control_center/decision_inbox.ex#L39-L63)).
- Each card shows ticket/id, question, short context, up to two option previews,
  blocking state, age, agent/model provenance, recommendation/selection,
  supervisor confidence, supersession, and lifecycle badge
  ([decision_card.ex:36-103](../../src/lib/aiur_web/components/operator_control_center/decision_card.ex#L36-L103)).
- A selected card adds context (short and markdown), delay consequence, full
  options with risk/benefits/drawbacks, recommendation, and a per-command
  event timeline; no event history is an explicit empty state
  ([decision_detail.ex:35-91](../../src/lib/aiur_web/components/operator_control_center/decision_detail.ex#L35-L91)).
- The page-level **Command history** is separate from selected-card history:
  `ControlCenterPresenter.state_payload/3` reads it independently and places it
  in `payload.history` ([control_center_presenter.ex:13-52](../../src/lib/aiur_web/control_center_presenter.ex#L13-L52)); it renders historical command cards plus audit entries and has unavailable, degraded-prefix, and empty states ([history.ex:13-74](../../src/lib/aiur_web/components/operator_control_center/history.ex#L13-L74)).

### Build Orders

- Catalog columns are **Title**, **Progress**, **Tickets**, **Epics**, and
  **Waves**, with diagnostic rows. It distinguishes loading, unavailable,
  stale last-known-good, structural-invalid, and healthy-empty catalog states
  ([build_order_catalog.ex:23-38](../../src/lib/aiur_web/components/operator_control_center/build_order_catalog.ex#L23-L38), [56-112](../../src/lib/aiur_web/components/operator_control_center/build_order_catalog.ex#L56-L112)).
- Selected root shows graph summary (**Members**, **Dependencies**, **External**,
  **Lanes**, **Waves**), a lane-by-wave dependency graph, phase/epic breakdowns,
  scoped analytics, scoped usage, and diagnostics ([build_order_selected.ex:45-95](../../src/lib/aiur_web/components/operator_control_center/build_order_selected.ex#L45-L95)). Graph cards carry ticket id/title, blocking count, progress when known, complexity, and status; graph grouping is lane columns by wave rows ([build_order_graph.ex:95-175](../../src/lib/aiur_web/components/operator_control_center/build_order_graph.ex#L95-L175)).
- Route and provider states include invalid parameter, awaiting/stale/unavailable
  catalog, not-found, selected graph loading/stale/unavailable/invalid, valid
  empty graph, and stale/invalid model notices
  ([build_order_selected.ex:39-61](../../src/lib/aiur_web/components/operator_control_center/build_order_selected.ex#L39-L61), [105-146](../../src/lib/aiur_web/components/operator_control_center/build_order_selected.ex#L105-L146)).

### Analytics

- Filters/interactions are scope (current session or Build Order query), **Run**
  versus **Full log**, selected unit series, chart zoom, and CPU/peak-CPU/peak-
  memory ranking ([analytics_live.ex:117-128](../../src/lib/aiur_web/live/analytics_live.ex#L117-L128), [161-218](../../src/lib/aiur_web/live/analytics_live.ex#L161-L218)). A snapshot command represents an explicit range and scope; it cannot imply the browser's interactive selection.
- KPIs: peak concurrency, mean utilization, memory headroom, PRs merged,
  tickets done, provider spend, and wasted capacity. Views: ticket lifecycle,
  per-unit CPU, concurrency vs cap, memory, cost per ticket, burn-up, and
  complexity breakdown ([analytics_live.ex:135-239](../../src/lib/aiur_web/live/analytics_live.ex#L135-L239)).
- Empty state is “No run telemetry to analyze yet,” rather than zeroes
  ([analytics_live.ex:111-115](../../src/lib/aiur_web/live/analytics_live.ex#L111-L115)). The presenter deliberately returns unavailable for a readable
  dataset with no scoped telemetry ([analytics/presenter.ex:105-113](../../src/lib/aiur_web/operator_control_center/analytics/presenter.ex#L105-L113)).

## Shared CLI output contract

Choose a **stable CLI schema**, not a raw projection mirror. Raw maps expose
Elixir atoms/struct shapes and make a provider refactor a breaking shell-script
change. The stable schema retains projection facts, health, and field names
needed for page parity while reserving `schema_version` for evolution.

Every `--json` response must be one object:

```json
{
  "schema_version": 1,
  "page": "units",
  "snapshot": {
    "captured_at": "2026-08-08T00:00:00Z"
  },
  "request": {"scope": "unfinished", "conditions": ["active"]},
  "sources": {
    "units_catalog": {
      "state": "available",
      "observed_at": "2026-08-08T00:00:00Z",
      "age_ms": 0,
      "freshness": "current",
      "partial": false,
      "reasons": []
    }
  },
  "data": {"catalog": {}, "view": {}},
  "auxiliary": {}
}
```

- `snapshot.captured_at` is always the CLI invocation time. `sources` is
  required for every independently read section, including primary data; each
  source has `state`, `observed_at`, `age_ms`, `freshness`, `partial`, and
  `reasons`. Unknown upstream time is `null`, `null`, and `"unknown"`. A
  command must never label a terminal snapshot “live.” `state` is one of
  `available`, `empty`, `partial`, `stale`, `unavailable`, or `invalid`; the
  reasons are machine-readable source/validation causes. Build Order selected
  output must at least name `planning_graph`, `execution`, and `activity` as
  separate sources; telemetry and usage are separate sources when requested.
- `request` carries only applied command inputs. Required `data` keys are:
  Units: `catalog` and filtered `view`; Commands: `page`, `selected` (nullable),
  `retained_counts`, and `history`; Build Orders: `catalog` on catalog output,
  or `root`, `graph`, and `runtime` on selected output; Analytics: `model`,
  `scope`, and `range`. `auxiliary` contains optional page cards, never a
  replacement for those required keys. Each value is a JSON-safe mapping of
  the cited page model. Preserve known absence as `null` or a field-level
  status; do not replace it with `0`, `[]`, or `{}` when that would mean
  “measured zero.” An empty collection is only valid with a source whose state
  is `"empty"` or a documented scope whose projection actually observed empty.
- `auxiliary` carries separately-derived UI facts (for example provider meters
  or provider spend) as named subobjects with their own snapshot metadata.
  No page command may merge an auxiliary estimate into the primary value.
- Human output defaults to a concise table on a TTY and labelled plain records
  otherwise. It begins with the capture time and a labelled state/age line for
  each displayed source; it repeats partial, stale, or unavailable warnings
  above that source's values. Wide views degrade by dropping non-identity
  secondary columns first, then print one labelled record per row; they must
  not wrap a table until its columns become ambiguous. Detailed Commands and
  selected Build Orders use summary rows followed by indented detail blocks.
  `--json` is complete and unaffected by terminal width.

## Sequencing

Ship **Commands first**: its `DecisionProvider` already yields the complete
dashboard-facing retained-page contract, including health and latency, and the
page is the clearest way to establish the shared snapshot/unknown conventions.
Units can proceed in parallel after that contract is accepted; its reusable
loader/presenter needs no extraction. Analytics can proceed in parallel for
session scope, but its ticket must first extract the private Build Order scope
resolver before it offers that query; it must also preserve explicit
scope/range and no-telemetry behaviour rather than rendering zero KPIs. Build
Orders should follow or be its own serial lane: its graph needs no extraction,
but selected-root parity necessarily composes GraphProjection,
execution/activity snapshots, and optional scoped telemetry / usage. It is the
most likely consumer of the shared envelope's per-source freshness rules.

No page needs a new shared LiveView abstraction. Each ticket should add a thin
CLI adapter around the seam above, serialize through the shared envelope, and
test its own projection/provider states. The only staging dependency is the
stable output contract in this note; code changes can otherwise proceed in
parallel.
