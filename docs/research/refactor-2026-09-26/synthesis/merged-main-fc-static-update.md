# Release-head static update at `fc8270bb6d30cf44a860b142b365ad10e5c906a1`

PR #2860 adds bounded retry and failed-server cleanup to the Opencode prewarm slot boot. Its focused tests cover returned exit-status-1 errors and a serve that dies before `await_ready` registers. This is source and test evidence; no installed-release behavior or failure incidence is inferred here.

Against the frozen `3339b887196d5e9aefb273117a14bf33391ee41f` source, the 986 canonical findings classify as 722 cited-line current, 37 stale and 227 unknown, versus 723/37/226 at `a4e5f70ac`. Only P2 `agent-backends-oc-22` moves from current to unknown: its `serve_lifecycle.ex:42-77` citation was rewritten by #2860. All P0 and P1 citation statuses are unchanged. Citation status is not a finding verdict.

The complete tracked-tree census remains 3,424 paths: 3,336 UTF-8 text, 47 binary and 41 symlinks, with no missing path. The number above 200 lines rises from 1,185 to 1,186; above 500 remains 355. No new oversized path appears, and all 355 remain in the frozen 359-row owner map.

The 216-feature path-status delta still queues 156 entries, with 92 changed-source and 135 changed-documentation hits. Relative to `a4e5f70ac`, only `integrations-11` and `ui-23` gain changed `serve_lifecycle.ex` citations. This does not change their effective decisions, establish live use or approve removal. Exact-head behavior checks and reviewed worker owner assignments remain required before implementation.

Reproduce from a clean checkout of this full SHA with `current_head_static_triage.py` (frozen base above), `feature_release_delta.py --candidate` and `file_size_census.py` as in the [f223 audit](merged-main-f223-static-revalidation.md). A later main revision requires another exact-head pass.
