# Research promotion and the universal 500-line gate

## Reproduced census

Against public `main` at `3339b887`, I compared added tracked paths by Git tree, decoded UTF-8 blobs and counted physical lines (including a final unterminated line). The counts move as independent research artifacts are integrated; they are **snapshot counts**, not three competing frozen totals.

| Research snapshot | Added tracked UTF-8 paths above 500 | Their gross physical lines |
| --- | ---: | ---: |
| Canonical research `4c00a16cf` | 60 | 270,346 |
| Staging `adfd9589c` after later triage/audit integration | 62 | 277,033 |
| Staging `8d5a335db` after another owner audit | 63 | 279,578 |

All oversized added paths in these snapshots are under `docs/research/refactor-2026-09-26/`. The largest, `review/in-progress/duplication-name-triage.json`, is **115,383 physical lines**. These are *gross evidence size*, not removable product code or net refactor savings. The one-line `review/findings.json` is already about 3.42 MB and contains 986 findings; its physical-line count does not make it a suitable main-branch substitute for the raw evidence. Do not reformat or minify evidence to satisfy the gate.

## Recommendation

Keep the complete raw reports, reviewer verdicts, source-ID mapping, feature inventory, owner maps and reproduction tooling on a **public, durable research ref**. Part-1 P2/P3 triage and identified cross-partition threshold reconciliation are now present. Pin the final evidence tree with an immutable commit SHA and preferably a protected/tagged ref. Keep the checked-in audit scripts with the evidence so another reviewer can reproduce source-ID coverage, effective dispositions, counts and privacy checks from that exact checkout. On canonical `4c00a16cf`, `python3 tooling/audit_review_synthesis.py <research-root>` reproduces 1,033 source IDs mapped to 986 canonical findings, and `python3 tooling/research_inventory.py <research-root>` reports both lenses present for all 60 research claims (artifact coverage only). These scripts require the research tree as an intact checkout; a short main summary cannot replace it. Do not delete raw evidence after extracting conclusions.

Promote a concise requirements/plan package to main: the 38-line [requirements](../../../../docs/brainstorms/2026-09-29-aiur-refactor-requirements.md), the 205-line [plan](../../../../docs/plans/2026-09-29-001-refactor-production-readiness-plan.md), and a short index that names the pinned research SHA, snapshot date, source commit and unresolved decisions. Neither the oversized raw tree nor `CONTINUATION.md` is required on main to execute a plan if the evidence ref remains fetchable. A future gate implementation may need a **fresh merged-main debt baseline**; generate that directly from tracked main blobs and keep it as an ordinary one-row-per-path ledger with explicit owners, rather than copying the stale frozen census or minifying a large JSON artifact. No raw evidence artifact has a demonstrated must-merge dependency today.

The plan mentions `docs/research/refactor-2026-09-26/` **24 times across 16 unique paths**; the requirements mention it **eight times across eight unique paths**. Those paths are inline code references, not resolvable links once the research tree is absent from main. Before promotion, replace evidence references with commit-pinned public links, and state how workers fetch the pinned research worktree for local audit commands. Use the final reconciled SHA, not `4c00a16cf` or the moving staging branch. Keep source IDs stable across the short main summary and research branch so each conclusion can be traced back to its raw claim and reviewer verdict.

This preserves the proposed universal gate's scope: it must count tracked docs, tests, generated and vendored text as well as product source. Main promotion should wait for the final evidence snapshot and link check; the research branch can continue to hold the full unminified record without being mistaken for implementation-ready code or measured line savings.
