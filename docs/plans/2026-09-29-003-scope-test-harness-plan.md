---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
plan_source: ce-plan
issue: 2885
---

# Scope the development test harness to pinned tickets

## Cause and boundary

`scripts/aiurdev --test` resets the first ID in `.aiur-test-tickets.json` but starts the ordinary daemon without a target filter. `Aiur.Orchestrator.Lifecycle.init/2` runs startup todo and terminal workspace cleanup before the first poll; those paths fetch every matching issue through `Aiur.Tracker`. The later candidate poll also sees the whole backlog. Thus a concurrency limit cannot keep an unrelated dirty todo workspace safe.

The development `--test` mode must restrict issue discovery to the first pinned ID; `--test3` must restrict it to the complete pinned set. An ordinary run retains full discovery. The scope is an internal launch value, not a user config key. A missing or malformed pinned file fails before the shim clears logs, stops a daemon, or resets tickets. The explicit reset stays limited to the same selected IDs.

## Implementation

1. Validate and select IDs from `.aiur-test-tickets.json` in `scripts/aiurdev`; export the internal scope only for a successful test launch. Cover the single and three-ticket modes and fail-closed cases in `src/test/scripts_aiurdev_test.exs`.
2. Add a small issue-scope function at the tracker read boundary, including the GitHub conditional-list paths used directly by CI and review polling. It filters complete issue records by canonical ticket identifier before any orchestrator cleanup or reconciliation receives them. Guard direct workspace cleanup and orphan-runner reaping too. Keep an absent scope as an exact pass-through. Cover candidate and state-list reads in focused tests.
3. Reproduce startup cleanup with a pinned todo and an unrelated dirty todo workspace. The pinned tree may be cleaned; the unrelated bytes and tracker state must remain. Prove the new test fails when the filter is removed, then restore it and rerun.
4. Update `website/docs-app/reference/cli.md` to state that `--test` and `--test3` constrain the launched workflow. Verify with unit/integration tests only while the preservation incident remains open. The Executor owns the real foreground TUI acceptance after it is safe to launch.

## Explicit limits

The separate preserve-before-recreate bug #2743 remains a production-workflow concern. This change does not relax ordinary cleanup, change configured agent limits, or claim a GitHub quota saving.
