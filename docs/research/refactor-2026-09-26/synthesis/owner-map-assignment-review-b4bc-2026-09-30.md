# Oversized-file assignment review at `main@b4bc11f`

Two independent read-only reviewers checked high-risk rows in the frozen
359-row [owner map](oversized-file-owner-map.csv) against detached
`b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f`. These are corrections for
the final-release-main U0 assignment pass, not approved removals. The frozen
CSV still carries its original `main_lines` and `main_change=unchanged` fields;
the [b4bc delta](owner-map-b4bc-delta.csv) is a separate overlay. Do not treat
the frozen fields as a current-main census.

| Paths | Assignment or prerequisite on the implementation base |
| --- | --- |
| `docs/build-order/build-order.json` | The approved baseline also serves as a publication receipt (`docs/build-order/README.md:144-147`, `scripts/publication_receipt_authority.py:354-375`). Move its authority and validator contract before replacing the monolith; regeneration alone is not enough. |
| Pinned ELK engine and authored worker copy | The engine is an offline, hash-checked release asset (`docs/vendor/elkjs-0.11.1.md`, `src/lib/aiur_web/static_assets.ex:11-33`). The worker copy is generated from `src/browser/layout/aiur-layout-worker.js` by `src/browser/scripts/vendor-elk.mjs:31-62`; give source and copy one browser-layout owner. Removal requires packaged offline/CSP parity. |
| `src/priv/github_quota_guard.sh`, `src/priv/github_budget.py` and related client/store/tests | Coordinate one GitHub access and guard boundary rather than assigning the scripts to generic launcher work. `github/budget.ex:18,147` loads the Python broker at runtime. |
| Shared CLI engine | `packaging/npm/aiur-cli/libexec/aiur-engine.sh` serves both installed `aiur` and `scripts/aiurdev` (AGENTS.md); owner and tests must cover both entry points. |
| npm lockfiles | Treat as generated dependency records tied to package manifests and `npm ci`; an unspecified compact replacement could change resolution. The universal 500-line target still needs a concrete, reproducible treatment for these files or a deliberate revision of that target; no silent exclusion. |
| `src/test/browser/fixture_server.exs`, `src/test/support/test_support.exs` | The former is an executable browser harness launched by `src/browser/scripts/start-fixture.mjs:9-13`; the latter holds shared cross-domain test setup. Assign harness and shared-test owners, not a generic test-scenario split. |
| Four deleted GitHub cache paths | Deleted at b4bc. Record as release deletions, not refactor savings or active split work. |
| `src/priv/build_orders/croptracker-demo.json` | Its README calls it deletable demo data and names the companion `AIUR_BUILD_ORDER_DEMO` config block (`src/priv/build_orders/README.md:42-48`). Validate users/docs before removing both. Keep the distinct permanent `aiur-build-order.json` pack. |
| Build Order prototype HTML | Their exact bytes and separate roles are pinned in `docs/build-order/design-manifest.md:5-10,31-36`; the README expects directly openable offline HTML. Generic removal conflicts with that evidence contract. Decide a durable replacement or revise the design authority before U8 acts. |

The new 508-line `src/test/aiur/orchestrator/status_report_test.exs` and
513-line `src/test/aiur_web/components/operator_control_center/units_table_test.exs`
are listed in the b4bc delta but not the frozen map. Add them to the refreshed
active owner map after the release-main recount. The original reviewers also
found `workspace_and_config_test.exs` crosses workspace, config,
Linear and orchestrator tests; split assignments by behavior owner.
