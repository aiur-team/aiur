# U7-T01 usage census and cut decisions

Tree: `6c88efd16` (main, 2026-10-10). Counts only; no paths, hostnames or config contents from private sources.

> `features.json` is not in this tree (the historical research pack was removed; see [STATUS.md](STATUS.md)), so the release_override updates have no file to land in. The decisions below are the record.

## Already cut (closed)

| Entry | Cut by | Evidence at 6c88efd16 |
| --- | --- | --- |
| cli-38 `guard-pr-deletions` | #2840 `d04069711` | no implementation in tree; the one remaining mention is the history-only plan `docs/plans/2026-08-17-001-...-plan.md:148` (left as-is: plans are history) |
| integrations-20, ui-13 `/github-cache` | #2841 `694f9d021` | only negative assertions remain (`route_registry_test.exs`) |

Their "pending merge and publication" override is false; mark them cut and merged.

## Census

| Population | Count | Date |
| --- | --- | --- |
| Tracked configs/examples with `tracker.kind: linear` | 1 (`src/examples/workflows/linear-codex.yaml`) | 2026-10-10 |
| Dev-host `.aiur/config` files found (depth 4 under code/github) with `kind: linear` | 0 of 24 | 2026-10-10 |
| `src/lib` files referencing Linear (`Aiur.Linear`, `linear_graphql`) | 6 | 2026-10-10 |
| `src/test` files mentioning Linear | 63 | 2026-10-10 |
| `src/lib` files referencing claude-repl / remote control | 61 | 2026-10-10 |
| Files under `.claude/skills/aiur-build` | 93 | 2026-10-10 |
| Callers of `scripts/aiur-test3-phases` (scripts, packaging, CI, skills, tests, string refs) | 0 (self-references and one inventory entry only) | 2026-10-10 |
| 90-day run logs by tracker kind; launcher logs for `--clear` | not measurable: no run-log or launcher-log population exists on this host | 2026-10-10 |

## Decisions

| Candidate | Decision |
| --- | --- |
| integrations-09 Claude REPL / Remote Control | keep (#3038 made the account-limit handoff REPL-only) |
| integrations-46 aiur-build | keep in repo; defer externalization |
| cli-44 `--test` / `--test3` | keep (release acceptance) |
| cli-44 `aiur-test3-phases` | **cut** (0 callers); deleted here with its FI-ENG-059 inventory entry |
| cli-44 `--clear`, test3 timer | keep: no launcher-log evidence of non-use |
| integrations-03 Linear | owner decision (U7-T02). Evidence: 1 tracked example, 0 dev-host configs, but Linear is the `tracker.ex` fallthrough default and `linear_graphql` is registered unconditionally, so a cut changes defaults and is not a pure deletion. Absence of dispatch logs is not evidence of no use by others. |
