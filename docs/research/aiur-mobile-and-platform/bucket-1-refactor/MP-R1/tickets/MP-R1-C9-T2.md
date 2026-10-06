---
ticket_id: MP-R1-C9-T2
feature_id: MP-R1
chunk_id: MP-R1-C9
bucket: 1-refactor
title: Comment poll reads plain inputs and one nested cursor struct instead of Orchestrator.State (in place, no process change)
status: blocked   # research complete; only DESIGN-R1 and named predecessors remain
blocked_by: [DESIGN-R1, MP-R1-C9-T1, MP-R2-C2-T08, MP-E1-C1]
prior_units: [U2, U8]
prior_boundaries: [ING #9, ORC #12]
prior_features: []
prior_findings: [orch-a-26, orch-b-12, events-webhooks-executor-17]
size_owner: LIFECYCLE_DISPATCH (orchestrator/comment_polling.ex, orchestrator/comment_polling/target_selection.ex, orchestrator/state.ex)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C9-T2 — Comment poll on plain inputs (preparation for the comments listener)

## Identity and outcome

- Bucket 1, MP-R1, chunk C9, migration step S15 (first half of the comments move).
- **User value:** none visible. This is the in-place step that lets C9-T3 move the comment
  poll into a listener process as a pure move. Doing it in two PRs keeps each reviewable:
  this one changes signatures, T3 changes the process.
- **Deliverable:**
  1. A struct `Aiur.Orchestrator.CommentPolling.Cursor` (PROPOSED,
     `src/lib/aiur/orchestrator/comment_polling/cursor.ex`) holding the eight
     comment-poll fields that are today top-level `Orchestrator.State` fields.
  2. `Orchestrator.State` gets **one** field `github_comment_cursor: %Cursor{}` in place
     of those eight.
  3. A struct `Aiur.Orchestrator.CommentPolling.Input` (PROPOSED,
     `…/comment_polling/input.ex`) with the four orchestrator facts the poll reads:
     `running_targets`, `running_titles`, `ownership_key`, `next_github_delay_ms`.
  4. `CommentPolling` and `CommentPolling.TargetSelection` take `(Cursor, Input, opts)`
     and return `{Cursor, outcome}`; they no longer pattern-match `%State{}`.
- **Non-goals:** no new process, no timing change, no change to target ordering, caps,
  cadence (`PollCadence.within_class_cadence?/3`) or reconcile scheduling.

## Dependencies and blockers

- DESIGN-R1 §1; **C9-T1** (same file, firehose code already gone); **MP-R2-C2-T08**
  orchestrator batch (same files); **MP-E1-C1** hooks on `main` (RC-19).
- U2 owns the files; no ticket transition changes, so not blocked on RQ-U2-TRANSITION.
- **Concurrent with:** C9-T5, C9-T6, C9-T7, C9-T10–T14. **Not** with C9-T3/T4.

## Verified starting point (45a290e3)

- Comment-poll fields in `orchestrator/state.ex` defstruct: `github_comments_since`
  (`:294`), `github_comment_etags` (`:295`), `github_comment_issue_updated_at` (`:296`),
  `github_comment_issue_list_cache` (`:300`), `github_comment_poll` (`:303`),
  `github_comment_reconcile_targets` (`:306`), `github_comment_reconcile_timer` (`:309`),
  `last_comment_poll_started_at_ms` (`:310`).
- `github_comment_etags` is **shared** with `CommandScan` (`orchestrator/command_scan.ex:67`),
  which uses the keys `:command_scan_review` / `:command_scan_issue` (moduledoc
  `command_scan.ex:9-12`). The comments poller keys it by target. The keys are disjoint, so
  the map can be split: CommandScan keeps its own (moved by C9-T4); the comment cursor
  keeps the target keys. This ticket gives CommandScan a separate field
  `github_command_scan_etags` initialised from today's two atom keys.
- Orchestrator facts the poll reads:
  - `state.running` for the running target list (`target_selection.ex:45,221-226`) and
    titles (`comment_polling.ex` `running_titles_by_target/1`);
  - `state.snapshot_key` as the ownership key of the owned poll
    (`comment_polling.ex:460`);
  - `TrackerHealth.github_next_poll_delay_ms(state)` (`comment_polling.ex:438`,
    `tracker_health.ex:344`) for the reconcile backoff.
- Results the orchestrator keeps: connectivity (`comment_polling.ex` `apply_poll_outcome`
  → `Orchestrator.note_github_connectivity_*`), `pr_review_seen_at` (merged into
  `State.pr_review_seen_at`, read by `comment_wake.ex` and `rework_gate.ex`), and
  PR draft observations folded by `ReadyForReviewTransitions.observe/2`
  (`fold_pr_draft_observations/2`). `pr_review_seen_at` and `pr_ready_ledger` stay on
  `State` (PR lifecycle owns them, see C9-T7 table).
- Callers: `dispatcher.ex:137` (`start_async/1`), `orchestrator.ex:59-63`
  (webhook hint, scheduled reconcile), `:84` (`apply_async_down`), `:202-211` (async
  result/started/guarding), `lifecycle.ex:205` (`terminate_poll`).
- Tests touching these fields: `comment_polling_test.exs`,
  `comment_polling/target_selection_test.exs`, `comment_polling/reconcile_test.exs`,
  `regression/orchestrator_blocking_http_test.exs`, `events/github_webhook_equivalence_test.exs`,
  plus `%State{github_comments_since: …, github_comment_issue_updated_at: …}` literals in
  `blocker_merge_wake_test.exs`, `command_scan_test.exs`, `comment_rework_active_entry_test.exs`,
  `comment_wake_test.exs`, `pr_anchored_test.exs`, `push_routing_test.exs`,
  `rework_review_transition_test.exs`, `orchestrator_deactivate_test.exs`,
  `orchestrator_status_test.exs` (all `src/test/aiur/`).

## Chosen design

```elixir
defmodule Aiur.Orchestrator.CommentPolling.Cursor do
  defstruct since: nil, etags: %{}, issue_updated_at: %{}, issue_list_cache: %{},
            poll: nil, reconcile_targets: MapSet.new(), reconcile_timer: nil,
            last_started_at_ms: nil
end

defmodule Aiur.Orchestrator.CommentPolling.Input do
  @enforce_keys [:running_targets, :running_titles, :ownership_key, :next_github_delay_ms]
  defstruct @enforce_keys
end
```

- `CommentPolling.input(%State{})` (the only function in the module that still takes a
  `State`) builds `Input` from `state.running`, `state.snapshot_key` and
  `TrackerHealth.github_next_poll_delay_ms/1`.
- Each public function becomes `f(%Cursor{}, %Input{}, opts) :: {%Cursor{}, outcome}` where
  `outcome :: %{connectivity: [...], pr_review_seen_at: map(), pr_draft_observations: list()}`.
  A thin wrapper in the orchestrator (`Orchestrator.CommentPollingState`, PROPOSED, ≤ 80
  lines) applies `outcome` to `State` with the same function calls in the same order as
  today. That wrapper is what C9-T3 later replaces with a message handler.
- The orchestrator still owns the owned-poll protocol messages in this ticket (process
  shape unchanged).

**Invariants:** identical target list and order for the same inputs (fixture-checked);
identical outcome folding order; the eight fields exist exactly once (inside `Cursor`).

## Implementation steps

1. Add `cursor.ex` and `input.ex`.
2. Change `State`: replace the eight fields with `github_comment_cursor: %Cursor{}`; add
   `github_command_scan_etags: %{}`; `CommandScan` reads/writes that field instead of
   `github_comment_etags[:command_scan_*]` (`command_scan.ex:67` and its writer).
3. Rewrite `target_selection.ex` heads from `%State{…}` to `(%Cursor{}, %Input{})`
   (≈25 heads; bodies unchanged). Split the file while touching it so neither half exceeds
   500 lines: human-review discovery (`:234-465`) to
   `comment_polling/target_selection/human_review.ex` (PROPOSED).
4. Rewrite `comment_polling.ex` likewise; move the owned-poll protocol (`:616-830`) to
   `comment_polling/owned_poll.ex` (PROPOSED) unchanged, which also brings
   `comment_polling.ex` under 500 lines (U8 LIFECYCLE_DISPATCH row).
5. Update the callers listed above to go through the wrapper.
6. Update the test literals (mechanical: nest the fields under `github_comment_cursor`).

Estimated: ≈180 changed lines, ≈420 moved lines.

## Non-happy paths

Unchanged by construction: abandoned poll (`prepare_comment_poll_start/2`), stale refs
(`apply_async/3` second clause), reconcile retry, owner exit. The tests below pin them.
Concurrency: single process as today. Privacy: no new data crosses any boundary.

## Compatibility and rollout

No config, flag, API or on-disk change. Revert-only rollback.

## Verification

```bash
env -C <checkout>/src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/orchestrator/comment_polling_test.exs \
  test/aiur/orchestrator/comment_polling/target_selection_test.exs \
  test/aiur/orchestrator/comment_polling/reconcile_test.exs \
  test/aiur/orchestrator/command_scan_test.exs \
  test/aiur/regression/orchestrator_blocking_http_test.exs \
  test/aiur/events/github_webhook_equivalence_test.exs
python3 scripts/check-components.py
```

New tests:

| Test | Expectation | Fails without |
|---|---|---|
| `target_selection_test "targets depend only on Cursor and Input"` | the same `Cursor`+`Input` gives the same ordered list as the base-SHA fixture `%State{}` (fixture copied from the existing ordering test) | the `Input.running_targets` plumbing (revert to `[]` and the running targets disappear) |
| `command_scan_test "command scan validators live in github_command_scan_etags"` | after a scan with ETags, `state.github_command_scan_etags` has both stream keys and `state.github_comment_cursor.etags` has none | the field split in `command_scan.ex` |
| `comment_polling_test "outcome folds connectivity then review-seen then draft observations"` | stub observers record call order | the wrapper's fold order |

Existing tests must pass with only the literal-shape edit; no assertion content changes.
Mutation procedure as AGENTS.md (separate worktree, clean `git status --porcelain`).
Manual: the AGENTS.md wrapper-tmux `--test` run; leave a trusted review comment on a
sandbox PR and see the incoming comment row in the agent's chat pane.

## Completion and handoff

- [ ] `Orchestrator.State` has `github_comment_cursor` and `github_command_scan_etags`;
      the eight old fields are gone.
- [ ] No touched file exceeds 500 lines; `comment_polling.ex` shrinks below 500.
- [ ] MP-E1-C1 hooks untouched.
- Docs: none (internal).
- Dependents: C9-T3 (process move), C9-T4 (CommandScan listener), C9-T7 (owner table).
  size_owner re-resolved at ticket start (RC-23, MP-R1-C11-T2).
