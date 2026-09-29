# Aiur refactor research index

The [requirements](brainstorms/2026-09-29-aiur-refactor-requirements.md) and [production-readiness plan](plans/2026-09-29-001-refactor-production-readiness-plan.md) are the short documents intended for `main`. Their frozen-source evidence is pinned to public research commit [`e09869f9c1afe21dc4edda2c4244e624ccebde1b`](https://github.com/aiur-team/aiur/tree/e09869f9c1afe21dc4edda2c4244e624ccebde1b/docs/research/refactor-2026-09-26). The frozen product source was `3339b887196d5e9aefb273117a14bf33391ee41f`; the v2 owner audit used `7bce08f36aede1f9747d24bb3a5c08145abd081e`, and the final clean pre-merge candidate check used `0299daca28383a336682374e19e90d6434aa4e1a`. Research was synthesized on 2026-09-29. These SHA references are evidence snapshots, not assertions about merged `main`.

The evidence tree contains all 32 raw review units, 1,033 source IDs mapped losslessly to 986 canonical findings, two independent skeptic reviews for all 182 inherited P0/P1 source findings, and a 216-feature catalog. Its [effective P2/P3 audit](https://github.com/aiur-team/aiur/blob/e09869f9c1afe21dc4edda2c4244e624ccebde1b/docs/research/refactor-2026-09-26/tooling/audit_p2p3_reconciled.py) checks all 889 canonical records plus 17 reconciled overlay decisions: 696 source-supported mechanisms, 192 unknown and one unsupported; 244 provisional fixes and 645 deferrals. The [owner-map audit](https://github.com/aiur-team/aiur/blob/e09869f9c1afe21dc4edda2c4244e624ccebde1b/docs/research/refactor-2026-09-26/synthesis/oversized-file-owner-map-audit-summary.md) covers all 359 frozen files above 500 lines; four disappear in the pre-release candidate. The 17,944-line feature-cut footprint is conditional gross deletion, not measured net saving.

The final pre-merge v3 candidate statically addresses two frozen P0 mechanisms: [PR #2845](https://github.com/aiur-team/aiur/pull/2845) removes ambient GitHub-token inheritance from OpenAI-compatible command sandboxes, and [PR #2846](https://github.com/aiur-team/aiur/pull/2846) removes the cross-instance stop-time pidfile sweep. Their focused tests require merged-main re-execution; runtime incidence remains unknown, and recycled-PID identity remains separate issue #2844. V3 changes cited paths for four more findings than v2, giving **294 path-affected findings** for source recheck; that count is not a defect count. The 359-row owner map still has four removed dashboard paths, 355 oversized paths and no new oversized tracked path in v3. Actual merged-main validation remains pending.

To reproduce the checks, fetch the pinned commit into a separate research checkout and run from the repository root:

```sh
git fetch origin e09869f9c1afe21dc4edda2c4244e624ccebde1b
git worktree add --detach ../aiur-refactor-evidence e09869f9c1afe21dc4edda2c4244e624ccebde1b
cd ../aiur-refactor-evidence
python3 docs/research/refactor-2026-09-26/tooling/audit_review_synthesis.py docs/research/refactor-2026-09-26
python3 docs/research/refactor-2026-09-26/tooling/audit_p2p3_triage.py
python3 docs/research/refactor-2026-09-26/tooling/audit_p2p3_reconciled.py
python3 docs/research/refactor-2026-09-26/tooling/privacy_check.py
```

**Before implementation:** refresh source reachability and finding incidence on merged release `main`; recount and assign the full oversized-file owner map against that head; test the CODEOWNERS trust, journal/projection and first in-process GitHub seam contracts. Preserve the universal 500-physical-line target for every tracked UTF-8 text file, including docs, tests and vendor/generated text. The raw evidence tree is intentionally kept outside main because its large artifacts exceed that future cap. The retained history cannot assign a cause to every idle-gap minute; prospective measurements must record actionable demand and observed action.
