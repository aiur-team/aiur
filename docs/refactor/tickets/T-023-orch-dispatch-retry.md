# T-023: orchestrator wave 2: Dispatcher, RetryEngine, Reconciler

**Phase:** 3
**Depends-on:** T-022
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/orchestrator.ex` is a 7,617-line GenServer (774 def/defp clauses)
being decomposed into ~26 modules per the binding name map in
`docs/refactor/research-arch/giant-orchestrator.md` §2. This is wave 2 of 6
(T-022..T-027): extract `Aiur.Orchestrator.Dispatcher` (dispatch execution:
choose loop, revalidation, thrash breaker, worker spawn),
`Aiur.Orchestrator.RetryEngine` (retry scheduling and budget semantics), and
`Aiur.Orchestrator.Reconciler` (per-poll reconciliation of running entries
against refreshed tracker states). T-022 already extracted
`Aiur.Orchestrator.State`, `Aiur.Orchestrator.EventTopics`,
`Aiur.Orchestrator.DispatchPolicy`, and `Aiur.Orchestrator.Slots`.

This area is regression hotspot #6 in `docs/refactor/research-history-hotspots.md`
(~15 incidents: retry budget burned by non-failures #549/#551, claim never
released on exhaustion #699/#723, load gate shipped disabled #477). The
CRITICAL preserved semantics: the retry budget is burned ONLY by real failures
(`:continuation`, `:capacity_wait`, `:precondition` never consume
`max_retry_attempts`), and reconciliation/cleanup semantics stay exactly as-is.
This is a verbatim code MOVE, not a rewrite: every function body is copied
unchanged, public function signatures and observable behavior are unchanged,
and all extracted code keeps executing as plain function calls inside the
orchestrator GenServer process (no new processes, no GenServer calls back into
the orchestrator — that deadlocks).

## Scope (exact)

Line numbers below are from the current `main` snapshot of
`src/lib/aiur/orchestrator.ex` (7,617 lines). T-022 will have shifted them:
locate every function by its exact name/arity (each name/arity is unique in
the file); use the line numbers only as orientation.

1. **Precondition check.** Verify these files exist:
   `src/lib/aiur/orchestrator/state.ex`, `src/lib/aiur/orchestrator/event_topics.ex`,
   `src/lib/aiur/orchestrator/dispatch_policy.ex`, `src/lib/aiur/orchestrator/slots.ex`
   (created by T-022). If any is missing, STOP: comment the blocker on the
   issue and end your turn. Do not start extraction.

2. **Create `src/lib/aiur/orchestrator/reconciler.ex`** defining
   `defmodule Aiur.Orchestrator.Reconciler`. Move these functions VERBATIM
   (bodies byte-identical, comments included) out of
   `src/lib/aiur/orchestrator.ex`:

   Public (`def` + `@spec`; these are called from code remaining in
   `orchestrator.ex`):
   - `reconcile_running_lifecycle/1` (was ~2395)
   - `refresh_running_issue_states/1` (was ~2401)
   - `reconcile_running_issue_states/4` (both clauses, was ~2654)
   - `reconcile_issue_state/4` (both clauses, was ~2665)
   - `maybe_reactivate_or_refresh/2` (was ~2835)
   - `reconcile_missing_running_issue_ids/3` (both clauses, was ~2853)
   - `refresh_running_issue_state/2` (was ~2887)

   Private (`defp`, internal-only):
   - `log_missing_running_issue/2` (both clauses, was ~2875)

3. **Create `src/lib/aiur/orchestrator/dispatcher.ex`** defining
   `defmodule Aiur.Orchestrator.Dispatcher`. Move these functions VERBATIM:

   Public (`def` + `@spec`):
   - `choose_issues/2` (was ~3489)
   - `dispatch_issue/2` `/3` `/4` (was ~3724; KEEP the default args
     `attempt \\ nil, preferred_worker_host \\ nil`)
   - `do_dispatch_issue/4` (was ~3750)
   - `check_thrash_budget/3` (was ~3786; its `@spec` already exists — move it)
   - `reset_thrash_budget/2` (was ~3822)
   - `revalidate_issue_for_dispatch/3` (both clauses, was ~3886)

   Private (`defp`):
   - `maybe_schedule_startup_todo_alert/5` (both clauses, was ~3519)
   - `dispatch_to_worker/4` (was ~3760)
   - `trip_thrash_breaker/2` (was ~3807; move its preceding comment block)
   - `spawn_issue_on_worker_host/5` (was ~3826)
   - `default_running_control/1` (was ~6527)

4. **Create `src/lib/aiur/orchestrator/retry_engine.ex`** defining
   `defmodule Aiur.Orchestrator.RetryEngine`. Move these functions VERBATIM:

   Public (`def` + `@spec`):
   - `complete_issue/2` (was ~3906)
   - `schedule_issue_retry/4` (was ~3914; move the #699 claim-release comment
     block inside it untouched)
   - `failure_retry?/1` (was ~4000)
   - `pop_retry_attempt_state/3` (was ~4048)
   - `handle_retry_issue/4` (was ~4067)
   - `release_issue_claim/2` (was ~4516)
   - `retry_delay/2` (all four clauses, was ~4520)
   - `failure_retry_delay/1` (was ~4544)
   - `normalize_retry_attempt/1` (both clauses, was ~4553)
   - `next_retry_attempt_from_running/1` (was ~4561)

   Private (`defp`):
   - `move_exhausted_issue_to_error_state/1` (both clauses + comment, was ~4009)
   - `log_scheduled_retry/7` (was ~4022)
   - `format_retry_preflight_error/1` (both clauses, was ~4089; sole consumer
     is `handle_retry_issue/4`)
   - `handle_retry_poll_failure/5` (was ~4094)
   - `emit_retry_poll_exhausted_alert/5` (was ~4119)
   - `handle_retry_issue_lookup/5` (both clauses, was ~4138)
   - `handle_active_retry/4` (was ~4494)
   - `normalize_retry_poll_failures/1` (both clauses, was ~4556)
   - `pick_retry_identifier/3`, `pick_retry_error/2`,
     `pick_retry_poll_failures/2`, `pick_retry_worker_host/2`,
     `pick_retry_workspace_path/2` (was ~4568-4588)
   - `find_issue_by_id/2` (was ~4659; sole consumer is `handle_retry_issue/4`.
     Do NOT confuse with `find_issue_by_identifier_or_id/2`, which stays in
     `orchestrator.ex`.)

   Move these module attributes and the import from `orchestrator.ex` into
   `retry_engine.ex` (delete them from `orchestrator.ex`; they have no other
   consumers): `@continuation_retry_delay_ms 1_000`,
   `@failure_retry_base_ms 10_000`, `@max_retry_poll_failures 3`,
   `import Bitwise, only: [<<<: 2]`.

5. **Module heads.** Each new module gets: a `@moduledoc` (2-4 lines stating
   its one-sentence responsibility from the name map, plus "All functions
   execute inside the orchestrator GenServer process."), the aliases it needs
   copied from `orchestrator.ex`'s head (e.g. `alias Aiur.Orchestrator.State`,
   `Issue`, `Tracker`, `Alerts`, `Config`, `AgentRunner`, `CodingAgent`,
   `Aiur.GitHub.Client, as: GitHubClient`, `require Logger` — only the ones
   its moved code references; `mix compile --warnings-as-errors` will flag
   unused ones), and `@spec` on every public `def` (`mix lint` runs
   `specs.check`, which enforces this).

6. **Rewrite intra-move references (no logic changes).** Inside the moved
   bodies, qualify calls whose targets now live elsewhere:
   - Targets extracted by T-022 → call them at their T-022 home, e.g.
     `DispatchPolicy.sort_issues_for_dispatch/1`,
     `DispatchPolicy.should_dispatch_issue?/4`,
     `DispatchPolicy.active_state_set/0`, `DispatchPolicy.terminal_state_set/0`,
     `DispatchPolicy.normalize_issue_state/1`,
     `DispatchPolicy.retry_candidate_issue?/2`,
     `DispatchPolicy.terminal_issue_state?/2`,
     `DispatchPolicy.active_issue_state?/2`,
     `DispatchPolicy.issue_routable_to_worker?/1`,
     `DispatchPolicy.dispatch_slots_available?/2`,
     `Slots.select_worker_host/2`, `Slots.worker_slots_available?/2`,
     `State.issue_context/1`. If T-022 placed one of these helpers differently
     (check with `grep -rn "def <name>" src/lib/aiur/orchestrator/`), call it
     where T-022 actually put it; if T-022 left it as a `defp` in
     `orchestrator.ex`, treat it under the next bullet.
   - Targets still living in `orchestrator.ex` (they belong to LATER waves) →
     flip each listed `defp` to `@doc false def` with a `@spec`, body
     untouched, and call it as `Orchestrator.<name>(...)` (add
     `alias Aiur.Orchestrator` in the new module). Exact list:
     `reconcile_stalled_running_issues/1`, `reconcile_overrunning_agents/1`
     (→ RuntimeWatchdog, T-027), `reconcile_pending_auto_resumes/1`
     (→ PushRouting, T-024), `terminate_running_issue/3`,
     `cleanup_terminal_issue_artifacts/1` `/2` (→ T-027; keep its default-arg
     head), `maybe_deactivate_human_review_issue/2`, `human_review_state?/1`
     (→ HumanReview, T-027), `reactivate_issue/2` (→ PauseResume, T-026),
     `ensure_tracker_preflight/1` (→ TrackerHealth, T-025),
     `running_worker_host/2` (multi-consumer, stays).
   - Cross-references between the two new modules stay module-qualified:
     `spawn_issue_on_worker_host/5` calls `RetryEngine.schedule_issue_retry/4`
     and `RetryEngine.normalize_retry_attempt/1`; `handle_active_retry/4` and
     `handle_retry_issue_lookup/5` call `Dispatcher.dispatch_issue/4`;
     `maybe_reactivate_or_refresh/2` is called by the facade's
     `maybe_deactivate_human_review_issue/2` via the wrapper below.
   - Do NOT change `self()`, `Process.send_after/3`, `Process.cancel_timer/1`,
     `make_ref()`, or `Process.monitor/1` sites in any way — the moved code
     runs inside the orchestrator process and the token-guarded timer
     semantics (`{:retry_issue, issue_id, retry_token}`) depend on it.

7. **In `src/lib/aiur/orchestrator.ex`:** delete every moved definition, then
   add a private one-line wrapper — identical head: same name, arity, guards,
   and default args — ONLY for the moved functions that code remaining in
   `orchestrator.ex` still calls (its `handle_info`/`handle_call` clauses,
   `handle_agent_down/2`, `do_maybe_dispatch/1`, `dispatch_or_hold/2`,
   comment-rework/PR-anchored/reactivate/RC paths, and the `*_for_test`
   seams). Exact wrapper list, each delegating to the new module:
   - → `Dispatcher`: `choose_issues/2`, `dispatch_issue/2..4` (keep
     `attempt \\ nil, preferred_worker_host \\ nil`), `do_dispatch_issue/4`,
     `reset_thrash_budget/2`, `check_thrash_budget/3`,
     `revalidate_issue_for_dispatch/3`
   - → `RetryEngine`: `complete_issue/2`, `schedule_issue_retry/4`,
     `next_retry_attempt_from_running/1`, `pop_retry_attempt_state/3`,
     `handle_retry_issue/4`, `release_issue_claim/2`
   - → `Reconciler`: `reconcile_running_lifecycle/1`,
     `refresh_running_issue_states/1`, `reconcile_running_issue_states/4`,
     `maybe_reactivate_or_refresh/2`

   Do NOT edit the bodies of `handle_info`/`handle_call` clauses,
   `handle_agent_down/2`, `do_maybe_dispatch/1`, or any `*_for_test` function —
   the wrappers keep every existing call site compiling unchanged. Do NOT
   move `maybe_dispatch/1`, `do_maybe_dispatch/1`, `dispatch_or_hold/2`,
   `maybe_choose_under_load/2`, or `handle_agent_down/2`: they stay in the
   facade this wave.

8. **Write the three test files** (new modules are NOT coverage-exempt; the
   85% threshold plus this ticket's review enforce real tests). Build
   `%Aiur.Orchestrator.State{}` structs directly (all fields default). Test
   only through each module's public functions; no GenServer needed:
   - `src/test/aiur/orchestrator/retry_engine_test.exs`:
     `failure_retry?/1` is false for `delay_type` `:continuation`,
     `:capacity_wait`, `:precondition` and true otherwise (THE budget
     invariant — #549/#551 class); `retry_delay/2` returns 1_000 for
     continuation attempt 1 and for `:capacity_wait`; failure delay is
     `10_000 * 2^(attempt-1)` capped by `agent.max_retry_backoff_ms` and the
     power capped at 10 (`failure_retry_delay/1`); `normalize_retry_attempt/1`
     (positive int passes, else 0); `next_retry_attempt_from_running/1`
     (increments a positive `:retry_attempt`, else nil);
     `pop_retry_attempt_state/3` returns `{:ok, attempt, metadata, state}` on
     a matching `retry_token` and `:missing` on a stale token (stale-timer
     immunity); `complete_issue/2` adds to `completed` and clears
     `retry_attempts`; `release_issue_claim/2` removes the id from `claimed`.
   - `src/test/aiur/orchestrator/dispatcher_test.exs`:
     `check_thrash_budget/3` returns `{:ok, _}` under the configured
     per-window limit, `{:trip, _}` above it, and resets the count once
     `now_ms` passes the window (window-lapse reset); `reset_thrash_budget/2`
     deletes the issue's budget entry; `revalidate_issue_for_dispatch/3`
     yields `{:ok, refreshed}` for an active candidate, `{:skip, refreshed}`
     for a stale one, `{:skip, :missing}` for `{:ok, []}`, and
     `{:error, reason}` on fetcher error (use a stub fetcher fun).
   - `src/test/aiur/orchestrator/reconciler_test.exs`:
     `reconcile_running_issue_states/4` with `[]` returns the state unchanged;
     `reconcile_issue_state/4` with a non-`%Issue{}` first arg returns the
     state unchanged; `refresh_running_issue_state/2` replaces the stored
     `:issue` for a known running id and is a no-op for an unknown id;
     `reconcile_missing_running_issue_ids/3` with every requested id visible
     returns the state unchanged.

9. **Do not modify** `src/mix.exs` (the three new modules must NOT be added to
   `ignore_modules`), any existing test file, `src/lib/aiur/orchestrator/tracked_set.ex`,
   or the T-022 modules. After steps 2-8 the repo compiles warnings-free and
   the FULL suite passes (run the Agent gate below).

## Files

- Create: `src/lib/aiur/orchestrator/dispatcher.ex`,
  `src/lib/aiur/orchestrator/retry_engine.ex`,
  `src/lib/aiur/orchestrator/reconciler.ex`,
  `src/test/aiur/orchestrator/dispatcher_test.exs`,
  `src/test/aiur/orchestrator/retry_engine_test.exs`,
  `src/test/aiur/orchestrator/reconciler_test.exs`
- Modify: `src/lib/aiur/orchestrator.ex`
- Test: the three new test files above; the entire existing suite must pass
  unmodified.

## Out of scope

- The other 19 planned orchestrator modules (CommentWake, PrAnchored,
  PushRouting, CommentPolling, CommandScan → T-024; IssueSync,
  AutoSubscriptions, TrackerHealth, OperatorMessages, DigestCoalescer →
  T-025; PauseResume, Interrupts, RemoteControlMode, TokenAccounting → T-026;
  StatusReport, WorkspaceCleanup, HumanReview, AgentTeardown, RuntimeWatchdog
  → T-027). Their functions stay in `orchestrator.ex`; the only permitted
  touch is the listed `defp` → `@doc false def` visibility flips.
- The T-022 modules (`state.ex`, `event_topics.ex`, `dispatch_policy.ex`,
  `slots.ex`) — call them, never edit them.
- `src/lib/aiur/orchestrator/tracked_set.ex`, `src/lib/aiur/agent_runner.ex`,
  `src/lib/aiur/tracker.ex`, `src/lib/aiur/coding_agent.ex` — untouched.
- `src/mix.exs` — untouched (no new coverage exemptions, no dep changes).
- Every existing test file, including all `*_for_test` seam call sites —
  test moves/renames are a later cleanup wave (research doc W29), not this
  ticket.
- Any behavior change: no renamed functions, no reordered clauses, no changed
  delays/limits/log strings/alert topics, no "improvements" to moved code.
- `handle_info`/`handle_call`/`handle_cast` clause bodies, `init/1`,
  `terminate/2`, tick scheduling, tracked-set sync (`issue_tracked?/1` stays
  in the facade — Publisher closure contract).

## Inventory-IDs

From `docs/refactor/feature-inventory/orc.md` — this ticket's Files implement
or touch these entries; their behavior must be byte-for-byte preserved:

- **FI-ORC-008** — dispatch ordering (the `choose_issues/2` loop moves; the
  sort itself lives in DispatchPolicy from T-022).
- **FI-ORC-015** — pre-dispatch issue revalidation incl. the PR-anchored
  (`pr-N`) bypass clause of `revalidate_issue_for_dispatch/3`.
- **FI-ORC-016** — codex thrash circuit breaker (gate BEFORE any clone;
  window-lapse reset; `thrash_circuit_open` needs_attention alert).
- **FI-ORC-017** — worker-host selection is exercised via
  `dispatch_to_worker/4` → `Slots.select_worker_host/2` (Slots itself is
  T-022's).
- **FI-ORC-018** — agent task spawn, claim add, running-entry shape (every
  seeded field), spawn-failure retry at attempt+1.
- **FI-ORC-019** — startup todo dispatch alert staggering (index × 1000ms,
  initial cycle only).
- **FI-ORC-020** — DOWN continuation-vs-failure retry (the `handle_agent_down/2`
  clause stays in the facade but now calls `RetryEngine.complete_issue/2` /
  `RetryEngine.schedule_issue_retry/4` via wrappers).
- **FI-ORC-021** — retry tokens, timer cancel, backoff ladder (continuation/
  capacity_wait 1s; precondition exponential on retry_poll_failures; failure
  `10s × 2^(attempt−1)`, power cap 10, bounded by `max_retry_backoff_ms`).
- **FI-ORC-022** — retry give-up: `retry_exhausted` alert, best-effort move to
  tracker state `error`, claim + retry-state release (#699/#723).
- **FI-ORC-023** — retry-poll failure budget (3 strikes, `:precondition`
  delay type never consumes the agent retry attempt,
  `orchestrator.retry_poll.exhausted` alert, claim release).
- **FI-ORC-024** — retry lookup dispositions (terminal → cleanup + release;
  non-active/missing → release; active → re-dispatch or `:capacity_wait`
  reschedule preserving the failure attempt count).
- **FI-ORC-025** — running-issue state reconciliation decision table incl.
  the fail-safe "fetch error keeps all workers running" branch.
- **FI-ORC-026** — human-review deactivation routing (only the
  `reconcile_issue_state/4` branch that calls
  `maybe_deactivate_human_review_issue/2` moves; the gate itself stays for
  T-027).
- **FI-ORC-046** — tracker preflight on every retry poll
  (`handle_retry_issue/4` → `Orchestrator.ensure_tracker_preflight/1`).

## Characterization-tests

All of `src/test/aiur/regression/` must pass UNMODIFIED. Specifically the
orchestrator characterization files landed by T-007 (Characterization:
orchestrator lifecycle & dispatch gates), which per
`research-arch/giant-orchestrator.md` §4 pin exactly this wave's semantics:
the `{:retry_issue, id, token}` stale-token drop, `:continuation`-vs-failure
budget accounting, exponential delay + backoff cap, retry-poll-failure
exhaustion, exhaustion → `error` state + claim release (#699),
`handle_active_retry`'s `:capacity_wait` reschedule, and thrash-breaker
window-lapse/operator-resume resets. List them at execution time with
`ls src/test/aiur/regression/ | grep -i orch` (they merge in Phase 1, before
this ticket opens) and run them explicitly before opening the PR.

These existing (non-regression-dir) pins must also pass unmodified — they
exercise the moved code through the `*_for_test` seams and `handle_info`
sends, which is why the seams and wrappers must keep identical signatures:
`src/test/aiur/orchestrator_thrash_test.exs`,
`src/test/aiur/orchestrator_deactivate_test.exs`,
`src/test/aiur/orchestrator_status_test.exs`,
`src/test/aiur/orchestrator_max_duration_test.exs`,
`src/test/aiur/core_test.exs`,
`src/test/aiur/workspace_and_config_test.exs`.

## Acceptance criteria

All greps run from the repo root; all must hold:

- `grep -c "defmodule Aiur.Orchestrator.Dispatcher do" src/lib/aiur/orchestrator/dispatcher.ex` = 1
- `grep -c "defmodule Aiur.Orchestrator.RetryEngine do" src/lib/aiur/orchestrator/retry_engine.ex` = 1
- `grep -c "defmodule Aiur.Orchestrator.Reconciler do" src/lib/aiur/orchestrator/reconciler.ex` = 1
- `grep -c "@moduledoc" <file>` >= 1 for each of the three new modules.
- `wc -l < src/lib/aiur/orchestrator.ex` < 6100 (7,617 on main; T-022 plus
  this wave's ~950 moved lines minus wrappers).
- New-file size caps (these three carry the research doc's documented
  exception to the 200-line norm — RetryEngine is deliberately kept whole so
  the budget invariant stays in one file; do not split them further and do
  not exceed the caps): `wc -l < src/lib/aiur/orchestrator/dispatcher.ex`
  <= 450, `wc -l < src/lib/aiur/orchestrator/retry_engine.ex` <= 520,
  `wc -l < src/lib/aiur/orchestrator/reconciler.ex` <= 320.
- Moved functions are moved, not rewritten: no NEW function body may exceed
  20 logic lines (wrappers are 1 line); moved bodies are byte-identical
  (verified at-merge via `--color-moved`).
- Retry attributes left the facade:
  `grep -cE "@failure_retry_base_ms|@continuation_retry_delay_ms|@max_retry_poll_failures" src/lib/aiur/orchestrator.ex` = 0,
  and each of the three appears exactly once in
  `src/lib/aiur/orchestrator/retry_engine.ex`.
- No retry-timer creation remains in the facade:
  `grep -c "Process.send_after(self(), {:retry_issue" src/lib/aiur/orchestrator.ex` = 0
  and the same grep = 1 in `src/lib/aiur/orchestrator/retry_engine.ex`.
- No thrash-budget logic remains in the facade:
  `grep -c "codex_thrash_budget" src/lib/aiur/orchestrator.ex` = 0.
- No unwrapped moved definitions remain (wrapped names keep a 1-line `defp`;
  these must be gone entirely):
  `grep -cE "^  defp (dispatch_to_worker|spawn_issue_on_worker_host|trip_thrash_breaker|maybe_schedule_startup_todo_alert|default_running_control)\(" src/lib/aiur/orchestrator.ex` = 0;
  `grep -cE "^  defp (handle_retry_poll_failure|handle_retry_issue_lookup|handle_active_retry|failure_retry\?|retry_delay|failure_retry_delay|move_exhausted_issue_to_error_state|pick_retry_|normalize_retry_poll_failures|log_scheduled_retry|emit_retry_poll_exhausted_alert|format_retry_preflight_error|find_issue_by_id)\(" src/lib/aiur/orchestrator.ex` = 0;
  `grep -cE "^  defp (reconcile_issue_state|reconcile_missing_running_issue_ids|refresh_running_issue_state|log_missing_running_issue)\(" src/lib/aiur/orchestrator.ex` = 0.
- New modules are NOT coverage-exempt:
  `grep -cE "Orchestrator\.(Dispatcher|RetryEngine|Reconciler)" src/mix.exs` = 0.
- A test file exists per extracted module:
  `test -f src/test/aiur/orchestrator/dispatcher_test.exs && test -f src/test/aiur/orchestrator/retry_engine_test.exs && test -f src/test/aiur/orchestrator/reconciler_test.exs`.
- `git diff --name-only origin/v2...HEAD` lists exactly the 7 files in
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

- Check: `git diff --color-moved=dimmed-zebra origin/v2...HEAD -- src/lib/aiur/orchestrator.ex src/lib/aiur/orchestrator/dispatcher.ex src/lib/aiur/orchestrator/retry_engine.ex src/lib/aiur/orchestrator/reconciler.ex`
  shows the moved bodies as moved (dimmed), not rewritten; the only in-body
  edits are module-qualification of the calls listed in Scope step 6.
- Check (FI-ORC-021 ladder intact): `retry_engine.ex` contains
  `@failure_retry_base_ms 10_000`, `@continuation_retry_delay_ms 1_000`,
  `@max_retry_poll_failures 3`, and `min(attempt - 1, 10)` verbatim.
- Check (FI-ORC-022, #699): `retry_engine.ex` contains the
  `"ticket.#{identifier}.agent.retry_exhausted"` alert, the
  `Tracker.update_issue_state(identifier, "error")` best-effort write, and a
  claim release on the give-up path.
- Check (FI-ORC-016 ordering): in `dispatcher.ex`, `do_dispatch_issue/4`
  calls `check_thrash_budget/3` BEFORE `dispatch_to_worker/4` (trip pays no
  workspace-clone cost).
- Check (FI-ORC-025 fail-safe): in `reconciler.ex`,
  `refresh_running_issue_states/1` returns `state` unchanged on
  `{:error, reason}` from `Tracker.fetch_issue_states_by_ids/1`.
- Run the named pins:
  `mix test test/aiur/orchestrator_thrash_test.exs test/aiur/orchestrator_deactivate_test.exs test/aiur/orchestrator_status_test.exs test/aiur/orchestrator_max_duration_test.exs test/aiur/core_test.exs test/aiur/workspace_and_config_test.exs test/aiur/regression`
  — all green with zero skips.
- Behavior spot-check on `v2` after merge: start `aiurdev` against the
  sandbox repo, confirm one ticket dispatches, then kill its agent process
  once and confirm the orchestrator logs `Scheduling continuation retry` /
  `Retrying agent failure` (unchanged log strings) and re-dispatches without
  burning the budget on the `:normal` exit path.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
