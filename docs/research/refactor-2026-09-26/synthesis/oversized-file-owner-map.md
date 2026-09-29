# Oversized tracked-text owner map

The [complete CSV](oversized-file-owner-map.csv) assigns a proposed owner and a next disposition to each of the **359** files over 500 physical lines in the frozen census. It is planning evidence, not an approved deletion list or a measured saving. Current public `main` is `3339b887196d5e9aefb273117a14bf33391ee41f`, the same revision named by the [census](file-size-census.json). Independent `git show` reads confirm that all 359 corrected public paths still exist at their frozen physical-line counts. No post-baseline main change appears in the CSV.

| Proposed disposition | Files | Decision needed before code change |
| --- | ---: | --- |
| Split by responsibility or behavior | 344 | Confirm semantic seams and keep every public entry point and test. |
| Regenerate or replace tracked data/lock output | 8 | Prove reproducibility, consumer parity and a final tracked artifact at most 500 lines. |
| Remove after replacement/reachability check | 7 | Prove no active caller, or ship the tested replacement first. This includes the user-requested GitHub cache dashboard removal and two vendored worker outputs. |
| **Total** | **359** | No row authorizes a cut by itself. |

## Census path correction

The published `file-size-census.json` has one path-alias error. The initial census in research commits `0eb07ebac` and `22746ed4f` named a **public tracked Build Order demo fixture** at 1,611 lines. Privacy-redaction commit `af5393171` replaced that path string with a private-alias placeholder, without changing the count. The placeholder has never existed in the stated frozen tree or current public `main`; the original public fixture still does and remains 1,611 lines. The CSV restores the original public path based on the pre-redaction census and verifies its count from the public Git blob. No private file content was read or copied.

This is an **alias error in the published census**, not an additional oversized file, an untracked input, or a reduction on main. The 359-file and 1,192-above-200 aggregate counts remain valid; the affected `src/priv/build_orders/` row's identity was wrong. Existing plan statements that cite 359 oversized files or zero measured saving do not change. Any future machine gate must derive its baseline from `git ls-tree` and current blobs, not copy the incorrect published path string. The old census should be corrected in a separately owned research edit when its owner is available.

## How to read and execute the map

Each CSV row gives the frozen and current-main line count, main-change flag, proposed owning boundary, one of three dispositions, a concrete next action, evidence basis and confidence. The count uses LF-separated UTF-8 physical lines, including blanks/comments and an unterminated final line. Proposed owners are responsibility boundaries inferred from public path/module roles; they are not team assignments. `medium` means the path role and proposed seam are supported but callers and behavior still need review. `low` means the disposition depends on reachability, packaging, or an unverified document/data generation path. No row is marked implementation-ready solely by this map.

For code, split by state owner, policy, IO effect, presentation or a named feature responsibility, then prove behavior and delete the old duplicate path. For tests, split scenarios by behavior/context and share fixtures without weakening assertions. For docs and skills, keep a short index and stable links to bounded topic files. For generated assets and lockfiles, retain deterministic installation and release behavior; never satisfy the cap by arbitrary line slicing or by hiding required output from the tracked-text gate. All proposed removals remain conditional on a caller and packaging audit.

The two GitHub cache LiveView rows are mapped to removal under PR #2841 because the user ordered that surface deleted. Their disappearance after that PR merges is a release change, excluded from future refactor savings. The other five removal rows require independent reachability or replacement proof. The CSV's gross line counts are debt exposure only: no net LOC reduction is claimed.

Before promoting a component to implementation-ready, refresh the map on merged main; inspect indirect references, config, build scripts, docs and package entries; record a named owner and acceptance tests; and establish the transitional 500-line gate's debt ledger. The final gate still covers generated, vendored, test, docs and skill text. The 200-line preference remains a cohesion review prompt.
