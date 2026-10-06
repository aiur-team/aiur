---
ticket_id: MP-R1-C9-T04
feature_id: MP-R1
chunk_id: MP-R1-C9
bucket: 1-refactor
title: PR command-scan listener owns the repo-wide command-scan cursor
status: blocked   # research complete; only DESIGN-R1 and named predecessors remain
blocked_by: [DESIGN-R1, MP-R1-C9-T02, MP-R1-C9-T03, MP-E1-C1]
prior_units: [U2, U3, U5]
prior_boundaries: [ING #9, ORC #12]
prior_features: []
prior_findings: [orch-a-19, orch-b-12]
size_owner: LIFECYCLE_DISPATCH (orchestrator/state.ex, orchestrator/dispatcher.ex); command_scan.ex (417 lines) is not in the U8 ledger -> n/a for that file
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C9-T04 — Command-scan listener

## Identity and outcome

- Bucket 1, MP-R1, chunk C9, step S15.
- **User value:** none visible. The repo-wide `/aiur` and `@bot` PR-command scan stops
  holding cursor state in `Orchestrator.State`.
- **Deliverable:** `Aiur.GitHub.Listeners.CommandScan` (PROPOSED,
  `src/lib/aiur/github/listeners/command_scan.ex`), a third child of
  `Aiur.GitHub.Listeners`, owning `github_command_scan_since` and
  `github_command_scan_etags` (the field C9-T02 split out of `github_comment_etags`). The
  module `Aiur.Orchestrator.CommandScan` moves with it and is renamed
  `Aiur.GitHub.Listeners.CommandScan.Scan`.
- **Non-goals:** the known defect `orch-a-19` (commands past the per-cycle cap of 25 are
  dropped while the cursor advances, `command_scan.ex:38,88-93`) is **not** fixed here. A
  refactor PR must not change it; the finding stays with its owner (U5/U7 dispositions).

## Dependencies and blockers

- DESIGN-R1 §1; C9-T02 (field split), C9-T03 (same supervisor file, serialize);
  MP-E1-C1 (RC-19). No transition change → not blocked on RQ-U2-TRANSITION.
- Concurrent with C9-T05–T07 and C9-T10–T14.

## Verified starting point (45a290e3)

- Two synchronous call sites inside the orchestrator tick:
  `dispatcher.ex:179` (`CommandScan.scan_pr_commands(state)` in
  `dispatch_candidate_poll/2`, after `StartupClaimReconciler.reconcile/2` and before
  `PrAnchored.maybe_stop_closed_pr_anchored_agents/1`) and `dispatcher.ex:227` (default
  `:scan_commands_fun` in `monitor_without_candidates/2`).
- `do_scan_pr_commands/2` (`command_scan.ex:65-112`) reads only
  `github_command_scan_since` and the two etag keys, publishes command hits through
  `Publisher` and deposits bodies in `ResourceStore`; it writes back only the cursor and
  etags (`:105-111`). It reads nothing else from `State`.
- Gate: `Config.tracker_kind() == "github" and GitHub.Config.pr_watch_enabled?()`
  (`command_scan.ex:47`).
- Tests: `src/test/aiur/orchestrator/command_scan_test.exs`,
  `src/test/aiur/events/pr_command_scanner_test.exs`,
  `src/test/aiur/events/pr_command_scanner_identity_mode_test.exs`.

## Chosen design

- `Aiur.GitHub.Listeners.scan_commands(opts) :: :ok` — `GenServer.call(…, :infinity)`.
  Synchronous on purpose: the scan runs between `StartupClaimReconciler` and
  `PrAnchored` today, and command events published in this tick are delivered to the
  orchestrator mailbox before the next tick either way, so a synchronous call is the only
  shape that keeps the order of publications relative to the rest of the tick.
- No outcome returns to `State` (the scan reports no connectivity today).
- Reset: `Listeners.reset/0` (called from `Lifecycle.init/2`, C9-T01) resets `since` and
  `etags` to `nil`/`%{}`, matching a fresh `%State{}` today. The durable validators in
  `ResourceStore` still answer the first scan after a restart (`command_scan.ex`
  moduledoc `:14-19`), unchanged.
- Exit propagation: not caught (same rule as C9-T01).

## Implementation steps

1. `git mv src/lib/aiur/orchestrator/command_scan.ex src/lib/aiur/github/listeners/command_scan/scan.ex`;
   change its head from `%State{}` to a small `%{since, etags}` struct.
2. Add the GenServer child and the facade function; add it to the supervisor child list.
3. Replace both dispatcher call sites; keep the `:scan_commands_fun` test seam with the
   new default.
4. Remove the two fields from `State`.
5. Move `command_scan_test.exs` to `src/test/aiur/github/listeners/command_scan_test.exs`.

Estimated: ≈60 changed lines, ≈417 moved lines.

## Non-happy paths

GitHub failure inside the scan is already logged and yields `[]` (`command_scan.ex`
comments at `:115-118`); unchanged. Listener crash → orchestrator restarts with it
(`:rest_for_one`, same blast radius as an inline crash today). Restart → `since: nil`, as
today.

## Compatibility and rollout

`pr_watch.*` keys unchanged. No disk format change (`ResourceStore` keys unchanged:
`:repo_review_comment_stream`, `:repo_issue_comment_stream`). Revert to roll back.

## Verification

```bash
env -C <checkout>/src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/github/listeners/command_scan_test.exs test/aiur/events/pr_command_scanner_test.exs \
  test/aiur/orchestrator/dispatcher_test.exs
```

| Test | Expectation | Fails without |
|---|---|---|
| `command_scan_test "since advances in the listener across two scans"` | second scan request carries the first scan's newest timestamp | the listener state write |
| `command_scan_test "reset clears since and etags"` | after reset the stubbed fetch receives `since: nil`, `etag: nil` | reset clause |
| `dispatcher_test "command scan runs after startup-claim reconciliation and before PR-anchored stop"` | ordered stub calls in `dispatch_candidate_poll/2` | the call placement |

Mutation check per AGENTS.md. Manual: wrapper-tmux `aiurdev --test`; comment `/aiur
rework` (or the configured command) on a sandbox PR; the target agent's chat pane shows the
command event.

## Completion and handoff

- [ ] Two fields gone from `State`; scan order pinned by test.
- [ ] `orch-a-19` explicitly unchanged (named in the PR body).
- Docs: none (internal).
- Dependents: C9-T07. size_owner re-resolved at ticket start (RC-23).
