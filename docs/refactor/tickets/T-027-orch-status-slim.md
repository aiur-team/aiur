# T-027: orchestrator wave 6: status, teardown, watchdog; slim parent

**Phase:** 3
**Depends-on:** T-026
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3`

## Problem / context

`src/lib/aiur/orchestrator.ex` is a 7,617-line GenServer (774 def/defp clauses)
being decomposed into ~26 focused modules under `src/lib/aiur/orchestrator/`
per the binding name map in
`docs/refactor/research-arch/giant-orchestrator.md` §2. This is the **sixth and
final** orchestrator wave (T-022..T-027). Waves T-022..T-026 already extracted
21 modules (`State`, `EventTopics`, `DispatchPolicy`, `Slots`, `Dispatcher`,
`RetryEngine`, `Reconciler`, `CommentWake`, `PrAnchored`, `PushRouting`,
`CommentPolling`, `CommandScan`, `IssueSync`, `AutoSubscriptions`,
`TrackerHealth`, `OperatorMessages`, `DigestCoalescer`, `PauseResume`,
`Interrupts`, `RemoteControlMode`, `TokenAccounting`). This ticket extracts the
last five — `Aiur.Orchestrator.StatusReport`,
`Aiur.Orchestrator.WorkspaceCleanup`, `Aiur.Orchestrator.HumanReview`,
`Aiur.Orchestrator.AgentTeardown`, `Aiur.Orchestrator.RuntimeWatchdog` — and
then slims `orchestrator.ex` down to a thin GenServer facade: `init/1`,
`terminate/2`, the `handle_info`/`handle_call`/`handle_cast` clause heads that
delegate, the public client API, the `*_for_test` seams, tick scheduling, and
tracked-set sync (`issue_tracked?/1` + `refresh_tracked_set/1` stay — the
Publisher-closure contract).

Two of these five are top regression zones in
`docs/refactor/research-history-hotspots.md`: `AgentTeardown` carries the
SSE-stream-close-before-brutal-kill ordering (#613-class chat-pane duplication)
and `RuntimeWatchdog` carries the max-agent-duration bound (#420-class runtime
credit leak). This is a verbatim code **MOVE, not a rewrite**: every function
body is copied byte-for-byte (comments included), public signatures and
observable behavior are unchanged, and all moved code keeps executing as plain
function calls inside the orchestrator GenServer process — no new processes, no
GenServer calls back into the orchestrator (that deadlocks; see the
`issue_tracked?/1` comment).

## Scope (exact)

Line numbers below are from the current `main` snapshot of
`src/lib/aiur/orchestrator.ex` (7,617 lines). Waves T-022..T-026 will have
shifted them and moved many helper targets out of the facade: locate every
function by its exact **name/arity** (each is unique in the file); use line
numbers only as orientation.

1. **Precondition check.** Verify all 21 prior-wave module files exist under
   `src/lib/aiur/orchestrator/`:
   `state.ex`, `event_topics.ex`, `dispatch_policy.ex`, `slots.ex`,
   `dispatcher.ex`, `retry_engine.ex`, `reconciler.ex`, `comment_wake.ex`,
   `pr_anchored.ex`, `push_routing.ex`, `comment_polling.ex`, `command_scan.ex`,
   `issue_sync.ex`, `auto_subscriptions.ex`, `tracker_health.ex`,
   `operator_messages.ex`, `digest_coalescer.ex`, `pause_resume.ex`,
   `interrupts.ex`, `remote_control_mode.ex`, `token_accounting.ex`.
   Run `ls src/lib/aiur/orchestrator/`. If any is missing, STOP: comment the
   blocker on the issue and end your turn. Do not start extraction.

2. **Create `src/lib/aiur/orchestrator/workspace_cleanup.ex`** defining
   `defmodule Aiur.Orchestrator.WorkspaceCleanup`. Move these functions
   VERBATIM (bodies byte-identical, comments included) out of
   `src/lib/aiur/orchestrator.ex`. Extract this module FIRST — `AgentTeardown`
   (step 5) depends on it.

   Public (`def` + `@spec`; called by code that remains in `orchestrator.ex` or
   by already-extracted sibling modules):
   - `cleanup_issue_workspace/1` `/2` (was ~4163; KEEP the
     `worker_host \\ nil` default-arg head)
   - `cleanup_terminal_issue_artifacts/1` `/2` (was ~4169; KEEP the default-arg
     head)
   - `run_startup_todo_workspace_cleanup/1` (was ~4179)
   - `run_terminal_workspace_cleanup/1` (was ~4227)

   Private (`defp`):
   - `clear_session_handle/1` (both clauses, was ~4176)
   - `cleanup_todo_workspaces_after_preflight/1` (was ~4196)
   - `configured_todo_states/0` (was ~4212)
   - `todo_issue_for_startup_cleanup?/1` (both clauses, was ~4221)
   - `ensure_terminal_workspace_cleanup_preflight/1` (was ~4244)
   - `cleanup_terminal_workspaces_after_preflight/1` (was ~4255)
   - `log_terminal_workspace_cleanup_fetch_skip/1` (all four clauses, was ~4270)
   - `cleanup_terminal_issue_workspace/1` (both clauses, was ~4287)
   - `cleanup_issue_workspace_for_issue/1` (both clauses, was ~4293)

3. **Create `src/lib/aiur/orchestrator/status_report.ex`** defining
   `defmodule Aiur.Orchestrator.StatusReport`. Move VERBATIM:

   Public (`def` + `@spec`):
   - `notify_dashboard/1` (was ~4299)
   - `agent_statuses/1` (was ~4411)
   - `running_summaries/1` (was ~4313)
   - `next_poll_in_ms/2` (both clauses, was ~4861/6861)

   Private (`defp`):
   - `entry_backend/1` (was ~4387)
   - `entry_model/1` (was ~4398)
   - `issue_complexity/1` (both clauses, was ~4408)
   - `running_statuses/2` (was ~4421)
   - `running_status/4` (was ~4427)
   - `idle_statuses/2` (was ~4453)
   - `running_issue?/2` (was ~4460)
   - `idle_status/2` (was ~4465)
   - `idle_queue_depth/2` (both clauses, was ~4488)

4. **Create `src/lib/aiur/orchestrator/human_review.ex`** defining
   `defmodule Aiur.Orchestrator.HumanReview`. Move VERBATIM:

   Public (`def` + `@spec`):
   - `human_review_state?/1` (both clauses, was ~2697)
   - `maybe_deactivate_human_review_issue/2` (was ~2703)

   Private (`defp`):
   - `verify_human_review_ready/1` (both clauses, was ~2717)
   - `transient_human_review_verification_error?/1` (all clauses, was ~2729)
   - `transient_github_graphql_error?/1` (both clauses, was ~2743)
   - `github_graphql_error_values/1` (was ~2751)
   - `transient_github_graphql_error_value?/1` (all clauses, was ~2762)
   - `defer_human_review_transition/3` (was ~2770)
   - `verify_human_review_ready_with_tracker/1` (was ~2776)
   - `reject_human_review_transition/3` (was ~2790)
   - `github_client_module/0` (was ~2806)

   Move the `@transient_github_graphql_error_types` module attribute (was
   ~73; its ONLY consumer is `transient_github_graphql_error_value?/1`) from
   `orchestrator.ex` into `human_review.ex`, and delete it from
   `orchestrator.ex`.

5. **Create `src/lib/aiur/orchestrator/agent_teardown.ex`** defining
   `defmodule Aiur.Orchestrator.AgentTeardown`. Move VERBATIM:

   Public (`def` + `@spec`):
   - `terminate_running_issue/3` (was ~2897; move the two load-bearing
     ordering comments inside it untouched)
   - `deactivate_running_issue/2` (was ~2954; move its comment block untouched)
   - `kill_repl_session/1` (was ~6699)

   Private (`defp`):
   - `close_active_chat_streams/2` (both clauses + the preceding
     load-bearing comment block, was ~2810/2817)
   - `terminate_reason/1` (both clauses, was ~2828)
   - `terminate_task/1` (both clauses, was ~3260)

6. **Create `src/lib/aiur/orchestrator/runtime_watchdog.ex`** defining
   `defmodule Aiur.Orchestrator.RuntimeWatchdog`. Move VERBATIM:

   Public (`def` + `@spec`; the two `entry?` predicates are ALREADY
   `@doc false def` with `@spec` — an existing test calls
   `Orchestrator.overrunning_entry?/3` (see Characterization-tests). Move them
   whole AND keep a facade wrapper for `overrunning_entry?/3` per step 8):
   - `reconcile_overrunning_agents/1` (was ~3076)
   - `overrunning_entry?/3` (was ~3102; keep its `@spec` + comment)
   - `reconcile_stalled_running_issues/1` (was ~3131)
   - `restart_stalled_issue/5` (was ~3150; move its comment blocks untouched)
   - `wedged_overcap_entry?/3` (both clauses, was ~3196; keep `@spec` +
     comment)

   Private (`defp`):
   - `maybe_pause_overrunning_entry/5` (was ~3115; move its comment untouched)
   - `terminate_wedged_overcap_entry/4` (was ~3213)
   - `maybe_restart_stalled_entry/5` (was ~3222)
   - `stall_elapsed_ms/2` (was ~3244)
   - `last_activity_timestamp/1` (was ~3256)

7. **Module heads.** Each new module gets: a `@moduledoc` (2-4 lines stating
   its one-sentence responsibility from the name map, plus "All functions
   execute inside the orchestrator GenServer process."), the aliases/`require`
   it needs copied from `orchestrator.ex`'s head (only the ones its moved code
   references — `mix compile --warnings-as-errors` flags unused ones; expect
   e.g. `alias Aiur.Orchestrator.State`, `alias Aiur.Issue`,
   `alias Aiur.Tracker`, `alias Aiur.Config`, `require Logger`, and for the
   sibling and facade calls in step 8), and `@spec` on every public `def`
   (`mix credo --strict` runs `specs.check`, which enforces this).

8. **Rewrite intra-move references (no logic changes).** Inside the moved
   bodies, qualify calls whose targets now live elsewhere. Each target below
   was extracted by an earlier wave — confirm its home with
   `grep -rn "def <name>" src/lib/aiur/orchestrator/` and call it there. If a
   listed target is (unexpectedly) still a `defp` in the facade, treat it as a
   facade resident (last bullet). If a needed target exists ONLY as a private
   `defp` inside another module (you cannot reach it and cannot edit that
   module), STOP and comment the blocker.

   - **State (T-022):** `issue_context/1`, `issue_tag/1`, `running_seconds/2`,
     `effective_runtime_seconds/2`, `running_entry_session_id/1`,
     `paused_running_entry?/1`, `deactivated_running_entry?/1` →
     `State.<name>(...)`.
   - **DispatchPolicy (T-022):** `normalize_issue_state/1`, `state_slug/1` →
     `DispatchPolicy.<name>(...)`.
   - **Slots (T-022):** `max_concurrent_agent_limit/1` →
     `Slots.max_concurrent_agent_limit(...)`.
   - **RetryEngine (T-023):** `release_issue_claim/2`, `schedule_issue_retry/4`,
     `next_retry_attempt_from_running/1`, `format_retry_preflight_error/1` →
     `RetryEngine.<name>(...)`. (NOTE: T-023 moved `format_retry_preflight_error/1`
     into `RetryEngine` believing `handle_retry_issue/4` was its sole consumer;
     the two `run_*_workspace_cleanup/1` functions you are moving in step 2 ALSO
     call it. Grep its real home; if it is a facade `@doc false def` delegating
     to RetryEngine, call `Orchestrator.format_retry_preflight_error/1` instead.
     Do not duplicate the function.)
   - **Reconciler (T-023):** `maybe_reactivate_or_refresh/2` →
     `Reconciler.maybe_reactivate_or_refresh(...)`.
   - **CommentWake (T-024):** `transition_control_status/4` →
     `CommentWake.transition_control_status(...)`.
   - **TrackerHealth (T-025):** `ensure_tracker_preflight/1` →
     `TrackerHealth.ensure_tracker_preflight(...)`.
   - **OperatorMessages (T-025):** `queue_depth_for_issue/2` →
     `OperatorMessages.queue_depth_for_issue(...)`.
   - **PauseResume (T-026):** `send_pause_control_message/2` →
     `PauseResume.send_pause_control_message(...)`.
   - **TokenAccounting (T-026):** `record_session_completion_totals/2` →
     `TokenAccounting.record_session_completion_totals(...)`.
   - **RemoteControlMode (T-026):** `remote_control_summary/1` →
     `RemoteControlMode.remote_control_summary(...)`.
   - **Facade residents (stay in `orchestrator.ex`):** `refresh_tracked_set/1`
     (called by `AgentTeardown.deactivate_running_issue/2`) →
     `Orchestrator.refresh_tracked_set/1` (add `alias Aiur.Orchestrator` in
     `agent_teardown.ex`). `refresh_tracked_set/1` is currently a `defp`; flip
     it to `@doc false def` with a `@spec` in the facade so the sibling can call
     it (this is the ONLY facade-body edit outside the delete/wrapper mechanics
     of step 9).
   - **Cross-references between the five NEW modules** stay module-qualified:
     `HumanReview.maybe_deactivate_human_review_issue/2` calls
     `AgentTeardown.deactivate_running_issue/2`;
     `AgentTeardown.terminate_running_issue/3` calls
     `WorkspaceCleanup.cleanup_terminal_issue_artifacts/2`;
     `RuntimeWatchdog.restart_stalled_issue/5` and
     `RuntimeWatchdog.terminate_wedged_overcap_entry/4` call
     `AgentTeardown.terminate_running_issue/3`.
   - Do NOT change `self()`, `Process.send_after/3`, `Process.cancel_timer/1`,
     `Process.monitor/1`, `Process.demonitor(ref, [:flush])`,
     `Task.Supervisor.terminate_child/2`, or `Process.exit(pid, :kill)` sites in
     any way — the moved code runs inside the orchestrator process and the
     brutal-kill / demonitor-flush semantics depend on it.

9. **In `src/lib/aiur/orchestrator.ex`:** delete every moved definition, then
   add a one-line delegating wrapper — identical head (same name, arity,
   guards, default args) — ONLY for the moved functions that code remaining in
   the facade (its `handle_info`/`handle_call`/`handle_cast` clauses,
   `init/1`, `terminate/2`, the `*_for_test` seams) OR an already-extracted
   sibling still calls via `Orchestrator.<name>`. Keep each wrapper's
   visibility matching who calls it: `@doc false def` (+ `@spec`) when a sibling
   module or an existing test calls it through `Orchestrator.`; plain `defp`
   when only facade-internal code calls it. Exact wrapper list (delegating to
   the named module), each verified by grep before you finalize:

   - → `StatusReport` (facade-internal callers only → `defp`):
     `notify_dashboard/1` (many `handle_info`/`handle_call` sites),
     `agent_statuses/1` (`handle_call(:status, …)`),
     `next_poll_in_ms/2` (`handle_call(:status/:poll_status, …)`)
   - → `WorkspaceCleanup`:
     `run_terminal_workspace_cleanup/1` (`init/1` + `_for_test` seam),
     `run_startup_todo_workspace_cleanup/1` (`init/1` + `_for_test` seam),
     `cleanup_terminal_issue_artifacts/1..2` (keep default-arg head; called by
     `RetryEngine` sibling → `@doc false def`)
   - → `HumanReview` (called by `Reconciler` sibling → `@doc false def`):
     `maybe_deactivate_human_review_issue/2`, `human_review_state?/1`
   - → `AgentTeardown`:
     `terminate_running_issue/3` (called by `Reconciler`, `RetryEngine`,
     `CommentWake`, `PrAnchored`, `RuntimeWatchdog` siblings + the
     `terminate_running_issue_for_test/3` seam → `@doc false def`),
     `kill_repl_session/1` (called by `terminate/2` + `RemoteControlMode`
     sibling → `@doc false def`)
   - → `RuntimeWatchdog`:
     `reconcile_overrunning_agents/1`, `reconcile_stalled_running_issues/1`
     (called by `Reconciler` sibling → `@doc false def`);
     `overrunning_entry?/3` (an existing test calls
     `Orchestrator.overrunning_entry?/3` → `@doc false def` + `@spec`);
     `restart_stalled_issue/5` (called by the `apply_stall_check_for_test/2`
     seam → `defp`);
     `maybe_pause_overrunning_entry/5` (called by the
     `apply_overrun_check_for_test/2` seam → `defp`)

   `deactivate_running_issue/2` is called ONLY by
   `HumanReview.maybe_deactivate_human_review_issue/2` (a sibling this wave):
   it needs NO facade wrapper — grep the facade after deletion to confirm no
   remaining caller; add a wrapper only if grep finds one.

   Do NOT edit the bodies of any `handle_info`/`handle_call`/`handle_cast`
   clause, `init/1`, `terminate/2`, or any `*_for_test` function — the wrappers
   keep every existing call site compiling unchanged. The only permitted facade
   body edit is the `refresh_tracked_set/1` visibility flip in step 8.

10. **Write the five test files** (new modules are NOT coverage-exempt; the 85%
    threshold plus this ticket's review enforce real tests). Build
    `%Aiur.Orchestrator.State{}` structs directly (all fields default) and
    running-entry maps by hand; test only through each module's public
    functions; no GenServer needed. Set app-env stubs where the code reads them
    (`:human_review_ready_verifier`, `:github_client_module`) and reset them in
    `on_exit`.
    - `src/test/aiur/orchestrator/workspace_cleanup_test.exs`:
      `cleanup_terminal_issue_artifacts/2` on a binary identifier removes the
      workspace and clears the session handle (assert via a stub/observed
      effect); `configured_todo_states/0` returns the tracker's `todo`-slug
      active states, falling back to `["todo"]` when none match;
      `todo_issue_for_startup_cleanup?/1` is true for a `todo`-slug `%Issue{}`
      and false otherwise.
    - `src/test/aiur/orchestrator/status_report_test.exs`:
      `agent_statuses/1` on an empty state returns `[]`; with one running and
      one idle polled issue it returns both rows sorted by identifier, the
      running row's `state` is `:running` (`:paused` when
      `control.status == :paused`) and the idle row's `state` is `:idle`;
      `next_poll_in_ms/2` returns `nil` for a `nil` due-time and
      `max(0, due - now)` otherwise.
    - `src/test/aiur/orchestrator/human_review_test.exs`:
      `human_review_state?/1` is true for `"human-review"` (and its label
      variants via `DispatchPolicy.normalize_issue_state/1`) and false
      otherwise; `transient_human_review_verification_error?/1` is true for
      `{:github, :timeout, _}`, `{:github_api_status, 503}`,
      `{:github_api_status, 429}` and false for `{:github_api_status, 404}`;
      `maybe_deactivate_human_review_issue/2` with the
      `:human_review_ready_verifier` app-env stubbed to return `:ok`
      deactivates the running entry (frees the slot, keeps the row) and with a
      transient error DEFERS (returns state unchanged).
    - `src/test/aiur/orchestrator/agent_teardown_test.exs`:
      `terminate_running_issue/3` on an unknown id releases the claim and
      returns otherwise-unchanged state; on a known id with `pid: nil, ref: nil`
      it removes the entry from `running`, `claimed`, and `retry_attempts`;
      `terminate_reason/1` maps `true → :terminal`, `false → :replaced`;
      `close_active_chat_streams/2` is a no-op for a non-binary identifier.
      (Exercise only `pid: nil`/`ref: nil` entries so no real task/pane kill is
      attempted.)
    - `src/test/aiur/orchestrator/runtime_watchdog_test.exs`:
      `overrunning_entry?/3` is true for a `started_at` older than
      `max_seconds`, false for a recent one, and false for a
      paused/deactivated entry; `wedged_overcap_entry?/3` is true only for a
      `:max_agent_duration`-paused entry whose `last_codex_timestamp` is newer
      than `paused_at` beyond `timeout_ms`, false otherwise;
      `reconcile_stalled_running_issues/1` and `reconcile_overrunning_agents/1`
      return the state unchanged when their config threshold is `<= 0` and when
      `running` is empty.

11. **Do not modify** `src/mix.exs` (the five new modules must NOT be added to
    `ignore_modules`; and see the note below on why `Aiur.Orchestrator` STAYS
    exempt), any existing test file, `src/lib/aiur/orchestrator/tracked_set.ex`,
    or the 21 prior-wave modules. After steps 2-10 the repo compiles
    warnings-free and the FULL suite passes (run the Agent gate below).

    **ignore_modules decision (leave untouched — do not edit `mix.exs`):** the
    slimmed `Aiur.Orchestrator` facade remains a defensive-branch GenServer
    (`init`/`terminate`/`handle_*` clause heads, public client API degrading to
    `:unavailable`, `*_for_test` seams) whose rescue/dead-pid/timeout clauses do
    not translate to unit coverage — the same rationale the existing `mix.exs`
    comment gives for keeping it exempt. Proving the facade meets the 85%
    line-coverage floor on its own is NOT part of this behavior-preserving
    move, so `Aiur.Orchestrator` and `Aiur.Orchestrator.State` STAY in
    `ignore_modules`. The coverage win of this wave is that the five NEW modules
    are fully covered by their own test files and are never added to the exempt
    list.

## Files

- Create:
  `src/lib/aiur/orchestrator/status_report.ex`,
  `src/lib/aiur/orchestrator/workspace_cleanup.ex`,
  `src/lib/aiur/orchestrator/human_review.ex`,
  `src/lib/aiur/orchestrator/agent_teardown.ex`,
  `src/lib/aiur/orchestrator/runtime_watchdog.ex`,
  `src/test/aiur/orchestrator/status_report_test.exs`,
  `src/test/aiur/orchestrator/workspace_cleanup_test.exs`,
  `src/test/aiur/orchestrator/human_review_test.exs`,
  `src/test/aiur/orchestrator/agent_teardown_test.exs`,
  `src/test/aiur/orchestrator/runtime_watchdog_test.exs`
- Modify: `src/lib/aiur/orchestrator.ex`
- Test: the five new test files above; the entire existing suite must pass
  unmodified.

## Out of scope

- The 21 prior-wave modules under `src/lib/aiur/orchestrator/` — call them,
  never edit them. `src/lib/aiur/orchestrator/tracked_set.ex` — untouched.
- The optional seam-collapse cleanup (research doc W29): do NOT rewrite the
  `*_for_test` seams to call the new modules directly, do NOT move or split
  test files, do NOT collapse the wrappers. The seams and their bodies stay
  exactly as they are; the wrappers keep them compiling.
- `src/mix.exs` — untouched (no new coverage exemptions, no removal of
  `Aiur.Orchestrator`/`Aiur.Orchestrator.State` from `ignore_modules`, no dep
  changes). See step 11.
- `src/lib/aiur/agent_runner.ex`, `src/lib/aiur/tracker.ex`,
  `src/lib/aiur/workspace.ex`, `src/lib/aiur/remote_control.ex`,
  `src/lib/aiur/tmux.ex`, `src/lib/aiur/coding_agent.ex` — untouched.
- Every existing test file, including all `*_for_test` seam call sites and
  `test/aiur/orchestrator_max_duration_test.exs`'s direct
  `Orchestrator.overrunning_entry?/3` calls — test moves/renames are a later
  cleanup wave (research doc W29), not this ticket.
- Any behavior change: no renamed functions, no reordered clauses, no changed
  log strings / alert topics / delays / limits, no "improvements" to moved
  code. The SSE-stream-close-before-kill ordering
  (`close_active_chat_streams/2` before `terminate_task/1`), the
  `kill_repl_session/1`-before-task-death ordering, the
  `refresh_tracked_set/1`-after-deactivation call, the `[:flush]` demonitor, the
  `drain: false` reaping in `terminate/2`, and the duration-clock semantics
  (`overrunning_entry?/3` excluding paused/deactivated entries;
  `wedged_overcap_entry?/3` as the sole duration-cap kill path) MUST survive
  byte-for-byte.
- `handle_info`/`handle_call`/`handle_cast` clause bodies, `init/1`,
  `terminate/2` bodies, tick scheduling, tracked-set sync (`issue_tracked?/1`
  stays in the facade — Publisher closure contract; `refresh_tracked_set/1`
  stays too, only its visibility flips per step 8).

## Inventory-IDs

From `docs/refactor/feature-inventory/orc.md` — this ticket's Files implement or
touch these entries; their behavior must be byte-for-byte preserved:

- **FI-ORC-003** — startup terminal-workspace cleanup (workspaces removed +
  SessionHandles cleared; Linear-credential skip is quiet). → `WorkspaceCleanup`.
- **FI-ORC-004** — startup todo-workspace cleanup (workspaces removed, session
  handles NOT cleared; `configured_todo_states/0` fallback to `["todo"]`). →
  `WorkspaceCleanup`.
- **FI-ORC-005** — shutdown reaping / `kill_repl_session` (pane + subtree reap
  so headless grandchildren cannot survive). → `AgentTeardown` (the
  `terminate/2` body stays in the facade and calls the `kill_repl_session/1`
  wrapper).
- **FI-ORC-026** — human-review deactivation with readiness verification
  (transient-error DEFER vs non-transient revert-to-rework; deactivation frees
  the slot, keeps the row, drops the id from the tracked set). →
  `HumanReview` + `AgentTeardown.deactivate_running_issue/2`.
- **FI-ORC-027** — chat-stream closure BEFORE any brutal kill
  (`close_active_chat_streams/2` runs before `terminate_task/1` in
  `terminate_running_issue/3` and `deactivate_running_issue/2`). →
  `AgentTeardown`.
- **FI-ORC-028** — `terminate_running_issue/3` teardown semantics (completion
  totals, `kill_repl_session`, optional workspace/session cleanup, stream
  close, task kill, `[:flush]` demonitor, entry/claim/retry removal, unknown-id
  claim release). → `AgentTeardown`.
- **FI-ORC-029** — stall watchdog restart with backoff (paused/deactivated
  entries skipped; disabled at timeout `<= 0`; restart schedules a failure
  retry at the next attempt). → `RuntimeWatchdog`.
- **FI-ORC-031** — max-agent-duration cap pauses (never kills):
  `overrunning_entry?/3` excludes paused/deactivated; a cooperative
  `{:pause_agent}` + flip to `:paused` with `paused_reason :max_agent_duration`.
  → `RuntimeWatchdog`.
- **FI-ORC-032** — wedged over-cap escalation (the ONLY kill path for the
  duration cap): a `:max_agent_duration`-paused entry that kept streaming codex
  past the grace window is force-terminated. → `RuntimeWatchdog`.
- **FI-ORC-060** — dashboard broadcasts and status/snapshot surfaces
  (`notify_dashboard/1`, `running_summaries/1`, `agent_statuses/1` with
  running+paused+idle rows sorted by identifier, backend/model labels, the
  mid-dispatch-race `extra_running` branch). → `StatusReport`.
- **FI-ORC-001** — poll tick loop (the `notify_dashboard/1` broadcast the tick
  fires now delegates to `StatusReport`; tick scheduling stays in the facade).

## Characterization-tests

All of `src/test/aiur/regression/` must pass UNMODIFIED. Specifically the
orchestrator characterization files landed by T-007 (Characterization:
orchestrator lifecycle & dispatch gates) and T-009 (engine identity, reap &
control RPC), which per `research-arch/giant-orchestrator.md` §4 pin exactly
this wave's semantics: the SSE-stream-close-before-brutal-kill ordering, the
`kill_repl_session` pane/subtree reap, the human-review verify-before-deactivate
gate, the max-duration overrun pause + clock arithmetic, the wedged-overcap kill
path, and the startup workspace-cleanup ordering. List them at execution time
with `ls src/test/aiur/regression/ | grep -iE 'orch|shutdown|cleanup'` (they
merge in Phase 1, before this ticket opens; `shutdown_cleanup_test.exs` already
exists) and run them explicitly before opening the PR.

These existing (non-regression-dir) pins must also pass unmodified — they
exercise the moved code through the `*_for_test` seams, `handle_info` sends, and
direct public calls, which is why the seams and wrappers must keep identical
signatures and visibility:
`src/test/aiur/orchestrator_deactivate_test.exs` (reconcile / deactivate /
human-review / teardown / queue),
`src/test/aiur/orchestrator_status_test.exs` (snapshot / status / dashboard),
`src/test/aiur/orchestrator_max_duration_test.exs` (overrun + clocks + the
direct `Orchestrator.overrunning_entry?/3` calls),
`src/test/aiur/core_test.exs`.

## Acceptance criteria

All greps run from the repo root; all must hold:

- Exactly one `defmodule` per new file:
  `grep -c "defmodule Aiur.Orchestrator.StatusReport do" src/lib/aiur/orchestrator/status_report.ex` = 1;
  `grep -c "defmodule Aiur.Orchestrator.WorkspaceCleanup do" src/lib/aiur/orchestrator/workspace_cleanup.ex` = 1;
  `grep -c "defmodule Aiur.Orchestrator.HumanReview do" src/lib/aiur/orchestrator/human_review.ex` = 1;
  `grep -c "defmodule Aiur.Orchestrator.AgentTeardown do" src/lib/aiur/orchestrator/agent_teardown.ex` = 1;
  `grep -c "defmodule Aiur.Orchestrator.RuntimeWatchdog do" src/lib/aiur/orchestrator/runtime_watchdog.ex` = 1.
- `grep -c "@moduledoc" <file>` >= 1 for each of the five new modules.
- **Slimmed-facade line ceiling:** `wc -l < src/lib/aiur/orchestrator.ex` <= 750.
  (The research doc §2 states the residual facade is ~550-700 lines — `init`/
  `terminate`, the delegating `handle_*` clause heads, the public client API,
  and the `*_for_test` seams all stay by design; the accumulated 1-line wrappers
  add the rest. This is the doc-grounded hard ceiling; the ticket-spec's
  aspirational "<=400" is not reachable this wave because the public client API
  alone (~620 lines) and the `*_for_test` seams (~230 lines) remain — collapsing
  the seams is the separate optional W29 cleanup, out of scope here.)
- New-file size caps (these carry the research doc's documented exception to the
  200-line file norm — they are cohesive state machines / status builders moved
  verbatim, and splitting them would break the byte-for-byte-move requirement):
  `wc -l < src/lib/aiur/orchestrator/status_report.ex` <= 420;
  `wc -l < src/lib/aiur/orchestrator/workspace_cleanup.ex` <= 210;
  `wc -l < src/lib/aiur/orchestrator/human_review.ex` <= 240;
  `wc -l < src/lib/aiur/orchestrator/agent_teardown.ex` <= 260;
  `wc -l < src/lib/aiur/orchestrator/runtime_watchdog.ex` <= 270.
- Moved functions are moved, not rewritten: no NEW function body may exceed 20
  logic lines (wrappers are 1 line); moved bodies are byte-identical (verified
  at-merge via `--color-moved`).
- The GraphQL-error attribute left the facade:
  `grep -c "@transient_github_graphql_error_types" src/lib/aiur/orchestrator.ex` = 0,
  and it appears exactly once in
  `src/lib/aiur/orchestrator/human_review.ex`.
- No unwrapped moved definition remains in the facade (wrapped names keep a
  1-line `def`/`defp`; the rest must be gone entirely). Each grep = 0:
  `grep -cE "^  defp (running_summaries|running_statuses|running_status|idle_statuses|idle_status|idle_queue_depth|running_issue\?|entry_backend|entry_model|issue_complexity)\(" src/lib/aiur/orchestrator.ex`;
  `grep -cE "^  defp (clear_session_handle|cleanup_todo_workspaces_after_preflight|configured_todo_states|todo_issue_for_startup_cleanup\?|ensure_terminal_workspace_cleanup_preflight|cleanup_terminal_workspaces_after_preflight|log_terminal_workspace_cleanup_fetch_skip|cleanup_terminal_issue_workspace|cleanup_issue_workspace_for_issue|cleanup_issue_workspace)\(" src/lib/aiur/orchestrator.ex`;
  `grep -cE "^  defp (verify_human_review_ready|verify_human_review_ready_with_tracker|transient_human_review_verification_error\?|transient_github_graphql_error\?|transient_github_graphql_error_value\?|github_graphql_error_values|defer_human_review_transition|reject_human_review_transition|github_client_module)\(" src/lib/aiur/orchestrator.ex`;
  `grep -cE "^  defp (deactivate_running_issue|close_active_chat_streams|terminate_reason|terminate_task)\(" src/lib/aiur/orchestrator.ex`;
  `grep -cE "^  defp (terminate_wedged_overcap_entry|maybe_restart_stalled_entry|stall_elapsed_ms|last_activity_timestamp)\(" src/lib/aiur/orchestrator.ex`.
- The five new modules are NOT coverage-exempt:
  `grep -cE "Orchestrator\.(StatusReport|WorkspaceCleanup|HumanReview|AgentTeardown|RuntimeWatchdog)" src/mix.exs` = 0.
- `mix.exs` untouched: `git diff --name-only origin/v2...HEAD` does NOT list
  `src/mix.exs`; `Aiur.Orchestrator` and `Aiur.Orchestrator.State` still appear
  in its `ignore_modules`.
- A test file exists per extracted module:
  `test -f src/test/aiur/orchestrator/status_report_test.exs && test -f src/test/aiur/orchestrator/workspace_cleanup_test.exs && test -f src/test/aiur/orchestrator/human_review_test.exs && test -f src/test/aiur/orchestrator/agent_teardown_test.exs && test -f src/test/aiur/orchestrator/runtime_watchdog_test.exs`.
- `git diff --name-only origin/v2...HEAD` lists exactly the 11 files in
  **Files** — in particular NOTHING under `src/test/aiur/regression/` and no
  `src/mix.exs`.
- The full Agent gate below passes.

## Verification
### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```
### At-merge (reviewer)

- Check (verbatim move): `git diff --color-moved=dimmed-zebra origin/v2...HEAD -- src/lib/aiur/orchestrator.ex src/lib/aiur/orchestrator/status_report.ex src/lib/aiur/orchestrator/workspace_cleanup.ex src/lib/aiur/orchestrator/human_review.ex src/lib/aiur/orchestrator/agent_teardown.ex src/lib/aiur/orchestrator/runtime_watchdog.ex`
  shows the moved bodies as moved (dimmed), not rewritten; the only in-body
  edits are the module-qualifications listed in Scope step 8.
- Check (FI-ORC-027 ordering intact): in `agent_teardown.ex`, both
  `terminate_running_issue/3` and `deactivate_running_issue/2` call
  `close_active_chat_streams/2` BEFORE `terminate_task/1`, and
  `kill_repl_session/1` before the task dies; `deactivate_running_issue/2` calls
  `Orchestrator.refresh_tracked_set/1` at the end.
- Check (FI-ORC-032 sole kill path): in `runtime_watchdog.ex`,
  `restart_stalled_issue/5` returns the state unchanged for a
  `paused_running_entry?`/`deactivated_running_entry?` that is not
  `wedged_overcap_entry?`, and `wedged_overcap_entry?/3` still requires
  `paused_reason == :max_agent_duration` and `last_codex > paused_at`.
- Check (FI-ORC-031 clock scope): `overrunning_entry?/3` still guards
  `not paused_running_entry?` and `not deactivated_running_entry?` before the
  `running_seconds > max_seconds` comparison.
- Check (FI-ORC-004 fallback): `configured_todo_states/0` still falls back to
  `["todo"]` when no active state has the `todo` slug.
- Check (facade slimmed): `wc -l < src/lib/aiur/orchestrator.ex` <= 750 and the
  facade retains `init/1`, `terminate/2`, the public client API, and the
  `*_for_test` seams (spot-check `grep -c "_for_test" src/lib/aiur/orchestrator.ex`
  is unchanged from before the ticket).
- Run the named pins:
  `mix test test/aiur/orchestrator_deactivate_test.exs test/aiur/orchestrator_status_test.exs test/aiur/orchestrator_max_duration_test.exs test/aiur/core_test.exs test/aiur/regression`
  — all green with zero skips.
- Behavior spot-check on `v2` after merge: start `aiurdev` against the sandbox
  repo, let one agent exceed `max_agent_duration_minutes` (set it low in
  `.aiur/config`), and confirm the orchestrator logs
  `Issue exceeded max_agent_duration` and pauses (not kills) the agent, and that
  a ticket marked `human-review` deactivates its slot while the row stays
  visible — unchanged log strings and behavior.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
