---
ticket_id: MP-R1-C7-T1
feature_id: MP-R1
chunk_id: MP-R1-C7
bucket: 1-refactor
title: Split the Tracker contract into IssueTracker and CodeHost ports
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T1, MP-R1-C1-T3, MP-E1-C1]
prior_units: [U2, U4, U5, U7]
prior_boundaries: [TRK, GHD, LIN]
prior_features: [integrations-03]
prior_findings: [codebase-10]
size_owner: WORKSPACE (src/lib/aiur/workspace/provisioner.ex, 743 lines; U8 ledger at 465aca643 — re-resolve at ticket start against the then-current ledger, RC-23 / MP-R1-C11-T2); other touched files are under 500 lines
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C7-T1 — Split the Tracker contract into IssueTracker and CodeHost ports

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C7 (migration step S5, prior
  carve order `feature-boundaries.md` §7 step 3).
- **User value:** none visible. The tracker contract stops mixing issue-tracker and
  code-host operations, so Linear and memory no longer implement seven pull-request
  callbacks as stubs, and the checker can tell "this caller needs a code host" from
  "this caller needs an issue tracker". This is the precondition for the `github`
  component (C7-T6) and for any later non-GitHub code host.
- **Deliverable:**
  1. Two behaviours: `Aiur.Tracker.IssueTracker` (candidate, state, comment and label
     callbacks) and `Aiur.Tracker.CodeHost` (pull-request and review callbacks).
  2. A facade `Aiur.CodeHost` (PROPOSED `src/lib/aiur/code_host.ex`) with the six
     code-host functions and `available?/0`.
  3. `Aiur.Tracker.NullCodeHost` (PROPOSED) returning exactly the values Linear and
     memory return today.
  4. The eight code-host call sites and the four `Tracker.adapter() == GitHubTracker`
     checks migrate to `Aiur.CodeHost`.
  5. `Aiur.Tracker` keeps the six code-host functions as `@deprecated` delegates to
     `Aiur.CodeHost` for one release, so no caller breaks.
- **Non-goals:** adapter registration (C7-T2); removing Dispatcher's direct GitHub calls
  (C7-T7, C7-T8); changing any return value; cutting the Linear adapter (prior U7
  `integrations-03` decides that, not this ticket); moving `GitHub.Tracker` out of
  `src/lib/aiur/github/`.

## Dependencies and blockers

- **Owner gate:** DESIGN-R1 §1 (confirm no runtime change).
- **Predecessors:** MP-R1-C1-T1 (manifest has `tracker` and `github` entries) and
  MP-R1-C1-T3 (rule set), so the new facade is declared and the checker can record the
  edges this ticket removes.
- **Prior units:** `src/lib/aiur/orchestrator/` is U2-owned. This ticket edits only call
  expressions in five orchestrator files; it must not run while a U2 PR edits the same
  file (`LIFECYCLE_STATUS` / `LIFECYCLE_DISPATCH` single-writer rule in
  `u8-release-007/proposal.md`). `agent_runner/comment_context.ex` is U4-owned (call
  expression only). `github/tracker.ex` is U5-owned (adds `@behaviour` lines only).
- **MP-E1-C1 (RC-19, RC-20):** MP-E1 ships in wave 0 and its C1 hooks edit U5 files
  (`github/labels.ex` `@marker_suffixes`/`label_set/2`, `github/issues.ex` `queued?`
  ingestion) and U2 files (`issue_sync.ex`, `dispatch_policy.ex`). The build queue is a
  sanctioned caller of the single label-writer seam and writes `agent:todo` only through
  `Aiur.Tracker.add_label/2` / `remove_label/2` (`tracker.ex:109-117`;
  `component-map.md` §4). This ticket rebases over MP-E1-C1 and must keep
  `add_label`/`remove_label` on the issue-tracker side with unchanged signatures and
  return values; they are **not** code-host operations.
- **Concurrent with:** C7-T3 (sandbox) and C7-T5 (workspace) — disjoint files except
  `workspace/provisioner.ex` (T1 changes line 108; T5 does not touch that function).
  Serialize with C7-T2 (both edit `tracker.ex`): T1 first.

## Verified starting point (base `45a290e3`)

- `src/lib/aiur/tracker.ex:8-27` declares 17 callbacks (15 names, two arities each for
  `fetch_issues_by_states` and `update_issue_state`); `:29-32` makes four optional.
  Issue-tracker callbacks: `fetch_candidate_issues`, `fetch_issues_by_states/1,2`,
  `fetch_issue_states_by_ids`, `fetch_issue_states_by_ids_conditional`,
  `create_comment`, `fetch_classified_issue_comments`, `update_issue_state/2,3`,
  `add_label`, `remove_label`. Code-host callbacks:
  `fetch_classified_pr_review_comments` (`:16`), `fetch_classified_pr_reviews` (`:17`),
  `fetch_unaddressed_pr_review_thread_comments` (`:18`),
  `fetch_open_pull_request_for_branch` (`:20`), `fetch_open_pull_requests_for_branch`
  (`:22`). Facade functions for them: `tracker.ex:124-150`.
- `fetch_classified_issue_comments` (`:15`) reads **issue** comments; it stays on the
  issue side even though Linear and memory stub it.
- Stubs that prove the mix: `memory/tracker.ex:70-85` and `linear/tracker.ex:89-104`
  return `{:ok, []}` / `{:ok, nil}`; `linear/tracker.ex:139,142` return
  `{:error, :unsupported}` for labels (issue side; unchanged).
- Real implementation: `github/tracker.ex:137-169`.
- Code-host callers through the facade (all, `git grep` at base):
  `agent_runner/comment_context.ex:97-100`,
  `orchestrator/merged_ticket_reconciler.ex:177`, `orchestrator/rework_gate.ex:278`,
  `orchestrator/rework_requeue.ex:146`, `workspace/provisioner.ex:108`.
- "Is there a code host?" checks written as adapter identity:
  `orchestrator/human_review.ex:84`, `pr_health_scanner.ex:105`, `rework_gate.ex:272`,
  `rework_requeue.ex:137` (`Tracker.adapter() == GitHubTracker`).
- Tests: `src/test/aiur/tracker_github_test.exs:51` ("implements Tracker behaviour"),
  `src/test/aiur/extensions_test.exs:365` ("tracker delegates to memory and linear
  adapters"), `:402`.
- Size owner pinned to the U8 ledger at `465aca643`; re-resolve at start (RC-23).
- Prior evidence: `feature-boundaries.md` §2 entry 3 (split recommendation), corrected
  by `synthesis/architecture-verification.md` claim codebase-10 ("consider separate
  issue-tracker/code-host capabilities, without claiming every adapter-specific
  reference is a defect").

## Chosen design

Two behaviours, one adapter module may implement both. The code host is derived from
the issue tracker at this ticket (the only code host today is GitHub, and it is used
only with the GitHub tracker); C7-T2 makes the pairing a registration.

```elixir
# PROPOSED src/lib/aiur/tracker/code_host.ex
defmodule Aiur.Tracker.CodeHost do
  @callback fetch_classified_pr_review_comments(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_classified_pr_reviews(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_unaddressed_pr_review_thread_comments(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_open_pull_request_for_branch(String.t() | integer()) :: {:ok, map() | nil} | {:error, term()}
  @callback fetch_open_pull_requests_for_branch(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
end

# PROPOSED src/lib/aiur/code_host.ex  (facade)
defmodule Aiur.CodeHost do
  @spec available?() :: boolean()          # true only when adapter() != NullCodeHost
  @spec adapter() :: module()              # GitHub.Tracker when tracker.kind == "github", else NullCodeHost
  # + the five functions above, delegating to adapter()
end
```

- `Aiur.Tracker.IssueTracker` carries the remaining callbacks and the same
  `@optional_callbacks` list (`tracker.ex:29-32`).
- `Aiur.Tracker` stays the issue-tracker facade but defines no callbacks. Elixir has no
  behaviour aliasing, so adapters declare `@behaviour Aiur.Tracker.IssueTracker` (and
  GitHub also `@behaviour Aiur.Tracker.CodeHost`). The test at
  `tracker_github_test.exs:51` changes to assert both behaviours.
- `Aiur.Tracker.fetch_classified_pr_review_comments/1` etc. become
  `@deprecated "Use Aiur.CodeHost"` one-line delegates (kept so out-of-tree scripts and
  any missed caller keep working; removed in a follow-up once the final plan refresh MP-R1-C11-T3 shows no caller).
- `NullCodeHost` returns `{:ok, []}` for the three list reads and
  `fetch_open_pull_requests_for_branch/1`, and `{:ok, nil}` for
  `fetch_open_pull_request_for_branch/1` — byte-identical to `memory/tracker.ex:73-85`
  and `linear/tracker.ex:92-104`. Linear and memory then drop their five stub functions.
- `available?/0` replaces `Tracker.adapter() == GitHubTracker` in the four orchestrator
  checks. Truth table at this ticket: `tracker.kind == "github"` ⇔ `available?()`.
- **Invariant:** for every `tracker.kind` value, every caller receives the same value it
  received at base. No call site changes its error handling.

## Implementation steps

1. Add `src/lib/aiur/tracker/issue_tracker.ex` and `src/lib/aiur/tracker/code_host.ex`
   (behaviours), `src/lib/aiur/tracker/null_code_host.ex`, `src/lib/aiur/code_host.ex`.
2. In `tracker.ex`, remove the `@callback` lines (`:8-27`) and `@optional_callbacks`
   (`:29-32`) — they move to `IssueTracker`. Turn `:124-150` into `@deprecated`
   delegates to `Aiur.CodeHost`.
3. `github/tracker.ex:6`: replace `@behaviour Aiur.Tracker` with both new behaviours;
   mark the five code-host functions `@impl Aiur.Tracker.CodeHost`.
4. `memory/tracker.ex`, `linear/tracker.ex`: `@behaviour Aiur.Tracker.IssueTracker`;
   delete the five code-host stubs.
5. Migrate callers: `comment_context.ex:97-100`, `merged_ticket_reconciler.ex:177`,
   `rework_gate.ex:278`, `rework_requeue.ex:146`, `provisioner.ex:108` →
   `Aiur.CodeHost.*`. Keep `comment_context.ex:96` (`fetch_classified_issue_comments`)
   on `Tracker`.
6. Replace the four `Tracker.adapter() == GitHubTracker` checks with
   `Aiur.CodeHost.available?()`; drop the now-unused `GitHubTracker` aliases in
   `human_review.ex`, `pr_health_scanner.ex`, `rework_gate.ex`, `rework_requeue.ex`.
7. Manifest (`components.json`): add `Aiur.CodeHost`, `Aiur.Tracker.IssueTracker`,
   `Aiur.Tracker.CodeHost` to the `tracker` component's facades; regenerate the ratchet
   allowlist; the count must drop (the four orchestrator→`GitHub.Tracker` edges go).

Estimated production change: ~150 lines added, ~80 removed.

## Non-happy paths

- **Out-of-tree adapter:** one that still declares `@behaviour Aiur.Tracker` compiles
  with a warning (`Aiur.Tracker` exists but defines no callbacks) and keeps working,
  because the facade still dispatches by function name. In-tree there are exactly three
  adapters (verified: `git grep '@behaviour Aiur.Tracker$'` → github, linear, memory).
  Whether compile warnings fail CI must be checked at the implementation head
  (`src/Makefile` `lint` target); if they do, that is the desired signal.
- **No code host (Linear, memory):** `available?()` is false; the PR-health scanner,
  rework requeue, rework gate and human-review checks behave as at base (they were
  false because the adapter was not GitHub).
- **Config unreadable:** `Aiur.CodeHost.adapter/0` reads `Config.settings!()` exactly as
  `Tracker.adapter/0` does (`tracker.ex:163`), so it raises in the same situations; no
  new rescue is added (behaviour-preserving).
- **Concurrency/idempotency:** pure delegation; no state.
- **MP-E1 hooks lost in a rebase (RC-19):** the split must not move or wrap
  `add_label`/`remove_label`, and must not touch `github/labels.ex` or
  `github/issues.ex`. If E1's queue source-scan test (MP-E1-C1-T6) exists at the
  implementation head, it must stay green unchanged; a failing scan means this ticket
  moved a seam E1 depends on.

## Compatibility and rollout

- No config change, no migration, no flag. `.aiur/config` `tracker.kind` unchanged.
- Deprecated delegates keep the public `Aiur.Tracker.*` surface for one release.
- Rollback: revert the PR (the manifest and allowlist revert with it).

## Verification

Commands (isolated worktree; never point tests at the live `~/.aiur`):

```bash
env -C src mise exec -- mix test test/aiur/tracker_github_test.exs test/aiur/extensions_test.exs \
  test/aiur/orchestrator/rework_requeue_test.exs test/aiur/agent_runner test/aiur/workspace/provisioner_test.exs
env -C src mise exec -- mix test test/aiur/code_host_test.exs      # new
make -C src fmt-check && make -C src lint
python3 scripts/check-components.py                                # from MP-R1-C1 (PROPOSED)
```

New / changed tests:

1. `code_host_test.exs` — "null code host returns the values linear and memory returned"
   asserts `{:ok, []}` ×4 and `{:ok, nil}` for a memory tracker config. **Mutation:**
   change `NullCodeHost.fetch_open_pull_request_for_branch/1` to return `{:ok, []}`; the
   test must fail.
2. `code_host_test.exs` — "available? is true only for the github tracker kind": memory →
   false, linear → false, github → true. **Mutation:** make `available?/0` return `true`;
   test fails.
3. `tracker_github_test.exs:51` — changed to assert `Aiur.Tracker.IssueTracker` and
   `Aiur.Tracker.CodeHost` are both in `GitHub.Tracker.module_info(:attributes)[:behaviour]`.
   **Mutation:** remove the CodeHost `@behaviour` line; test fails.
4. `extensions_test.exs:365` — extend: `Aiur.Tracker.fetch_open_pull_request_for_branch("1")`
   with a memory config still returns `{:ok, nil}` through the deprecated delegate
   (guard against future regression; passes at base too — say so in the test comment,
   it does not count as coverage of this change).
5. Existing PR-health / rework tests stay green unchanged (behaviour evidence).
6. RC-19 guard: `env -C src mise exec -- mix test test/aiur/github/labels_test.exs
   test/aiur/build_queue` (E1-C1 tests, present after wave 0) pass unchanged, and
   `git diff --stat` shows no change under `src/lib/aiur/github/labels.ex`,
   `github/issues.ex` or `src/lib/aiur/build_queue/`.

Manual: `scripts/aiurdev --test` foreground per AGENTS.md; open one agent chat pane;
confirm the AgentList and chat render as before (no visible change expected).

## Completion and handoff

- [ ] Two behaviours, facade and null code host exist; three adapters declare the right behaviours.
- [ ] No in-tree caller uses `Aiur.Tracker` for the five code-host functions.
- [ ] No `Tracker.adapter() == GitHubTracker` remains (`git grep` empty).
- [ ] Checker violation count lower than before (number in PR body).
- [ ] Mutation results for tests 1–3 named in the PR body.
- **Docs:** none (no config key, CLI flag or behaviour change). `website/docs-app/apis/github.md`
  is not affected.
- **Dependents:** C7-T2 (registration), C7-T6 (github facades), C7-T7/T8 (Dispatcher),
  C9-T5/T6 (`PRHealthScanner`/`ReworkRequeue` move reads `Aiur.CodeHost`).
