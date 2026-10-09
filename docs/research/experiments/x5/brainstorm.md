---
title: Experiments page (X5) - Plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
execution: code
date: 2026-10-09
epic: aiur-team/aiur#3774
area: X5 page
origin: docs/research/experiments/requirements.md
---

# Experiments page (X5) - Plan

## Goal Capsule

- **Objective.** Give the operator one standalone page that shows every experiment at a glance and, for the selected one, its charts and its written report. A reader must be able to tell how strong the evidence is without trusting a verdict word.
- **Product authority.** Kevin's brainstorm of 2026-10-09 (epic #3774, `docs/research/experiments/requirements.md`). The MP-E8 Claude Design (`docs/research/aiur-mobile-and-platform/bucket-2-platform/MP-E8/claude-design-source-of-truth.md`) is the visual authority for everything it covers. MP-R1 (`bucket-1-refactor/MP-R1/component-map.md`) is the authority for component boundaries.
- **Open blockers.** None for planning. Build waits on the X2 facade (spec + store) and the X4 result shape it exposes. Kevin's sign-off is needed on two visual items that the Claude Design does not cover (see "Open questions for Kevin").

This is an unattended brainstorm. The product decisions in the brief are settled and are carried forward, not re-asked. I made the in-area decisions below myself and give the reason for each.

---

## Product Contract

### Problem

Today aiur has no place to see whether a feature or a release changed delivery. `/analytics` shows one run's live utilization from the run-telemetry stream. It has no notion of a line, a cohort, a frozen baseline or a sample guard. Without a page, the experiments built in X1-X4 and the analyst reports from X6 can only be read as files.

### Actors

- **A1 Operator** (Kevin, or a consumer-repo operator). Skims the index, opens one experiment, reads the evidence and the report. Uses the page on desktop and on a phone.
- **A2 Experiment analyst agent (X6).** Does not use the page. Its report and labels are rendered on the page.
- **A3 Consumer-repo operator.** Uses aiur on another repository, with their own metric packs. The page must show their metrics without any aiur-specific wording.

### Carrying forward (session-settled, from the brief)

- **KD1** Standalone page: index of experiments in a left-side tab list; selecting one shows its charts and its written report. *(session-settled: user-directed, chosen over a single long report page)*
- **KD2** Both kinds: before/after line and A/B cohorts. The page is agnostic to the kind. *(session-settled: user-directed)*
- **KD3** Verdict rigor: medians, spread and sample counts are always visible; "not enough data" below the minimum count; no bare verdict word on the page. *(session-settled: user-directed)*
- **KD4** Generic: metric names, units and directions come from the spec and its metric pack. Nothing on the page names an aiur-only metric. *(session-settled: user-directed)*
- **KD5** Standalone, modular component that fits the MP-R1 map; the page reads only the X2 facade. *(session-settled: user-directed)*
- **KD6** Desktop and mobile (390 px) layouts, consistent with the MP-E8 Claude Design and the shell nav. *(brief)*

### Decisions made in this brainstorm

**D1. Own page at `/experiments`, not an `/analytics` sub-route.** The nav item sits directly below Analytics.
Reasons:
1. Kevin asked for a standalone page. A sub-route would make Experiments a mode of Analytics.
2. The data is different. Analytics reads one run's telemetry stream (`AnalyticsLive` derives everything from `Aiur.RunTelemetry`). Experiments read frozen baselines and computed results that span releases and many boots.
3. MP-R1 isolation. A sub-route would be owned by the analytics part of `dashboard-ui` and would pull experiment data into it. An own page lets the experiments components register their own route module (RC-39: "each component owns its `AiurWeb.Routes.*` module") and be absent from consumer installs that turn the component off.
4. Layout. The index-plus-detail layout does not fit the full-width card grid that `/analytics` uses.
5. The URL is shareable: `/experiments/:id` opens one experiment directly, the same as `/build-orders/:root_number`.

Rejected: `/analytics/experiments` (coupling, reasons 2-4); an Analytics tab (it hides experiments behind run telemetry and breaks the shareable URL).
Placement below Analytics keeps the two measurement pages next to each other. This is a change to the nav that the Claude Design does not have, so it needs Kevin's sign-off (Q1).

**D2. The index is a vertical list of links, styled as left-side tabs.** Each item is a link to `/experiments/:id` with `aria-current="page"` when selected. This gives real URLs, back-button behaviour and LiveView patch navigation. A `role="tablist"` would give none of these.

**D3. Index item content (skimmable in one line plus one row of facts):**
- name;
- kind chip: `Before/after` or `A/B` (for N cohorts: `A/B/C` up to 4, then `N cohorts`);
- status chip, taken from X2's status (for example collecting, ready, reported, archived);
- up to 3 headline metrics. Each shows the label, the signed median change in percent, a direction glyph that says whether the change is in the expected direction (glyph plus text, never colour alone), and the sample-guard state (`n 7/10` with a "not enough data" chip when below the minimum);
- analyst labels from X6, such as `underpowered` or `confounded`, as small chips.
Ordering: active experiments (collecting) first, newest first, then the rest, newest first.
No verdict word ("win", "better", "regressed") appears anywhere. A delta is always shown with its sample size.

**D4. The detail view has one fixed order:**
1. Header: name, kind, status, the line (label and time) or the cohort definitions, the windows, the frozen-baseline time, min samples, hypothesis and expected direction per metric.
2. Metric summary ("forest" chart and table): one row per metric with before/after (or per-cohort) median, IQR, n, the median difference with its bootstrap CI, p-value and test name, effect size, and the guard state. This is the per-metric median + CI view.
3. Distribution comparison for the selected metric: before vs after, or cohort vs cohort, as box (IQR) plus whiskers plus every sample as a dot. One component serves both kinds.
4. Time series for the selected metric: each sample at its time, a rolling median, the line drawn as a vertical rule, before/after windows shaded, and X6 confounder annotations as markers. For cohort experiments, there is no line; points are coloured by cohort and also differ in shape.
5. Power: per metric, samples now vs samples needed for the minimum detectable effect at the spec's power, as a meter with text ("needs 6 more after the line").
6. The analyst report, rendered from X6's Markdown.
A metric selector (segmented control, the `an-seg` pattern) picks the metric for charts 3 and 4. The selection is in the URL (`?metric=`).

**D5. The page never computes statistics.** All numbers (medians, IQR, CI, p-values, effect sizes, power, samples needed, guard state) come from X2's facade, which carries X4's results. The page only lays them out. This keeps the stats engine testable in one place and keeps the page a thin view.

**D6. Mobile (at or below the shell's mobile breakpoint, tested at 390 px) is list-then-detail.** `/experiments` shows the index full width. Selecting an item opens `/experiments/:id` full width with a "All experiments" back link at the top. Charts stack in the same order as desktop. The summary table becomes one card per metric. Long tables and the time series scroll inside their own container; the document never scrolls sideways. Rejected: a horizontal tab strip (names and metric deltas do not fit at 390 px).
On desktop, `/experiments` with no id selects the first experiment in index order.

**D7. Empty and partial states are first-class:**
- **No experiments.** Explains what creates experiments (a version bump or release, a tagged feature epic merge, or the analyst on request) and shows the command to start one (named by X2/X6).
- **Capture off.** When `observability.telemetry_enabled` is false, a banner says that new samples are not being captured, so results will not grow. Existing experiments still render.
- **Not enough data.** Charts draw the samples that exist. The CI, p-value and effect size cells show "not enough data (n 3 of 10)" in place of numbers. The power meter shows how many samples are still needed. No interval is drawn for a group below the minimum.
- **Report pending.** "The analyst has not written a report for this experiment yet." When the report is older than the latest results, a "results changed since this report" note is shown with both times.
- **Unknown id.** A not-found message inside the shell with a link to the index.
- **Store unreadable.** An error state that names the store path class (not the absolute path), the same style as the analytics `an-empty` states.
- **Component off.** When the experiments capability is not available, the nav item is not rendered and `/experiments` shows an "Experiments are not enabled" state.

**D8. Live update without churn.** The page subscribes to the facade's change notification. It reloads the index and the open experiment only when X2 reports a change, not on a timer.

**D9. Visual language comes from MP-E8 primitives.** The Claude Design has no Experiments page. The page is built from the design's existing pieces, with their exact CSS values: shell, page head, `an-card`, `an-kpi`, `an-seg`, chips, the `sev-rail` left edge for the selected index item, and the analytics series palette. Charts are server-rendered inline SVG, the same as `/analytics` (no client chart library). Light and dark themes and both palettes are supported.

**D10. Accessibility.** Every chart has `role="img"`, a text summary in `aria-label`, and a "Show data" disclosure with the same numbers as a table. State is never shown by colour alone. Touch targets are at least 44 px on coarse pointers. Motion respects `prefers-reduced-motion` (there is little motion: only the selection transition).

### Requirements

- **R1** `/experiments` and `/experiments/:id` render inside the dashboard shell, with a nav item below Analytics.
- **R2** The index shows every experiment from the facade with the D3 content and ordering.
- **R3** The detail view shows the D4 sections in order, for both kinds, for any metric pack.
- **R4** Every number shown comes from the facade; the page has no statistics code (D5).
- **R5** All D7 states render with the documented copy.
- **R6** Desktop (1440, 1024) and mobile (390) layouts per D6, with no document-level horizontal scroll.
- **R7** The page code is its own MP-R1 component that references only the X2 facade for data, and the dependency check proves it.
- **R8** Browser specs and visual baselines cover both themes, desktop and mobile, and the empty and not-enough-data states.

### Acceptance examples

- **AE1** A before/after experiment with 12 before and 4 after samples, min 10: the index shows `n 4/10` and a "not enough data" chip for each headline metric; the detail draws 16 dots, no after-window CI, and the power meter reads "needs 6 more after the line".
- **AE2** A Claude-vs-Codex cohort experiment: kind chip reads `A/B`; the distribution chart has one box per cohort; the time series has no line rule; cohorts differ in colour and marker shape.
- **AE3** A consumer repo with a custom metric pack (`checkout_latency_ms`, lower is better): labels, units and direction glyphs come from the pack; no aiur metric name appears.
- **AE4** No experiments exist: the page shows the empty state with how experiments are created, and no chart frames.
- **AE5** At 390 px, opening an experiment from the index shows the detail with a back link, and the document width equals the viewport width.

### Scope boundaries

- Not in X5: creating, editing or deleting experiments from the page (X2 CLI and X6 own that); computing statistics (X4); writing reports (X6); capture (X1); automatic lines (X3).
- Not in X5: a cross-link from `/analytics` to `/experiments`. Deferred, because it changes the analytics baselines for little value while the nav item is one row away.
- Not in X5: export (CSV/PNG) of charts.

### Dependencies on other areas (assumed interface)

The page assumes this read facade from X2. Names are proposals; X2 owns the final names. The plan files repeat it.

- `Aiur.Experiments.list/1` returns `{:ok, [summary]}` or `{:error, reason}`. A summary has id, title, kind (`:line` or `:cohorts`), status, created_at, line or cohorts, up to 3 headline metric results, and analyst labels.
- `Aiur.Experiments.fetch/1` returns `{:ok, detail}`, `{:error, :not_found}` or `{:error, reason}`. A detail has the spec (hypothesis, metrics with label, unit and expected direction, windows, min samples, line or cohorts, strata), the baseline frozen_at, per-metric results (per group: n, median, IQR, samples with time, ticket and stratum; effect: difference, percent, CI, p-value, test name, effect size; power: samples needed, MDE, power; guard state), confounder annotations, and the report (Markdown, written_at, results_at).
- `Aiur.Experiments.status/0` returns capture on/off and store health.
- `Aiur.Experiments.subscribe/0` delivers `{:experiments_changed, id | :all}`.
- X4 results reach the page only through these calls.

### Open questions for Kevin

- **Q1** The Claude Design has no Experiments page or nav item. Build from MP-E8 primitives now and you approve screenshots, or commission a Claude Design first? *Recommendation:* build from primitives; record the new nav item as a pending-sign-off parity exception; re-skin later if you design it.
- **Q2** Nav position: directly below Analytics (shifts Streamdeck down one row in every parity cell) or last (no shift)? *Recommendation:* below Analytics, so the two measurement pages sit together.

### Ticket plans

| Ticket | Plan | Depends on |
|---|---|---|
| EXP-X5-1 page route, index and detail shell | [plan-page-shell.md](plan-page-shell.md) | X2 facade |
| EXP-X5-2 charts | [plan-charts.md](plan-charts.md) | EXP-X5-1, X2 detail fields (samples, CI, power), X4 results |
| EXP-X5-3 analyst report | [plan-report.md](plan-report.md) | EXP-X5-1 (U2 only), X6 report via X2 |
| EXP-X5-4 visual baselines | [plan-visual-baselines.md](plan-visual-baselines.md) | EXP-X5-1..3, Kevin sign-off (Q1) |
