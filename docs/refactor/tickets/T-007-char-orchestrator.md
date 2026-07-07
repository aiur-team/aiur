# T-007: Characterization: orchestrator lifecycle & dispatch gates

**Phase:** 1
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:1` `complexity:3`

## Problem / context

`src/lib/aiur/orchestrator.ex` (7,617 lines) is regression hotspot #6 (~15 incidents: retry budget burned by non-failures #549/#551/#699, max-duration bound regression #420, load gate shipped disabled #477, pause/resume races — see `docs/refactor/research-history-hotspots.md`) and is about to be decomposed into ~26 modules by tickets T-022..T-027 (`docs/refactor/research-arch/giant-orchestrator.md`). Before any extraction wave touches the file, its current lifecycle and dispatch-gate behavior must be pinned by characterization tests that live under the guarded `src/test/aiur/regression/` path, where executor agents are forbidden from editing them. T-022..T-027 all require these tests to pass **unmodified**.

Some cases below deliberately duplicate coverage that exists in ordinary test files (`orchestrator_load_gate_test.exs`, `orchestrator_max_agents_test.exs`, `core_test.exs`): the regression copies are the frozen contract; the ordinary files may later be split/moved during decomposition. This ticket creates **two new test files and changes nothing else**.

## Scope (exact)

Harness conventions (use these exactly; make zero design decisions):

- Both files start `use Aiur.TestSupport` (see `src/test/support/test_support.exs`; it is non-async and provides `write_workflow_file!/2`, `restore_env/2`, and aliases `Orchestrator`, `Issue`, `Workflow`).
- Where a live GenServer is needed: start a uniquely-named orchestrator per test — `{:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :CaseName))` with an `on_exit` that kills it (copy `start_orchestrator/1` from `src/test/aiur/orchestrator_max_agents_test.exs` lines 19–23). Seed state with `:sys.replace_state(pid, fn state -> ... end)`.
- Copy the running-entry fixture `running_entry/3` from `src/test/aiur/orchestrator_max_agents_test.exs` lines 4–17 (entry `pid: self()` so control messages arrive in the test mailbox).
- Where a tracker is needed: in-memory tracker via `write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: [...], tracker_terminal_states: [...])` plus `Application.put_env(:aiur, :memory_tracker_recipient, self())` — copy the pattern from `src/test/aiur/core_test.exs` test `"abnormal worker exit beyond max_retry_attempts gives up, clears retry state, and surfaces the error state"` (~line 686). Always restore app env in `on_exit`.
- Drive behavior ONLY through: `send(pid, msg)` + `:sys.get_state(pid)`; direct `Orchestrator.handle_info(msg, state)` calls on a constructed state (pattern: `src/test/aiur/orchestrator_deactivate_test.exs` lines ~1774–1863); the public client API (`pause_agent/2`, `resume_agent/2`, `set_max_concurrent_agents/2`, `max_concurrent_agents/1`); and the existing `*_for_test` seams in `src/lib/aiur/orchestrator.ex` lines 2425–2652 (`slot_status_for_test/1`, `apply_pause_request_for_test/2`, `apply_overrun_check_for_test/2`, `resume_paused_issue_for_test/3`, `should_dispatch_issue_for_test/2`, `dispatch_candidate_for_test/2`, `retry_dispatch_ready_for_test/3`) plus `Orchestrator.load_gate/3` (lines 2389–2393) and `Orchestrator.read_load/1` (lines 2350–2351). Do NOT add new seams — if a case seems to need one, stop and comment the blocker on the issue.
- Comment-event map fixtures: copy the shape used by the `{:event, ...}` comment-wake blocks in `src/test/aiur/orchestrator_deactivate_test.exs` (search that file for `pr.review_comment` topic construction). Reuse its stubbing approach verbatim; do not invent new stubs.

Authoring constraints (mandatory, from the refactor regression-safety rules):

- Never assert exact counts on shared singletons (each test uses its own named orchestrator; assertions on `state.running`/`state.claimed` are per-instance and fine).
- Every `assert_receive` timeout must be >= 2000 (ms). `refute_receive` may use a short window (100ms, matching existing tests).
- No `Process.sleep` for synchronization anywhere in these files. After `send(pid, msg)`, synchronize with `:sys.get_state(pid)` (it is a synchronous call queued behind the message). Use `assert_receive` / monitors for async effects. (Do NOT copy `core_test.exs`'s `Process.sleep(50)` lines when porting its patterns.)
- Any test that reaches subscription attachment (tests L2 and L5 below can, via `maybe_transition_idle_issue_to_rework` attaching universal subscriptions) must isolate the SubscriptionStore `:log_file` to a per-test tmp dir — copy the pattern from `src/test/aiur/events/subscription_store_test.exs`.
- Where a count invariant is asserted (slots, claims), assert it census-style over the state you constructed (e.g. `map_size(state.running)`, `MapSet.member?(state.claimed, id)`), never over global resources.
- Timing assertions on retry `due_at_ms`: define a local `assert_due_in_range/4` helper copied from `src/test/aiur/core_test.exs`.

### Step 1 — Create `src/test/aiur/regression/orchestrator_lifecycle_test.exs`

Module `Aiur.Regression.OrchestratorLifecycleTest`. A `@moduledoc` stating: these tests pin `Aiur.Orchestrator` lifecycle behavior prior to the T-022..T-027 decomposition and must pass unmodified through every extraction wave. Four `describe` blocks with exactly these names and tests:

`describe "comment wake/rework transitions"` (behavior contract: FI-ORC-034/035/036; source `src/lib/aiur/orchestrator.ex` lines 609–620, 1037–1154, 1183–1310, 1242–1260):

1. **L1** `test "trusted PR review comment reactivates a deactivated entry to rework"` — Input: state with one running entry whose `control.status == :deactivated`, memory tracker holding the issue in an active review state. Action: `Orchestrator.handle_info({:event, event}, state)` with a trusted-author `ticket.<n>.pr.review_comment` event. Expected: tracker receives a state write to `"rework"` and the returned state's entry is no longer `:deactivated`.
2. **L2** `test "trusted comment on an idle issue promotes it to rework and dispatches immediately"` — Input: empty `running`, memory tracker holding the issue idle in `"human-review"`. Action: same `handle_info` with an `issue.commented` event. Expected: tracker write to `"rework"` and the issue id appears in `claimed` (immediate dispatch attempted) in the returned state.
3. **L3** `test "untrusted-author comment is ignored"` — Same as L1 but the event author is untrusted. Expected: no tracker write, returned state unchanged (entry still `:deactivated`, `claimed` unchanged).
4. **L4** `test "bot review-pass comment never self-triggers rework"` — Same as L2 but the comment body is the bot's own `[codex] review passed` benign review-pass shape. Expected: no tracker write, no claim.
5. **L5** `test "transient tracker failure retries the wake without consuming the event"` — Input: idle-promotion setup as L2 but the tracker write fails transiently. Action: `handle_info({:event, event}, state)`. Expected: `assert_receive {:retry_comment_rework, identifier, source, ^event, 2}, 2000` (the wake event is re-scheduled, not consumed — #631/#632 class); re-delivering that message via `Orchestrator.handle_info/2` with the tracker healthy completes the `"rework"` write. Pattern: `orchestrator_deactivate_test.exs` lines ~1852–1863.
6. **L6** `test "pr.merged terminalizes the ticket to done and tears down the running entry"` — Input: state with one running entry, memory tracker. Action: `handle_info({:event, ...}, state)` with topic `ticket.<n>.pr.merged`. Expected: tracker write to `"done"`, entry removed from `running`, id removed from `claimed`.

`describe "pause/resume semantics"` (contract: FI-ORC-011/037/054; source lines 767–804, 4770–4777, 5983–6053, 6214–6231, 6423–6454):

7. **L7** `test "pause.request parks a working entry and stamps paused_at"` — Input: live orchestrator, one `:working` entry with `pid: self()`. Action: `Orchestrator.pause_agent(name, identifier)`. Expected: `{:ok, request_id}`, `assert_receive {:pause_agent, ^request_id}, 2000`, and `:sys.get_state` shows `control.status == :paused` with non-nil `paused_at`. Pattern: `orchestrator_status_test.exs` line ~577.
8. **L8** `test "a paused entry keeps its slot and holds new dispatch"` — Input: state with session cap 1 and one `:paused` entry. Expected: `Orchestrator.slot_status_for_test(state) == %{active: 0, paused: 1}` and `should_dispatch_issue_for_test(fresh_todo_issue, state) == false` (available_slots = cap − (active + paused) = 0).
9. **L9** `test "resume of a paused entry bypasses available_slots"` — Input: live orchestrator, cap 1, exactly one entry, `:paused`, `pid: self()`. Action: `Orchestrator.resume_agent(name, identifier)`. Expected: `{:ok, :resumed}` and `assert_receive {:resume_agent, request_id} when is_integer(request_id), 2000` — even though available_slots is 0. Pattern: `orchestrator_status_test.exs` line ~599.
10. **L10** `test "resume is refused when active count already fills the cap"` — Input: live orchestrator, cap 1, one `:working` entry plus one `:paused` entry. Action: resume the paused one. Expected: the error return and no `{:resume_agent, _}` message (`refute_receive {:resume_agent, _}, 100`). Mirror the exact error atom asserted by the corresponding test in `orchestrator_status_test.exs` (line ~626).
11. **L11** `test "resume with no running entry starts a queued idle issue"` — Input: live orchestrator with `last_polled_issues` seeded with a dispatchable todo issue and no running entry, memory tracker. Action: `Orchestrator.resume_agent(name, identifier)`. Expected: `{:ok, :started}` and the issue id lands in `claimed` (FI-ORC-054). Mirror the queued-start pattern in `orchestrator_status_test.exs` (~line 2121).

`describe "drain semantics"` (contract: FI-ORC-012; source lines 5458–5465):

12. **L12** `test "lowering the cap below active count reports draining and holds new dispatch"` — Input: live orchestrator with 2 `:working` entries. Action: `Orchestrator.set_max_concurrent_agents(name, 1)`. Expected: `{:ok, %{max: 1, draining?: true}}`; both entries still present in `:sys.get_state(pid).running` (existing work continues); `should_dispatch_issue_for_test(fresh_todo_issue, state) == false`.

`describe "max-duration bound"` (contract: FI-ORC-031/032/033; source lines 3069–3129, 6233–6324, 6374–6421):

13. **L13** `test "an overrun active entry gets a cooperative pause, never a kill"` — Input: state with one `:working` entry whose `started_at` is 120s in the past, entry `pid: self()`. Action: `Orchestrator.apply_overrun_check_for_test(state, 60)`. Expected: returned entry has `control.status == :paused` and `paused_reason == :max_agent_duration`; `assert_receive {:pause_agent, _}, 2000`; the entry pid was NOT killed (it is `self()`; assert the entry is still in `running`).
14. **L14** `test "paused and deactivated entries are excluded from the overrun check"` — Input: one already-`:paused` overdue entry and one `:deactivated` overdue entry. Action: `apply_overrun_check_for_test(state, 60)`. Expected: state unchanged, `refute_receive {:pause_agent, _}, 100`.
15. **L15** `test "duration-cap resume: operator resets the budget, automated resume preserves the overrun"` — Input: an entry paused with `paused_reason: :max_agent_duration` and `started_at` far in the past. Action: `Orchestrator.resume_paused_issue_for_test(state, entry, true)` then separately `(state, entry, false)`. Expected: with `operator? == true` the resumed entry's `started_at` is reset to approximately now (fresh budget); with `operator? == false` `started_at` is preserved (overrun retained, #420-class bound); in both cases `last_codex_timestamp` is refreshed so the stall watchdog grants a full window.

### Step 2 — Create `src/test/aiur/regression/orchestrator_dispatch_retry_test.exs`

Module `Aiur.Regression.OrchestratorDispatchRetryTest`. Same `@moduledoc` intent. Two `describe` blocks:

`describe "dispatch gates"` (contract: FI-ORC-009/010/011/014; source lines 2322–2393, 3568–3696, 4770–4777):

16. **D1** `test "available slots = cap - (active + paused)"` — Input: state with cap 2, one `:working` + one `:paused` entry. Expected: `should_dispatch_issue_for_test(todo_issue, state) == false`; with session cap raised to 3 in the constructed state, `== true`.
17. **D2** `test "load gate holds new dispatch strictly above threshold x schedulers (#465)"` — Pure table: `Orchestrator.load_gate(20.0, 1.5, 12) == :hold`; `load_gate(10.0, 1.5, 12) == :dispatch`; `load_gate(18.0, 1.5, 12) == :dispatch` (exact ceiling dispatches); `load_gate(:unavailable, 1.5, 12) == :dispatch` (fails open).
18. **D3** `test "load gate disabled via null threshold never reads the load source"` — `load_gate(99.0, nil, 12) == :dispatch`, `load_gate(99.0, 0.0, 12) == :dispatch`; and with `Application.put_env(:aiur, :loadavg_source_override, fn -> flunk("must not read load when disabled") end)` (restored in `on_exit`), `Orchestrator.read_load(nil) == :unavailable`. Pattern: `orchestrator_load_gate_test.exs`.
19. **D4** `test "per-state slot limit gates same-state dispatch"` — Input: `write_workflow_file!` with `max_concurrent_agents_by_state: %{"rework" => 1}`; state with one active entry whose issue state is `"rework"`. Expected: a second `"rework"` candidate fails `should_dispatch_issue_for_test/2`; a `"todo"` candidate (with slots free) passes. Config-shape pattern: `workspace_and_config_test.exs` line ~1712.
20. **D5** `test "a claimed issue is not a dispatch candidate"` — Input: issue id present in `state.claimed`. Expected: `dispatch_candidate_for_test(issue, state) == false`; removing it from `claimed` flips the result to `true` (claim uniqueness).
21. **D6** `test "a running issue is not a dispatch candidate"` — Input: issue id present as a `state.running` key. Expected: `dispatch_candidate_for_test(issue, state) == false`.
22. **D7** `test "a todo blocked by a non-terminal blocker is not a candidate; unknown blocker state blocks"` — Input: todo issue with a blocker in a non-terminal state, and a variant whose blocker state is unknown. Expected: both fail the candidate check; with the blocker terminal, it passes. Mirror the blocker fixture shape used by the dispatch-gate tests in `workspace_and_config_test.exs` (FI-ORC-009's named pin).

`describe "retry budget accounting"` (contract: FI-ORC-020/021/022/023/024; source lines 451–462, 506–548, 3906–3997, 4000–4020, 4048–4161, 4494–4551):

23. **D8** `test "a stale retry token is dropped"` — Input: live orchestrator; seed `retry_attempts` with `%{issue_id => %{attempt: 2, retry_token: token_a, ...}}` via `:sys.replace_state`. Action: `send(pid, {:retry_issue, issue_id, make_ref()})`. Expected: `:sys.get_state(pid).retry_attempts[issue_id]` unchanged (attempt still 2, token still `token_a`).
24. **D9** `test "slot-unavailable retry reschedules as capacity_wait without burning budget (#549/#551)"` — Port `core_test.exs` test `"slot-starved retry preserves failure attempt and remains queued"` (~line 791) with `Process.sleep` replaced per the constraints: seed a failure retry at attempt 2 with the cap full, fire `{:retry_issue, issue_id, retry_token}`. Expected: rescheduled entry keeps `attempt: 2`, gets a fresh `retry_token`, and `due_at_ms` lands ~1s out (`assert_due_in_range`); `retry_dispatch_ready_for_test/2` is false while busy and true once a slot frees.
25. **D10** `test "tracker poll failure reschedules as precondition without burning budget (#549/#551)"` — Port `core_test.exs` test `"retry poll failures do not consume agent retry budget"` (~line 866, including its `:retry_poll_failure_test_pid` hook). Expected: after a failed tracker poll the retry entry's `attempt` is unchanged and `retry_poll_failures` incremented.
26. **D11** `test "the third consecutive retry-poll failure releases the claim and alerts"` — Input: retry entry seeded with `retry_poll_failures: 2` and the issue id in `claimed`; tracker poll fails again. Expected: `retry_attempts` entry cleared, id removed from `claimed`, and `capture_log` contains `orchestrator.retry_poll.exhausted` (FI-ORC-023).
27. **D12** `test "failure-retry exhaustion moves the ticket to error and releases the claim (#699/#723)"` — Port `core_test.exs` test `"abnormal worker exit beyond max_retry_attempts gives up, clears retry state, and surfaces the error state"` (~line 686) with its memory-tracker setup. Expected: retry state cleared, claim released, memory tracker receives the `"error"` state write, and `capture_log` contains `agent.retry_exhausted`.
28. **D13** `test "normal worker exit schedules a continuation retry at attempt 1"` — Port `core_test.exs` test `"normal worker exit schedules active-state continuation retry"` (~line 608): `send(pid, {:DOWN, ref, :process, self(), :normal})`. Expected: entry removed from `running`, id in `completed`, `retry_attempts[issue_id]` has `attempt: 1` with `due_at_ms` in the 500–1100ms window (continuation is NOT a failure and burns no budget).
29. **D14** `test "abnormal worker exit schedules exponential failure backoff"` — Port `core_test.exs` test `"abnormal worker exit increments retry attempt progressively"` (~line 647): entry with `retry_attempt: 2`, `send(pid, {:DOWN, ref, :process, self(), :boom})`. Expected: `retry_attempts[issue_id].attempt == 3` with `due_at_ms` in the 39,500–40,500ms window (10s × 2^(attempt−1)).

### Step 3 — Verify

From `src/`: run the full Agent gate (below). Both new files must be green in the same run as the whole suite. Run the two files once more standalone: `mix test test/aiur/regression/orchestrator_lifecycle_test.exs test/aiur/regression/orchestrator_dispatch_retry_test.exs`.

## Files

- Create: `src/test/aiur/regression/orchestrator_lifecycle_test.exs`
- Create: `src/test/aiur/regression/orchestrator_dispatch_retry_test.exs`
- Modify: none
- Test: the two created files (they are the deliverable)

## Out of scope

- Any edit to `src/lib/aiur/orchestrator.ex` or any other file under `src/lib/` — including adding new `*_for_test` seams. If a listed case cannot be reached through the existing seams named in Scope, comment the blocker on the issue instead.
- Any edit to existing test files (`core_test.exs`, `orchestrator_*_test.exs`, anything already under `src/test/aiur/regression/`) or to `src/test/support/`.
- Behaviors NOT listed above: thrash breaker, main-push notify (#720), pending-auto-resume drain, token accounting, PR-anchored routing, comment polling, remote control (other tickets own those pins).
- Fixing any bug or "wrong-looking" behavior discovered while writing pins — characterization tests pin behavior as-is; report oddities as issue comments.
- Refactoring, renaming, or moving anything in `docs/` or CI workflows.

## Inventory-IDs

FI-ORC-009, FI-ORC-010, FI-ORC-011, FI-ORC-012, FI-ORC-014, FI-ORC-020, FI-ORC-021, FI-ORC-022, FI-ORC-023, FI-ORC-024, FI-ORC-031, FI-ORC-032, FI-ORC-033, FI-ORC-034, FI-ORC-035, FI-ORC-036, FI-ORC-037, FI-ORC-054 (all in `docs/refactor/feature-inventory/orc.md`).

## Characterization-tests

This ticket CREATES the characterization tests for the orchestrator lifecycle/dispatch/retry seams:

- `src/test/aiur/regression/orchestrator_lifecycle_test.exs` (new)
- `src/test/aiur/regression/orchestrator_dispatch_retry_test.exs` (new)

Existing ordinary pins in the same area (not edited by this ticket): `src/test/aiur/orchestrator_deactivate_test.exs`, `orchestrator_status_test.exs`, `orchestrator_max_agents_test.exs`, `orchestrator_max_duration_test.exs`, `orchestrator_load_gate_test.exs`, `orchestrator_thrash_test.exs`, `orchestrator_prewarm_gate_test.exs`, `core_test.exs`.

## Acceptance criteria

- `test -f src/test/aiur/regression/orchestrator_lifecycle_test.exs && test -f src/test/aiur/regression/orchestrator_dispatch_retry_test.exs` succeeds.
- Module names are exactly `Aiur.Regression.OrchestratorLifecycleTest` and `Aiur.Regression.OrchestratorDispatchRetryTest` (`grep -l "defmodule Aiur.Regression.OrchestratorLifecycleTest"` / `...DispatchRetryTest` each match their file).
- `grep -c 'test "' src/test/aiur/regression/orchestrator_lifecycle_test.exs` returns 15; `grep -c 'test "' src/test/aiur/regression/orchestrator_dispatch_retry_test.exs` returns 14.
- The six describe names exist verbatim: `grep -h 'describe "' <both files>` yields exactly `comment wake/rework transitions`, `pause/resume semantics`, `drain semantics`, `max-duration bound`, `dispatch gates`, `retry budget accounting`.
- `grep -rn "Process.sleep" src/test/aiur/regression/orchestrator_lifecycle_test.exs src/test/aiur/regression/orchestrator_dispatch_retry_test.exs` returns nothing.
- Every `assert_receive` in both files carries an explicit timeout >= 2000: `grep -n "assert_receive" <both files>` shows no line without a `, 2000` (or larger) timeout argument.
- Each new file is <= 400 lines (`wc -l`); test-helper functions within them are <= 20 logic lines each. (The 400-line ceiling is this ticket's stated norm for characterization test files, superseding the 200-line new-file norm.)
- `git diff --stat` against the base shows exactly the two new files and zero modifications elsewhere; `git diff <base> -- src/lib/` is empty.
- Full Agent gate passes from `src/` with both files included; `mix test test/aiur/regression/orchestrator_lifecycle_test.exs test/aiur/regression/orchestrator_dispatch_retry_test.exs` also passes standalone.

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

- This PR touches the guarded regression path **by design** — apply the `regression-suite-change` override label (per T-005's tripwire guard) before merging.
- Check: `git diff --stat v2...HEAD` lists only the two new files under `src/test/aiur/regression/`; `git diff v2...HEAD -- src/lib/` is empty.
- Check: from `src/`, run `mix test test/aiur/regression/orchestrator_lifecycle_test.exs test/aiur/regression/orchestrator_dispatch_retry_test.exs` twice consecutively — green both times (flake probe; these files gate every T-022..T-027 wave, so a flaky pin here halts phase 3).
- Check: `grep -c 'test "'` counts are 15 and 14, and `grep -rn "Process.sleep"` over the two files is empty (authoring rules held).
- Check: spot-read D9/D10/D12 and confirm they assert budget NON-consumption (attempt unchanged) rather than merely rescheduling — that invariant is the #549/#551 contract.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
