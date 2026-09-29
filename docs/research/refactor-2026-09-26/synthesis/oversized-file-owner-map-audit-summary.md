# Oversized-file owner-map audit synthesis

This is a research audit of the [359-row proposed owner map](oversized-file-owner-map.csv), not an approved decomposition or a measured saving. The three [partition audits](oversized-file-owner-map-audit-part-1.json), [middle audit](oversized-owner-audit-part-2.json), and [final audit](oversized-file-owner-map-audit-part-3.json) cover rows 0–119, 120–238, and 239–358 exactly once. Counts use the [physical-line rule](file-size-analysis.md), including blank lines, comments, and an unterminated final line.

| Source state | Audited rows | Present and still >500 | Missing | Retained files whose line count changed from frozen main |
| --- | ---: | ---: | ---: | ---: |
| Frozen main `3339b887196d5e9aefb273117a14bf33391ee41f` | 359 | 359 | 0 | — |
| Pre-release combined candidate `7bce08f36aede1f9747d24bb3a5c08145abd081e` | 359 | **355** | **4** | **37** |
| Future merged main after the release | Recount required | Unknown | Unknown | Unknown |

The candidate's four absent paths are the GitHub cache dashboard LiveView, its LiveView test, the cache-inspector test, and the page-only budget-map module (rows 41, 47, 332, 350). The partition audits attribute all four to the user-directed dashboard deletion in release PR #2841. They find no oversized-file disappearance attributable to the separate local PR-deletion guard removal. The GitHub cache, cost CLI, quota and credential guards require their own preservation checks; a filename containing `guard` does not make it part of the deleted PR guard. Candidate differences are release changes, not refactor savings. The eventual implementation base is **merged main**, so U0 must recount it independently; the candidate SHA is only a preparation snapshot.

## Owner corrections for U0

The audits flag **19** original owner labels for correction or scenario-level splitting: five in rows 0–119, three in rows 120–238, and eleven in rows 239–358. The middle audit separately has 43 provisional path-based owners that need confirmation; that is an evidence status, not 43 additional corrections.

| Row | Path | Audited owner or required split |
| ---: | --- | --- |
| 12 | `src/test/aiur/core_test.exs` | Split core and integration scenarios by behavior owner. |
| 13 | `src/test/aiur/workspace_and_config_test.exs` | Split workspace and configuration scenarios. |
| 37 | `src/test/aiur/extensions_test.exs` | Assign workflow, tracker, and web extension scenarios to their respective owners. |
| 52 | `src/test/support/test_support.exs` | Shared `Aiur.TestSupport` infrastructure, not a test-scenario owner. |
| 79 | `src/test/aiur/agent_list/renderer_test.exs` | AgentList TUI renderer tests. |
| 120 | `src/test/aiur/dynamic_tool_test.exs` | Codex dynamic-tool tests. |
| 136 | `src/test/manual/executor_control_center_docs_fixture.exs` | Operator control center documentation fixture. |
| 139 | `src/test/aiur/open_ai_compat/coding_agent_test.exs` | OpenAI compatibility coding-agent tests. |
| 240 | `src/lib/aiur/codeowners.ex` | GitHub CODEOWNERS and comment authority; coordinate with U5's single trust owner. |
| 246 | `src/test/aiur/env_test.exs` | Agent environment tests. |
| 270 | `src/lib/aiur.ex` | OTP application startup and supervision; preserve restart and headless contracts. |
| 291 | `src/test/aiur/cli_test.exs` | Aiur CLI tests. |
| 298 | `src/test/aiur/app_server/adapter_test.exs` | Opencode AppServer adapter tests. |
| 304 | `src/test/aiur/usage_ledger/recovery_test.exs` | Usage ledger recovery tests. |
| 310 | `src/test/aiur/usage/price_table_test.exs` | Usage pricing tests. |
| 317 | `src/test/aiur/agent_list/app_test.exs` | AgentList TUI app tests. |
| 339 | `src/test/aiur/open_ticket_source_test.exs` | Open-ticket source tests. |
| 351 | `src/test/aiur/coordination_tasks_test.exs` | Coordination task tests. |
| 356 | `src/test/aiur_web/github_webhook_test.exs` | GitHub webhook HTTP ingress tests, not dashboard presentation. |

## Action hazards and validation order

1. **U0: freeze merged main and settle actions.** Recount every tracked UTF-8 text path, verify each map row against its blob, record release deletions separately, and identify any newly oversized files. Immutable historical plans count while tracked on main; for ten middle-partition plan/brainstorm rows, decide how to split or archive them durably with links. The [file-size contract](file-size-analysis.md) grants no archival, generated, or vendor exemption for tracked files. Confirm the remaining 43 provisional path owners and the 19 corrections above. Record each path's caller, release dependency, source of truth, and behavior check before assigning a worker.
2. **U0: prove safe actions before authorizing removals or regeneration.** Keep npm OIDC trusted publishing in `.github/workflows/release-npm.yml`; its publish job cannot simply move to a reusable workflow. Confirm generator and parse-equivalent output for `src/priv/build_orders/aiur-build-order.json`; preserve live references and decision provenance before touching `docs/build-order/plan-preview.html`. Locate the pinned upstream CE skill source before splitting vendored copies. Check the Build Order demo fixture's documented direct path before deletion. Identify byte-identical CE/Riffrec/publication-receipt copies and their authoritative source before deduplicating. Preserve vendored ELK and layout-worker offline/CSP packaging, the compile-time embedded dashboard CSS, and standalone offline RunTelemetry HTML. Keep enforceable `AGENTS.md` rules discoverable.
3. **U0: install the migration gate.** Count all tracked text with the exact frozen census convention; fail new or enlarged files above 500 while the reviewed owner ledger is retired. Test the 500/501 boundary, 200/201 review prompt, final unterminated line, edited baseline file, binary/symlink classification, and vendor/generated paths. Do not create permanent exemptions or treat the candidate's four release deletions as U8 output.
4. **U8: parallelize only disjoint ownership.** Doc, skill, test, generated and vendor assignments can start after U0 where the owner and safe action are settled. Component-owned code waits for its U1–U7 contract changes, especially GitHub CODEOWNERS/trust, DecisionProjection and Orchestrator State semantics, and `Aiur.Application` startup order. Preserve caller and release behavior while removing the old oversized owner; test actual behavior rather than a line-slice extraction. Unknown historical-doc, vendor-source or publishing constraints stay explicit blockers for the affected rows.
5. **U8/U9: close the universal gate and measure actual outcome.** Require zero tracked UTF-8 text files above 500, with 500 passing and 501 failing; verify generated/offline artifacts, package/release startup, browser and real CLI/TUI paths where affected. Recount net tracked physical lines on the final merged implementation base by source, tests, docs and generated assets, excluding moved lines from any saving claim. The 37 candidate count changes and any gross candidate line delta are not net savings.

The middle audit records 98 conditional and 21 unresolved action assessments; the latter comprise eleven historical-document archival/splitting decisions, eight pinned CE-source/regeneration decisions, one generated Build Order fixture, and one referenced preview. These are gates for the specific rows, not reasons to infer that the other proposed splits are approved.
