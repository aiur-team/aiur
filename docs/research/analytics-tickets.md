# Analytics branch — research pack

Synthesized 2026-07-29/30. Canonical context for tickets #1338–#1341 plus
blocker #991. Implementing agents should not need further research.

## Why the Analytics page has never rendered

The page (`/analytics`, `AnalyticsLive`) is fully implemented — six real
pure-SVG charts + six KPI tiles over a durable telemetry stream. It renders
empty because **the entire telemetry subsystem is gated behind `AIUR_DEBUG`,
three layers deep**, all keyed on `LogFile.debug_enabled?()`
(`src/lib/aiur/log_file.ex:151-159`, purely `AIUR_DEBUG ∈ {1,true,yes}`):

1. `src/lib/aiur.ex:35` — `RunTelemetry.start_boot()` (restart marker /
   boot_id) is debug-only.
2. `src/lib/aiur.ex:164` — `if(debug?, do: Aiur.RunTelemetry.Supervisor)` —
   the whole subtree (Writer + Sampler) never starts.
3. `src/lib/aiur/run_telemetry.ex:62,81` — `record/2,3`, `record_batch/2`
   no-op (fail-open by design).

Verified: **zero `telemetry.ndjson` files exist** outside test fixtures.
Telemetry cannot backfill — a run started without the flag is permanently
unrecorded. Hence #1338: `observability.telemetry_enabled` (default true) in
`src/lib/aiur/config/schema/observability.ex`; `--debug` keeps controlling
**richness**, the new setting controls **existence**.

## What exists (don't rebuild)

- **Sampler** (5 s): real `/proc` cpu_percent, rss_bytes, fd_count, disk I/O
  across `_daemon` / `_operator` / per-ticket agent PID trees.
- **Lifecycle**: 13 phase boundaries (dispatch → prewarm → … → pr_merged,
  review_pause, rework_start…). Deliberately no prompt/command/output text.
- **GitHub enricher**: PR/comment events backfilled with `boot_id: nil`.
- **Writer**: append-only versioned NDJSON (`.aiur/telemetry.ndjson`),
  per-boot monotonic sequence, `restart` markers; multi-boot in one file,
  filtered by boot_id at read. **Never rotated** → #1339.
- **Dataset/Timeline/Presenter**: tolerant reducer; `:absolute` and
  `:active` (idle-gap-eliding) timelines; 180-bucket view model.
- Tests: `analytics_live_test.exs`, `analytics_scope_test.exs`, fixtures
  under `test/fixtures/run_telemetry/` (include malformed lines + a
  `future_kind` on purpose).

## Gaps vs the Claude Design (assets/analytics.js, 612 lines D3)

Design's data is entirely synthetic (mulberry32 PRNG over
`window.__aiurFleet`; NOW=107 hardcoded) — it proves layout, not piping.

| Design | Repo | Ticket |
|---|---|---|
| 6 charts + 6 KPIs | ✅ | — |
| Complexity breakdown (7th chart) | ❌ no `complexity` anywhere in telemetry or presenter | #1340 — record tier at dispatch (historically accurate) vs read-time label join; decision must be explicit |
| Brush-to-zoom shared `timeDomain` across 5 time charts | ❌ discrete range toggle only | #1341 — client brush overlay hook pushing `{t0,t1}` on release; zoom must survive LiveView patch (see #1306 class) |

## Blockers and interactions

- **#991** (Writer: sync `File.write` per cast, single GenServer, mailbox
  growth under load) — acceptance said "does not run in non-debug mode",
  which #1338 makes false. Hard blocker on #1338.
- **#1339** retention: prune **whole boots** at `restart` markers (partial
  boots break paired lifecycle intervals); rotate-then-swap or prune before
  Writer start; avoid full-file parse for `session: :current`. Must stay
  compatible with whatever batching #991 lands. Same remedy shape as #1231
  (AlertFeed) — different files, don't merge them.
- Dashboard CSS is compile-time embedded (`@external_resource` in
  `static_assets.ex`) — restart to see changes.
  `dashboard_css_theme_test.exs` forbids new literal `color: #hex`.
- Coverage gate 85% (`src/mix.exs`, `summary.threshold`).

## Run-order note for the Executor

Land #991 → #1338 early and restart the daemon so the build-order run
records **itself**; terminal capstone renders /analytics charts of this very
run. Launch with `--debug` so the pre-#1338 stretch is captured under
today's gate.
