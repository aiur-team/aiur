# BO-015 — Acceptance Evidence Index

Single entry point for the program-capstone acceptance of the bounded Build
Order feature. It indexes the automated evidence, the Executor-owned manual
proof, and the operator-facing guidance the ticket requires. Source paths are
repo-relative to `src/`.

## What this capstone accepts

The complete bounded Build Order feature, integrated on `develop` with all 53
prerequisite tickets merged, proven by automated suites and by Executor-root
real + synthetic proof, then accepted by closing root #1084 with state reason
`COMPLETED`. This index is documentation and acceptance record only; it adds no
product behavior.

## Companion documents

- [Acceptance matrix](bo-015-acceptance-matrix.md) — every BOREQ-001..015 →
  exact automated or manual evidence, plus the reconfirmed gate state.
- [Executor-root manual proof checklist](bo-015-executor-proof-checklist.md) —
  the prohibited-in-agent-workspace real CLI/TUI/browser proof and root
  closure sequence.
- Existing planning pack (pinned to approved commit `4d8de95`):
  [README](README.md), [implementation pointers](08-implementation-pointers.md),
  [technical decisions](05-technical-decisions.md),
  [requirements](../brainstorms/2026-07-12-build-order-requirements.md),
  [deferred findings](deferred-findings.md).

## Route / interaction / destination / icon guide (Executor-facing)

Where the operator-visible behavior lives, so evidence and troubleshooting can
point at real code:

- **Routes:** `/build-orders` and `/build-orders/:root_number` —
  `lib/aiur_web/router.ex:109-110` → `lib/aiur_web/live/build_order_live.ex`;
  URL/loading/empty/stale/invalid/cyclic state in
  `lib/aiur/build_order/route_state.ex`.
- **Graph interaction:** keyboard/pointer/touch selection, pan/zoom/fit, focus —
  `priv/static/aiur-dom-svg-layout/interaction.js`,
  `interaction-policy.js`, and
  `lib/aiur_web/components/operator_control_center/build_order_graph.ex`.
- **Destinations:** read-only GitHub / Chat / Commands links and non-fetchable
  other-repo diagnostics — rendered through the presenter
  (`lib/aiur_web/build_order_presenter.ex`) and the selected/status components
  (`build_order_selected.ex`, `build_order_status.ex`). Build Order exposes no
  GitHub/Aiur mutation handler.
- **Icons:** derived lane/status icons always carry accessible generic
  fallbacks and use no GitHub icon metadata (see the graph/status components).

## Configured-repository authoring guide (root / member / edges / bounds)

For authoring a valid configured-repository Build Order root:

- **Root identity:** a GitHub issue carrying the `build-order` marker; discovered
  via `lib/aiur/build_order/catalog.ex` (repo/number in URLs, node-ID internal).
- **Members:** direct native sub-issues with strict `complexity:`, `phase:`,
  `build-lane:` labels parsed by `lib/aiur/build_order/metadata.ex`.
- **Native dependencies:** `blockedBy` edges; readiness clears only on
  CLOSED + `COMPLETED` (`lib/aiur/build_order/{edge_state,lifecycle}.ex`).
- **Bounds:** bounded paginated provider with atomic publish, stale-LKG
  preservation, and bound+`1` overflow detection
  (`lib/aiur/build_order/graph_projection.ex`, `github_graph/bounded.ex`).
- **External endpoints:** configured-repository detail rejects other
  repositories before I/O; structured history never parses raw logs.

## Graph / detail / history health, freshness, troubleshooting guide

- **Freshness:** configurable 60 / 15 / 5-second cadences with selection/
  reconnect coalescing; PubSub renders within its bound
  (`graph_projection.ex` + policy/configuration).
- **Health/degraded:** stale LKG, unavailable-provider, unknown-activity, and
  fallback rendering — proven by the `:degraded` / `:invalid` / `:cycle`
  fixtures (`test/support/browser_harness/fixtures.ex`).
- **Detail/history:** bounded description/progress/latest/Logs base context;
  structured history via `ticket_history_provider.ex` /
  `ticket_history_normalizer.ex` (never raw-log parsing).
- **Troubleshooting entry points:** browser failure/timeout evidence specs
  (`browser/tests/{failure-evidence,timeout-evidence,harness-failures}.spec.mjs`)
  and the vendor/packaging checks (`check-vendored-elk.mjs`,
  `check-packaged-layout-worker.mjs`).

## Bounded cleanup record

This capstone is documentation-only (acceptance artifacts); it introduces no
temporary fixtures or compatibility shims of its own, so it removes none.

- Temporary fixtures / compatibility code are owned by their originating
  tickets and are removed there, not here (per the capstone's narrow-integration
  rule).
- No follow-up tickets were created for contained review/integration findings
  (Non-goals). Any contained defect returns to its owning ticket/rework; only a
  genuine independent P0/P1 acceptance blocker may be promoted.
- Systemic non-blockers, if any surface during Executor proof, route to
  [`deferred-findings.md`](deferred-findings.md) and do not change the
  completion condition.

## Terminal condition

The feature is complete only after: implementation, review, current-`develop`
CI, merge under the active policy, documentation, cleanup, post-merge real
CLI/browser proof, synthetic boundary proof, and root #1084 `COMPLETED`
closure. Automated child progress and green CI alone never close the root.
