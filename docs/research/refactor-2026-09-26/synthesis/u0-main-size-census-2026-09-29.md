# U0 tracked-text census at merged main

Read-only recount at merged main `c2cbf881b12db3e786ead8cb93edd9db34e15cc5`, after research-index PR #2873. The census used `tooling/file_size_census.py` against a complete detached worktree of that commit. It counts LF-separated physical lines, including an unterminated last line, for tracked UTF-8 files; NUL-containing or non-UTF-8 files are binary, and symlink targets are not counted twice.

| Measure | Count |
| --- | ---: |
| Tracked paths | 3,427 |
| UTF-8 text files | 3,339 |
| Binary files | 47 |
| Text files over 200 lines | 1,187 |
| Text files over 500 lines | 355 |
| Missing paths in worktree | 0 |

The 355 current oversized paths are all in the frozen 359-row `synthesis/oversized-file-owner-map.csv`; there is no new path requiring an owner. Exactly four frozen paths are no longer oversized because they are absent: `src/lib/aiur/github/budget_map.ex`, `src/lib/aiur_web/live/github_cache_live.ex`, `src/test/aiur/github/cache_inspector_test.exs`, and `src/test/aiur_web/live/github_cache_live_test.exs`. This agrees with the earlier released-main count, while refreshing its source head to `c2cbf881b`. It does not show that any of the 355 remaining paths was refactored or that net lines were saved.

Reproduction with this research branch and a complete checkout of that commit:

```sh
python3 <research-checkout>/docs/research/refactor-2026-09-26/tooling/file_size_census.py \
  HEAD <main-checkout> --repository <main-checkout>
```

The owner-map set comparison used the `oversized` paths in the command's JSON output against the `path` column of `synthesis/oversized-file-owner-map.csv`. Rerun this check on each implementation head; the final 500-line gate still needs implementation and CI enforcement.

## Later current-main checkpoint

The same census command on complete detached `b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f` reports 3,434 tracked paths: 3,346 UTF-8 text files, 47 binary files, and 41 symlinks. Of the text files, 1,188 exceed 200 lines and **357 exceed 500**. This is a source census, not evidence that any runtime finding occurs in production.

The original 359-row owner map still covers 355 oversized paths; its four absent paths remain the deletions listed above. Two tests now need owner rows: `src/test/aiur/orchestrator/status_report_test.exs` (508 lines) and `src/test/aiur_web/components/operator_control_center/units_table_test.exs` (513 lines). Among surviving mapped paths, 63 line counts have changed since the map's `main_lines` column was recorded. The dated [65-row delta](owner-map-b4bc-delta.csv) records those changes and the two new paths without replacing the frozen map. Of the 63, 56 grew and seven shrank, for a combined 1,400 more physical lines across those paths; that is source change, not a refactor saving or incidence measure.

Two independent recounts confirmed the 357 total and the four absent paths. A blob-level cross-check also matched all 359 frozen counts to `3339b887` with no mismatch. The new status-report test fits the existing `Ticket lifecycle and dispatch tests` owner category; the UnitsTable test fits `Web UI and dashboard tests`. These category assignments are provisional, not permission to split tests by arbitrary line ranges. Refresh counts and actions on the final release base before enabling the universal gate.

## Research-branch checkpoint after main cleanup

The [JSON census](u0-main-size-census-8f17-2026-09-30.json) of clean `main@8f17b91f12191031eb7be3590f2dc290a81095c0` records 3,439 tracked paths, including 3,351 UTF-8 text files, 47 binary files and 41 symlinks. Of the text files, 1,189 exceed 200 lines and **357 exceed 500**. No tracked path was missing. The oversized path set equals all 357 distinct paths in `u8-release-007/assignments.csv`, with no new or retired path since that release-head proposal. Exactly four assigned paths changed physical line count: `github/resource_store.ex` 2,191→2,261; `build_order/graph_projection.ex` 1,825→1,842; `events/github_webhook/deposit.ex` 991→996; and `website/docs-app/apis/github.md` 742→759. Their combined increase is 109 lines. This source count proves neither runtime incidence nor a refactor saving.

The JSON was produced with `tooling/file_size_census.py` against a complete detached checkout of `8f17b91f`. The set check compared its `oversized[*].path` with `u8-release-007/assignments.csv`'s `path` column and compared `oversized[*].lines` with `release_lines`; duplicate or absent rows would invalidate the equality. Recount the implementation SHA before installing a size gate. This checkpoint stays on `research/refactor-findings`; it is not a change to `main`.
