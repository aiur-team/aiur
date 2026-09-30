# Refactor checkpoint at released `main@465aca643`

Aiur `v0.0.7` points to `465aca643527ea94a4d0d6d7c178c5d23d2aaf57`. Its [stable workflow](https://github.com/aiur-team/aiur/actions/runs/36667374101) passed, and all four npm packages resolved at `0.0.7` with `latest=0.0.7` on 2026-09-30. This pins the refactor baseline; the release proof does not establish the behavior of any proposed refactor.

## Complete tracked-text census

From this research checkout, with `RELEASE_CHECKOUT` pointing to a clean canonical checkout of that commit, run:

```text
python3 docs/research/refactor-2026-09-26/tooling/file_size_census.py 465aca643527ea94a4d0d6d7c178c5d23d2aaf57 "$RELEASE_CHECKOUT" --repository "$RELEASE_CHECKOUT"
```

The complete result counted 3,436 tracked paths, 3,348 UTF-8 text files, 47 binary files, 1,188 text files above 200 physical lines, and **357 above 500**. The [357-path CSV](file-size-census-release-007.csv) preserves each oversized path and count in fewer than 500 lines. There were no missing tracked paths. This is a new full census, not the earlier changed-blob estimate.

Of the 359 frozen [owner-map](oversized-file-owner-map.csv) paths, 355 remain oversized. Four disappeared from the tracked tree with the pre-refactor GitHub cache dashboard removal (#2841): `src/lib/aiur_web/live/github_cache_live.ex`, `src/test/aiur_web/live/github_cache_live_test.exs`, `src/test/aiur/github/cache_inspector_test.exs`, and `src/lib/aiur/github/budget_map.ex`. These removals belong to the published release and are excluded from future refactor savings. Two newly oversized paths need U8 owners:

| Path | Lines | Proposed owning boundary | Required split proof |
| --- | ---: | --- | --- |
| `src/test/aiur/orchestrator/status_report_test.exs` | 533 | Orchestrator status and projections | Keep status values, cause and observed age together across CLI and web cases. |
| `src/test/aiur_web/components/operator_control_center/units_table_test.exs` | 513 | Operator control center components | Split by rendered user behavior while preserving unknown and stale cases. |

Both owner assignments are provisional until U0 reviews the worker boundaries and caller checks. The 357-path inventory is a debt baseline, not a claim that 357 files should become 357 separate packages.

## Current-source checks that remain behavioral gates

- The three inherited P0 mechanisms are statically repaired at this tag: `chat_completions.ex:56-64` authorizes before marker/coalesced dispatch; `open_ai_compat/command_runner.ex:10,80-99` starts bubblewrap with a cleared environment; and `aiur-engine.sh:3511-3578` selects the stopping instance's recorded pidfile. Their existing bridge, command-runner and stop-pidfile tests cover source-level branches. U1 still needs coalesced text plus marker with an explicit no-send assertion, real bubblewrap `env` with synthetic daemon credentials, and a real two-instance stop. For that last witness, use two fresh isolated Executor-controlled roots and stop only their recorded instances: `src/test/regression/aiur-shutdown.sh:20-25` broadly kills Aiur/OpenCode processes and could terminate a live daemon. Recycled PID identity is separately tracked by #2844. This is a source audit, not a claim that those live witnesses ran.
- `web-occ-12`: #2905 statically escapes SVG labels; browser rendering and a production-hunk red/green check remain before treating the behavior as verified. Do not queue a duplicate escaping repair.
- CODEOWNERS trust (`github-a-01`, `github-a-07`, KTD9/U5): `src/lib/aiur/github/code_owners.ex` and `src/lib/aiur/codeowners.ex` still carry separate trust and path-resolution behavior. Failed team lookup can become an empty list, cached membership has no expiry, and team/PR-file readers can stop at one page. Test degraded cause and age, revocation, pagination and command authority on this release base. The [current-main audit](codeowners-current-main-2026-09-30.md) has the detailed source paths.
- Decision journal (`loose-1-02`, `loose-1-03`, KTD10/U6): an append may write a complete record before `sync` reports failure; a later projection failure can leave accepted authority with a stale read model and a notification path. Test ambiguous writes, restart reconciliation and side-effect replay by event ID before changing ownership.
- Codex startup diagnostics (R2/KTD4/U4/U6): `src/lib/aiur/codex/startup_failure.ex` appends bounded excerpts without file retention/rotation, but `Config.Paths.log_root_dir/0` creates a per-launch directory. Retry failure time is volatile in `state.retry_attempts`; CLI prints its timestamp rather than an observed age. A short secret whose keyword is interrupted by ANSI may evade the current line filter; this is a source-level privacy hypothesis requiring a focused redaction test, not a measured leak. Specify what survives restart, what remains forensic-only, bounded retention, redaction and a rendered age before extracting this path.

These checks are source observations at the tagged commit. They do not measure incident frequency or prove a runtime failure. The 182 inherited P0/P1 findings already have two independent static verdicts; affected citations and the two new test owners need release-head review without repeating those verdicts mechanically.

## Release-head citation triage

The pinned [static triage tool](../tooling/current_head_static_triage.py) compared all 986 canonical finding citations from `3339b887` with `465aca643`: 595 findings had identical cited lines, 38 had a stale path or line range, and 353 had changed, moved or freeform anchors requiring source review. All three P0 findings have changed or moved anchors. Of 94 P1 findings, 60 have identical anchors, two have stale anchors (`nonelixir-shell-03`, `web-rest-08`), and 32 have changed or moved anchors. These statuses describe citation equality only; they do not confirm or dismiss a defect.

The two stale P1 anchors received source follow-up. `nonelixir-shell-03` is repaired at this release: the shipped tmux config binds the packaged `aiur-pane-ctrlc` helper before the foreground TUI starts (`packaging/npm/aiur-cli/share/aiur.tmux.conf:68-87`, `libexec/aiur-engine.sh:1003-1014`), both files are in the npm manifest, and `bash scripts/verify-ctrlc-binding.sh` passed its four checks on the release clone. A real installed chat-pane Ctrl+C with a queued message remains a narrower UX witness: send Ctrl+C through the attached wrapper tmux client to exercise the binding, and confirm the pane survives and queued text is delivered once. Sending the key directly to the inner pane bypasses that binding. `web-rest-08` remains live in retained paths, but the deleted cache page invalidates its frozen surface count: `DecisionApiController.invoke` collapses raised/exit causes to `:store_unavailable` (`decision_api_controller.ex:63-69`); `StreamdeckLive.update_logs` swallows a scroll failure (`streamdeck_live.ex:1410-1415`); `ChangeBridge.init` ignores subscription errors without retry (`change_bridge.ex:35-43`); and `Generation.subscribe` can turn a dead server into `:ok` (`generation.ex:30-35`). U6/U7 should inject each failure and assert visible cause, retry and event delivery. A generic web-wide rescue wrapper is not a justified repair.

Run the comparison from this research checkout with `--findings docs/research/refactor-2026-09-26/review/findings.json --base 3339b887196d5e9aefb273117a14bf33391ee41f --head 465aca643527ea94a4d0d6d7c178c5d23d2aaf57 --output <temporary-json>` and the tool's required Python path. The prior `source-anchor-corrections.json` cannot be applied blindly to this head: its `web-rest-08` correction at `financial_data/change_bridge.ex:369-383` is no longer identical. Refresh affected anchors in the owning implementation units, keeping the raw citation and current source evidence separately.
