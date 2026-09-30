# Eight P2/P3 fixes with deleted citations at `main@b4bc11f`

Two independent read-only reviews traced the eight provisional fixes in the
[path-impact CSV](p2p3-b4bc-path-impact.csv) that cite a deleted file. They
checked detached `b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f`; no runtime
test or incident measurement was made. The user-directed GitHub cache page
removal is the baseline. Do not restore it to satisfy an old finding.

| IDs | Current-main disposition | Evidence and next proof |
| --- | --- | --- |
| `github-a-03`, `github-a-21`, `github-a-34` | Specific BudgetMap/CacheInspector behavior removed with the page. | The page and those modules are absent; the route registry test excludes `/github-cache` (`src/test/aiur_web/operator_control_center/route_registry_test.exs:6-13`). Quota logging and actual caller accounting survive (`src/lib/aiur/github/quota.ex:993-999,1052-1055`), so do not infer a broader quota repair. Confirm no surviving call site before marking these three retired on final release main. |
| `tests-2-10` | Survives. | Fixed sleep/refute checks remain in `src/test/aiur/github/agent_cache_bridge_test.exs:42-47,74-82`; `app_token_refresher_test.exs:109-113` and `budget_test.exs:69-122` have further timing negatives. Replace with ordered evidence and mutation-check the intended behavior. |
| `tests-2-13` | Survives. | Global PATH mutation remains in `src/test/aiur/github/config_test.exs:769-793,879-896`; cwd and VM tracing changes remain in workspace, usage-ledger and resource-store tests. Isolate the global effect or serialize it with verified restoration before changing the test owner. |
| `tests-2-37` | Survives. | `src/test/aiur/run_telemetry/lifecycle_test.exs:32` checks only the event-key type; interrupt and budget tests still check identifier or reset types without their required relationships. Assert stable key, matched identifiers and expected reset value. |
| `web-occ-12` | Survives; focus a security behavior test. | `src/lib/aiur_web/operator_control_center/analytics/charts.ex:279,312,419-420,611-615` interpolates labels into SVG text/title; `src/lib/aiur_web/components/operator_control_center/usage_summary.ex:93` renders chart output with `Phoenix.HTML.raw`. Supply hostile model, actor and ticket labels and assert escaped rendered SVG. The deleted cache chart was a safe sibling, not the vulnerable path. |
| `web-rest-16` | Survives with smaller scope. | Dynamic endpoint config remains in `src/lib/aiur_web/live/dashboard_live.ex:2012-2013,2270-2271`, Stream Deck paths, Decision API and router credentials. Recount keys on final main; the removed page's seven seams no longer count. |

Deletion is evidence about one cited path, not a finding-level verdict. These
five surviving findings retain their original provisional `fix` action until
their owner supplies a behavior test and current-main exposure check.
The [focused SVG path audit](analytics-svg-label-b4bc.md) records the strongest
data source, rendering sink and test contract for `web-occ-12`.
