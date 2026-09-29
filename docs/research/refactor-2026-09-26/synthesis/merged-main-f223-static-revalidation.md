# Merged-main static revalidation at `f223f30ead855c1f88ea188fb8f9cf74414ffb90`

This is a source and inventory check of the clean, merged 0.0.6 tree on 2026-09-29. It is not a runtime incidence study, a finding disposition, or proof that the release was published. The frozen baseline is `3339b887196d5e9aefb273117a14bf33391ee41f`; the last pre-merge candidate is `0299daca28383a336682374e19e90d6434aa4e1a`.

## Results

- The frozen 1,033 source IDs still map to 986 canonical findings. Exact cited-line comparison against merged main classifies 725 findings current at their cited lines, 36 stale and 225 unknown. The 4,961 cited locations are 4,422 identical, 63 stale and 476 unknown. Identical lines establish only citation stability; changed or moved lines require semantic review. All three P0 findings have changed citations: `agent-backends-oc-01` remains an open authentication contract, while #2845 and #2846 statically address the GitHub-token and cross-instance stop mechanisms in `agent-backends-oc-02` and `nonelixir-shell-01`. Their runtime incidence is unknown. Recycled-PID identity remains #2844.
- The tracked-tree census counts 3,423 paths: 3,337 UTF-8 text, 47 binary, 39 symlinks, no missing paths. Of the text files, 1,185 exceed 200 lines and 355 exceed 500. Every 500-plus path belongs to the frozen 359-row owner map. Four paths are absent after the cache page removal: `src/lib/aiur_web/live/github_cache_live.ex`, `src/test/aiur_web/live/github_cache_live_test.exs`, `src/test/aiur/github/cache_inspector_test.exs`, and `src/lib/aiur/github/budget_map.ex`. There is no newly oversized tracked path. The 355 surviving owner rows retain proposed, unapproved dispositions; ownership and caller/release checks are still implementation gates.
- The separate source validation lists 23 conditional provisional path-role rows and 19 flagged owner corrections, 42 distinct paths. Git blob IDs for all 42 are identical between the pre-merge candidate and this main SHA, so their cited source anchors carry forward. The middle owner audit has 43 provisional owners in all: 23 conditional and 20 with unresolved actions; one additional verified-namespace row has an unresolved action. The 21 action routes still need implementation or explicit source/consumer decisions, including eight CE updater gates and the Build Order fixture. Exact blob identity does not approve a proposed split.
- The 216-feature citation delta was regenerated against this exact main SHA. Exactly 156 entries still have revalidation reasons, including 21 Muse-adjacent entries; 91 cite modified source paths, 135 cite changed documentation, and six cite deleted source paths. Compared with v3, only `subsystems-21` and `ui-22` gain a cited source change: `src/lib/aiur/launcher_watchdog.ex` now checks the exported foreground launcher PID through `ProcessIdentity.alive?/1`, and the launcher exports that PID only into fresh foreground starts. The `simplify` decisions for these features remain provisional. The 156 are a review queue, not 156 approved cuts or individually behavior-validated entries.
- The effective P2/P3 reconciliation still accounts for all 889 records and 17 overlays: 244 provisional fixes and 645 deferrals. It was reproduced on the research checkout; current-main behavior review and reachable-population evidence remain outstanding.

## Reproduction

From the research checkout, with both revisions fetched:

```sh
python3 docs/research/refactor-2026-09-26/tooling/current_head_static_triage.py --findings docs/research/refactor-2026-09-26/review/findings.json --base 3339b887196d5e9aefb273117a14bf33391ee41f --head f223f30ead855c1f88ea188fb8f9cf74414ffb90 --output /tmp/aiur-f223-triage.json
python3 docs/research/refactor-2026-09-26/tooling/feature_release_delta.py --repo . --candidate f223f30ead855c1f88ea188fb8f9cf74414ffb90 --output docs/research/refactor-2026-09-26/synthesis/feature-merged-main-f223-delta.jsonl --check
python3 docs/research/refactor-2026-09-26/tooling/audit_p2p3_reconciled.py
```

The file census used `file_size_census.py` on a detached, clean worktree at the exact main SHA; its physical-line rule includes blank lines and unterminated final lines, classifies binary, and does not count symlink targets twice. The resulting 359-path comparison was checked by path against `synthesis/oversized-file-owner-map.csv`. Repeat the census after any newer main merge; do not treat this snapshot as a perpetual current-main claim.

## Next evidence gates

Inspect changed source spans and indirect callers for the 225 unknown and 36 stale findings, especially all P0/P1 and the 17 P2/P3 overlays. For each of the 156 feature entries, inspect actual hunks and replacement reachability before promoting a keep/simplify/cut decision; the static citation mapping alone is insufficient. Review and assign the 355 surviving oversized paths against main, then execute the trust, journal/projection, and GitHub seam behavior matrices before the plan advances from requirements-only.
