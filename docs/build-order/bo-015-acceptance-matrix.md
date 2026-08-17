# BO-015 — Build Order Acceptance Matrix

Program-capstone acceptance evidence for the bounded Build Order feature. Maps
every requirement `BOREQ-001..015` to exact automated evidence (test files) or
to the Executor-owned manual-proof slot. Paths are repo-relative to `src/`
unless noted.

## Reconfirmed gate state (pickup)

| Gate | Result | Evidence |
|---|---|---|
| Configured integration branch/policy | `develop` | `AIUR_BASE_BRANCH` / `tracker.base_branch`; head at pickup `243c6afb` |
| Integration gate (all 53 prerequisites merged) | MET | 53 member issues CLOSED; only capstone #1102 open |
| Terminal prerequisites CLOSED | MET | BO-006 #1094, BO-014 #1101, BO-020 #1107, DASH-023 #1127, DASH-033 #1137 |
| Root #1084 state | OPEN (correct) | Closes only via `COMPLETED` after post-merge proof |
| Canonical planning validator | 0 errors / 0 warnings | `docs/build-order/scripts/validate_publication.py` against approved commit `4d8de95` |
| External gate GATE-001 (OCC baseline) | RESOLVED | Root #1084 receipt: OCC baseline `9849f32` is an ancestor of `main` → `develop` (monotone) |
| External gate GATE-002 (Executor skill revision) | RESOLVED | Root #1084 receipt: skill revision landed on `main`; `/aiur-build`, `/aiur-run`, `/aiur-monitor` discoverable |

Both external gates are monotone (ancestor / landed-on-main), so they remain
resolved as `develop` advances. The Executor reconfirms no branch/skill drift
at post-merge time per the "later drift is an explicit gate failure" rule.

## Coverage legend

- **AUTO** — clear ExUnit automated coverage (`mix test`).
- **BROWSER** — verified only by the Playwright browser/a11y/perf harness under
  `src/browser/` (not plain `mix test`).
- **MANUAL** — requires Executor-root real CLI/TUI/dashboard proof
  (prohibited from an issue-workspace agent — see the proof checklist).

## Requirement → evidence

| BOREQ | Requirement (short) | Primary source | Automated evidence | Coverage |
|---|---|---|---|---|
| 001 | Discover `build-order` roots; node-ID internal, repo/number in URLs | `lib/aiur/build_order/catalog.ex`, `github_graph/queries.ex`, `root_summary.ex` | `test/aiur/build_order/catalog_test.exs`, `github_graph_test.exs` | AUTO |
| 002 | Direct sub-issue membership; strict complexity/phase/lane parse | `lib/aiur/build_order/metadata.ex`, `member.ex` | `test/aiur/build_order/metadata_test.exs` | AUTO |
| 003 | Native `blockedBy` edge states + precedence; only CLOSED+COMPLETED clears | `lib/aiur/build_order/{edge_state,lifecycle,graph,graph_analysis}.ex` | `lifecycle_test.exs`, `graph_analysis_test.exs`, `dependency_chain_test.exs` | AUTO |
| 004 | Bounded paginated provider; atomic publish, stale LKG, bound+1 detect | `lib/aiur/build_order/graph_projection.ex` (+policy/options/configuration), `github_graph/{pager,bounded,provider_result}.ex` | `graph_projection_test.exs`, `graph_projection_policy_test.exs`, `graph_projection_structural_test.exs`, `graph_projection_pubsub_test.exs`, `graph_projection_recovery_test.exs`, `bounded_test.exs`, `provider_result_test.exs` | AUTO |
| 005 | Repository-qualified tracker identity as trusted join key | `lib/aiur/tracker_identity.ex` | `test/aiur/tracker_identity_test.exs` | AUTO |
| 006 | Daemon StatusReport canonical + separate runtime evidence projection | `lib/aiur/orchestrator/status_report.ex`; `lib/aiur/build_order/{activity,ticket_history_provider,ticket_history_normalizer}.ex` | `status_report_test.exs`, `ticket_history_provider_test.exs`, `ticket_history_normalizer_test.exs` | AUTO |
| 007 | Pure planning/runtime join, no I/O, distinct fields | `lib/aiur_web/{build_order_presenter,build_order_view_model}.ex` | `test/aiur_web/build_order_presenter_test.exs` | AUTO |
| 008 | Real browser/a11y/perf harness + 20/50/100/degraded fixtures | Harness `browser/` (`playwright.config.mjs`, `scripts/run-browser-tests.mjs`, `scripts/start-fixture.mjs`); fixtures `test/support/browser_harness/fixtures.ex`, `test/browser/fixture_server.exs` | `browser/tests/{liveview-smoke,harness-failures,failure-evidence,timeout-evidence}.spec.mjs` | BROWSER |
| 009 | Pinned local layout engine/worker, no CDN | `priv/static/vendor/elk/0.11.1/*`; `browser/scripts/{vendor-elk,check-vendored-elk,check-packaged-layout-worker}.mjs` | `browser/tests/layout-worker.browser.spec.mjs` | BROWSER |
| 010 | Semantic DOM/SVG adapter; off-thread layout, stale-gen discard, fallback | `priv/static/aiur-dom-svg-layout/*`, `browser/layout/aiur-layout-worker.js` | `browser/tests/{dom-svg-layout-adapter,layout-worker}.browser.spec.mjs` | BROWSER |
| 011 | Reusable all-state ticket context; bounded, sanitized, focus-managed | `lib/aiur/build_order/ticket_detail*.ex`, `ticket_detail_coordinator*.ex`, `ticket_history_*.ex`; `lib/aiur_web/build_order/ticket_context_{adapter,presenter,selection}.ex`, `context_runtime.ex` | `ticket_detail_test.exs`, `ticket_detail_coordinator_test.exs`, `ticket_context_{adapter,presenter,selection}_test.exs`, `operator_control_center/{ticket_context,build_order_ticket_context}_test.exs`; browser `ticket-context.browser.spec.mjs` | AUTO |
| 012 | `/build-orders` URL-backed routes; loading/empty/stale/invalid/cyclic states | `lib/aiur_web/live/build_order_live.ex`, `router.ex:109-110`, `build_order/route_state.ex`, `components/operator_control_center/build_order_{graph,catalog,selected,status}.ex` | `test/aiur_web/live/build_order_live_test.exs`, `route_state_test.exs`; browser `build-order-route.browser.spec.mjs` | AUTO |
| 013 | Accessible keyboard/pointer/touch selection; pan/zoom/fit, focus | `priv/static/aiur-dom-svg-layout/{interaction,interaction-policy}.js`; `components/.../build_order_graph.ex` | `browser/tests/build-order-interaction.browser.spec.mjs` | BROWSER |
| 014 | Responsive bounded scale; 320px/200%/20-50-100 members, budgets | `priv/static/aiur-dom-svg-layout/*`, `build_order_graph.ex` | `browser/tests/{build-order-responsive,build-order-performance}.browser.spec.mjs` | BROWSER |
| 015 | Durable bounded acceptance capstone (all layers, real CLI/browser proof) | Cross-cutting — no single owning module | `browser/tests/parity-composition.browser.spec.mjs` + every BOREQ suite above; live-CLI harness `test/support/live_e2e_docker/*` | MANUAL (aggregate) |

## Notes and honest gaps

- **BOREQ-013/014** have **no ExUnit unit coverage** — evidence is
  Playwright-only (`build-order-interaction`, `build-order-responsive`,
  `build-order-performance`). Accepted as BROWSER coverage; the Executor's
  manual keyboard/touch/zoom pass is the human corroboration.
- **BOREQ-009/010** are verified via the browser harness plus the vendor-check
  scripts (`check-vendored-elk.mjs`, `check-packaged-layout-worker.mjs`), not
  ExUnit.
- **BOREQ-015** is the capstone itself — no dedicated module. Its automated
  evidence is the aggregate of all other suites plus
  `parity-composition.browser.spec.mjs`; its user-visible proof is the
  Executor-root manual run and cannot be satisfied by `mix test` alone.
- Usage/accounting modules (`usage_runtime.ex`, `usage_scope.ex`,
  `financial_data_access_test.exs`, `build_order_usage_live_test.exs`, etc.)
  belong to the DASH usage/accounting program, not BOREQ-001..015; they are in
  the 54-member root but out of this requirement axis.

## Outstanding for acceptance (Executor-owned)

No BOREQ lacks a mapped evidence slot. The remaining unfilled cells are the
**MANUAL** rows, which the Executor completes via
[`bo-015-executor-proof-checklist.md`](bo-015-executor-proof-checklist.md).
Root #1084 closes `COMPLETED` only after that post-merge real + synthetic proof
is recorded — never on child-progress or CI alone.
