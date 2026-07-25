# Split analytics: live-session view vs build-order-scoped long-run pane

Issue: [#1304](https://github.com/its-everdred/aiur/issues/1304) · complexity:4 · base `develop`

## Problem

`/analytics` (`AnalyticsLive` → `Analytics.Presenter` → `Analytics.Charts`) renders one
scope: whatever is in the durable telemetry stream, windowed to the bounding box of all
ticket lifecycle activity. Two things are wrong with that as the only surface:

1. It is not actually session-scoped. `telemetry.ndjson` is append-only and is **never**
   rotated or truncated (`LogFile` only removes legacy `disk_log` wrap artifacts), so the
   stream already accumulates across every daemon boot. The "live run" page silently
   mixes sessions.
2. There is no way to see a **Build Order's** cost/throughput across its whole life. A
   Build Order runs over many sessions; the per-session view can't answer "what did this
   whole build cost, and how is it burning down".

## Design decisions

These are the issue's open questions, answered from the code rather than deferred.

### DEC-1 — A Build Order is identified by its current member set

Membership authority is the same one `UsageScope` already uses: the selected root's
`SelectedRoot.members`, each carrying a `TrackerIdentity`. Telemetry rows are keyed by a
bare ticket-number string (`Lifecycle` extracts it from `ticket.<n>.pr.merged`; the
sampler writes actor `"ticket:<n>"`), so the join key is
`TrackerIdentity.identifier` → telemetry `ticket`.

Consequence worth stating: the telemetry stream is **not** repository-qualified, while
member identities are. Aiur is configured against a single repository, so the join is
sound today, but the scope module will only accept identities whose repository matches
the configured one and will count anything else as rejected — the same failure shape
`Scope.explicit_ticket_set/1` already produces. No new "session ↔ build order" mapping is
invented; membership is derived live from the graph projection, so a ticket that joins the
Build Order later retroactively contributes its earlier telemetry, exactly like `this
build` usage.

### DEC-2 — No new persistence. The existing stream is already cross-session

`Dataset.build/2` already reduces records from every `boot_id` in the file into one
model, and every record carries `boot_id`. So:

- **Cross-session aggregation** = read the whole stream, filter to member tickets. No new
  store, no aggregation job, no schema change, no migration.
- **A session** = one `boot_id`.

This is the single highest-leverage finding: the "durable, build-order-keyed store" the
issue worried about is unnecessary.

### DEC-3 — `/analytics` becomes explicitly current-session

Add a `:session` option to the presenter. `:current` filters records to one `boot_id`:
`Aiur.Boot.run_id()` when that boot has records in the stream, otherwise the latest
`boot_id` present. The fallback matters — a dashboard reading a stream written by a prior
boot must not render an empty page, and "latest boot in the stream" is the live session by
construction whenever the daemon is writing. The page names the scope in the UI so the
two surfaces are unmistakable.

### DEC-4 — Charts are shared; presenters are not

The issue asks for a "duplicate set" of components but explicitly asks to confirm this.
**Recommendation: share `Charts`, add a second presenter.** `Charts` is 315 lines of pure
`model → SVG` with no session assumptions; a literal copy would drift within a release and
double every future fix. The scope difference lives entirely in how the model is built,
which is what a second presenter is for. The Build Order pane is still a visually distinct
pane with its own KPI strip and its own card copy — the user-visible "duplicate set of
components" is delivered; only the SVG builders are shared.

### DEC-5 — Aggregate over *active* time, not calendar time

This is the decision that makes the pane honest. A Build Order spans weeks of wall clock
with long idle gaps. Naively stretching the existing window over that span breaks three
things: CPU/memory series average to noise across ~hours-wide buckets, and
`wasted_slot_hours` counts every night and weekend as idle capacity — a number that would
be off by an order of magnitude and would be read as real.

So the build-order model is built on a **compressed timeline**: contiguous spans of
telemetry activity are detected (a gap longer than a threshold splits a span), idle gaps
are elided, and every timestamp in the model — bucket centres, ticket lifecycle rows,
merge points — is projected into elapsed-active-time coordinates.

`Charts.x_axis/6` already labels ticks as `fmt_elapsed(t - t0)`, so a compressed axis
reads "0m / 4h / 8h …" of active build time with **no change to `Charts` at all**. Every
existing chart stays meaningful, and `wasted_slot_hours` becomes a defensible number
(idle *slots during active sessions*, not idle wall clock).

The live-session presenter uses an identity projection, so its behaviour is unchanged.

### DEC-6 — Which KPIs change

The build-order KPI strip drops the "now"-flavoured facts (`conc_now`, memory headroom
right now) which are meaningless once a session has ended, and adds cross-session ones:
sessions observed, total active time, cumulative CPU-hours. `peak_conc`, cumulative
`wasted_slot_hours`, and members-merged-of-total carry over and are the interesting
long-run numbers. Burn-up is computed against **Build Order membership** (all members,
including ones with no telemetry yet) rather than against tickets that happen to appear in
the stream — otherwise a build shows 100% complete before it starts.

## Implementation units

### U1 — `Aiur.RunTelemetry.Timeline` (new, pure)

`lib/aiur/run_telemetry/timeline.ex`

- `active_spans(timestamps_ms, opts)` → `[{start_ms, end_ms}]`, merging points closer than
  `:max_idle_gap_ms` (default 15 min) and dropping empty spans.
- `compress(spans)` → a projection struct `%{spans: [...], total_ms: n}`.
- `project(timeline, ms)` → elapsed-active ms, clamped into the nearest span so a
  lifecycle point landing inside an idle gap still renders at the gap boundary rather
  than vanishing.
- `identity(t0, t1)` → a single-span timeline, so the live presenter uses one code path.

Tests: `test/aiur/run_telemetry/timeline_test.exs` — span merging at/around the threshold,
projection monotonicity, points inside gaps clamping to the boundary, empty input.

### U2 — Scope-aware dataset filtering

`lib/aiur/run_telemetry/dataset.ex` (additive)

- `Dataset.filter(dataset, opts)` where opts accept `:boot_id` and `:tickets` (a
  `MapSet` of ticket-number strings). Filters `actors` (keeping `_daemon`/`_operator`
  baseline actors and member `ticket:<n>` actors, and dropping non-matching samples by
  `boot_id`), `tickets`, and `records`, and recomputes `provenance.time_range`.

Filtering the already-reduced dataset — rather than re-reading the file per scope — keeps
one parse path and one profile computation. Per-actor `profile` statistics are recomputed
from the surviving samples so `cpu_seconds`/`peak_*` are scope-correct.

Tests extend `test/aiur/run_telemetry/dataset_test.exs`: boot filtering, ticket filtering,
baseline actor retention, profile recomputation.

### U3 — Presenter scope options

`lib/aiur_web/operator_control_center/analytics/presenter.ex`

- `model/2` gains `:timeline` (default identity) and threads every emitted timestamp
  (`series[].t_ms`, `window`, `tickets[].{start_ms,work_ms,end_ms,merged_at}`) through it.
  Bucket width becomes `total_active_ms / buckets`.
- `load/1` gains `:session` (`:current` | `:all`) and `:tickets`, applying `Dataset.filter/2`
  before `model/2`.
- KPI computation gains a `:scope` so the strip can carry `sessions` and `active_ms`, and
  so `total`/`done` can be driven by an explicit member count when one is supplied.

`AnalyticsLive` passes `session: :current`; the existing `:run`/`:full` range control is
unchanged.

### U4 — `AiurWeb.BuildOrder.AnalyticsScope` (new, pure)

`lib/aiur_web/build_order/analytics_scope.ex`, modelled directly on `UsageScope`:
same `decide/1` decision vocabulary (`:none | :pending | {:invalid, s} | {:unavailable, r}
| :empty_build | {:unscopable, n} | {:ready, ticket_set, key, health}`) so the pane's
degraded states match the rest of the Build Order page. The membership key is the sorted
member number set plus the authority epoch.

Tests: `test/aiur_web/build_order/analytics_scope_test.exs`, mirroring `usage_scope_test.exs`.

### U5 — `AiurWeb.BuildOrder.AnalyticsRuntime` (new)

`lib/aiur_web/build_order/analytics_runtime.ex`. Same shape as `UsageRuntime` minus the
protected-financial-data gate (telemetry is not gated): `initialize/1`, `sync_scope/1`,
debounced reload, reset-on-root-switch, and `handle_async` for the load so a multi-MB
NDJSON parse never blocks the render path. **The parse must be async** — this is the one
place where copying `UsageRuntime`'s synchronous fetch would be a real regression.

### U6 — `AiurWeb.OperatorControlCenter.BuildOrderAnalytics` pane

`lib/aiur_web/components/operator_control_center/build_order_analytics.ex`. Rendered from
`build_order_selected.ex` immediately after `BuildOrderBreakdown` (the "Waves & Epics"
section), carrying its own heading, its own KPI strip, and the shared `Charts` output. It
reuses the `an-*` CSS by moving the analytics page CSS into a shared helper so both
surfaces stay in one stylesheet rather than two copies.

### U7 — Scope labelling on both surfaces

`/analytics` gets an explicit "Live session" scope label naming the session; the pane gets
"This Build Order · N sessions". Both link to each other so the distinction is discoverable.

## Test scenarios

| # | Scenario | Expectation |
|---|---|---|
| T1 | Two boots in one stream, `session: :current` | Only the latest boot's actors/tickets in the model |
| T2 | `session: :current` when `Boot.run_id/0` is absent from the stream | Falls back to the latest boot; model is non-empty |
| T3 | Member filter with a non-member ticket active | Non-member excluded from series, cost rows, and burn-up scope |
| T4 | Two sessions separated by a 3-day gap | `window.end_ms` ≈ summed active time, not 3 days |
| T5 | Same, `wasted_slot_hours` | Bounded by `cap × active hours`, not `cap × calendar hours` |
| T6 | Ticket merged during session 2 | Burn-up step lands inside session 2's compressed region |
| T7 | Build Order member with no telemetry | Counted in burn-up scope total, absent from cost rows |
| T8 | Root switch mid-load | Prior root's model never renders under the new URL |
| T9 | `:no_telemetry` | Pane renders the empty state, not a crash or zeroed KPIs |
| T10 | Live `/analytics` regression | Existing presenter/live tests pass unchanged |

## Risks

- **Parse cost.** The whole NDJSON is re-read per pane load. Mitigated by U5's async load
  plus the existing debounce; if the stream grows past comfort a later ticket can add a
  reduced-dataset cache. Flagged, not pre-optimised.
- **Daemon/executor baseline attribution.** When two Build Orders run in one session, the
  shared daemon CPU is attributed to both panes. Charted as "orchestration overhead during
  active spans" and labelled as shared rather than silently summed into per-build cost.
- **Cap semantics.** `wasted_slot_hours` for a Build Order measures capacity not spent on
  *that build*, which is the interesting number but is not the same as global idle. The
  KPI copy says so.
- **`fmt_elapsed` above ~99h** renders large hour counts; acceptable, but worth a glance
  during review.

## Out of scope (noted, not fixed)

`AiurWeb.OperatorControlCenter.BuildOrderUsage` exists but is not rendered from any
template — pre-existing dead wiring, unrelated to this change.
