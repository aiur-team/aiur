# Aiur refactor research index

The [requirements](brainstorms/2026-09-29-aiur-refactor-requirements.md) and [production-readiness plan](plans/2026-09-29-001-refactor-production-readiness-plan.md) describe a staged reduction in Aiur's complexity. The plan remains **requirements-only**: source analysis and ownership assignments direct focused work, while behavior, caller and implementation-head checks still gate changes to each boundary.

## Evidence and release baseline

- The [research corpus](research/refactor-2026-09-26/README.md) preserves 32 review units, 1,033 source IDs reconciled to 986 canonical findings, two independent static verdicts for all 182 inherited P0/P1 source findings, and a 216-feature inventory. The [P2/P3 reconciliation](research/refactor-2026-09-26/synthesis/p2p3-triage-reconciliation-overlay.md) covers all 889 lower-priority findings with 244 provisional fixes and 645 deferrals.
- The [97 canonical P0/P1 action ledger](research/refactor-2026-09-26/synthesis/high-priority-disposition-fc8270bb.md) records 84 provisional fixes, 12 deferrals and one keep. Static actions are not runtime incidence or permission to repeat a repair already merged.
- [Aiur v0.0.7](https://github.com/aiur-team/aiur/releases/tag/v0.0.7) was published from `main@465aca643527ea94a4d0d6d7c178c5d23d2aaf57` as `aiur-cli` and the three platform packages. The [stable workflow](https://github.com/aiur-team/aiur/actions/runs/36667374101) passed at that commit. The deletion guard and GitHub cache dashboard were removed in this release, so their deletion is outside the future refactor's savings.
- The [release-head checkpoint](research/refactor-2026-09-26/synthesis/merged-main-465aca-release-checkpoint.md) counts 357 tracked UTF-8 text paths over 500 lines: 355 frozen-map survivors, four retired paths and two newly oversized tests. A 986-finding citation comparison gives 595 identical, 38 stale and 353 changed, moved or freeform anchors. This is citation equality only; changed anchors need focused source review.
- The [U8 proposal](research/refactor-2026-09-26/synthesis/u8-release-007/proposal.md) assigns each of those 357 paths exactly once across 35 provisional owner packages. Its [manifest](research/refactor-2026-09-26/synthesis/u8-release-007/assignments.csv) and [generator](research/refactor-2026-09-26/synthesis/u8-release-007/build.py) preserve the count and flag conditional regeneration, deletion, historical anchors and shared surfaces for U0 review.

## Current decisions and checks

All three inherited P0 mechanisms are statically repaired at the published commit: completion routing authorizes before dispatch, the OpenAI-compatible command sandbox clears daemon credentials, and stopping an instance selects its own recorded pidfile. U1 still calls for a coalesced-route no-send test, a real bubblewrap environment witness and a two-live-instance stop witness; recycled PID identity remains [issue #2844](https://github.com/aiur-team/aiur/issues/2844). The [release checkpoint](research/refactor-2026-09-26/synthesis/merged-main-465aca-release-checkpoint.md) also identifies CODEOWNERS trust, ambiguous decision-journal writes, and Codex startup diagnostic lifetime as current-source behavior gates.

The first GitHub access seam stays inside the existing process hierarchy until complete/held/unknown outcomes and restart behavior are proved. Package extraction follows an ownership and release benefit, not a target package count. Feature cuts require current use, indirect caller and replacement evidence. The [plan](plans/2026-09-29-001-refactor-production-readiness-plan.md) assigns these checks to U0–U9 and requires a real foreground CLI/TUI run for user-facing acceptance.

To reproduce the release-head assignment audit from the repository root:

```sh
python3 docs/research/refactor-2026-09-26/synthesis/u8-release-007/build.py
```

This regenerates only the assignment CSV and asserts the 357-path reconciliation. Recheck paths and citations on the implementation SHA before assigning workers; the released baseline does not prove future behavior or a saving.
