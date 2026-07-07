# T-022: orchestrator wave 1: State, EventTopics, DispatchPolicy, Slots

**Phase:** 3
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3`

## Problem / context

`src/lib/aiur/orchestrator.ex` is a 7,617-line GenServer — the #6 regression
hotspot in `docs/refactor/research-history-hotspots.md` (retry budgets burned
by non-failures, max-duration bound #420, load gate shipped disabled #477,
pause/resume races). The decomposition plan in
`docs/refactor/research-arch/giant-orchestrator.md` splits it into ~26 modules
under `src/lib/aiur/orchestrator/` across 6 strictly serialized waves. This
ticket is wave 1 of 6: the four pure-leaf modules (`State`, `EventTopics`,
`DispatchPolicy`, `Slots`) — plain function moves with no timers, monitors, or
new processes. All extracted code keeps executing inside the orchestrator
GenServer process as plain function calls; no new GenServer calls anywhere
(a call from extracted code back into the orchestrator deadlocks).

This is a **verbatim code move, not a rewrite**. Function bodies, guards,
clause order, and comments move unchanged. Public function signatures and all
observable behavior are unchanged. Test files are never edited. Line numbers
below are from the `v2` state at ticket-writing time; if they have drifted,
locate functions by name — the function names and module assignments are the
binding contract.

## Scope (exact)

1. **Create `src/lib/aiur/orchestrator/state.ex`** defining
   `defmodule Aiur.Orchestrator.State`. Move, verbatim, from
   `src/lib/aiur/orchestrator.ex`:
   - The nested `defmodule State do ... end` block (lines 89–152): the
     `@moduledoc`, `@type t`, and `defstruct` (including the
     `queue_store: AgentQueueStore.new()` default) become the body of the new
     top-level module. The module name is unchanged
     (`Aiur.Orchestrator.State`), so no call site anywhere changes.
   - These functions (each moved `defp` becomes a public `def` on the new
     module, with a `@spec` added; bodies and attached comments verbatim):
     - `maybe_put_runtime_value/3` (lines 4590–4593)
     - `find_issue_id_for_ref/2` (4669–4674)
     - `running_entry_session_id/1` (4676–4679)
     - `issue_context/1` (4681–4683)
     - `active_running_count/1` (4685–4691)
     - `paused_running_count/1` (4693–4699)
     - `active_running_entry?/1` (4701–4705)
     - `paused_running_entry?/1` (4707–4711)
     - `sleeping_running_entry?/1` (4713–4717)
     - `deactivated_running_entry?/1` (4719–4723)
     - `find_running_key_by_identifier/2` (6363–6368)
     - `apply_pause_runtime_clock/4` (6369–6382, including the freeze/thaw
       comment block above it)
     - `thaw_pause_clock/4` (6384–6393)
     - `shift_started_at_by_pause_if/3` (6395–6399)
     - `shift_started_at_by_pause/2` (6400–6421, including the #420
       "duration-capped pause must NOT credit" comment — this comment is
       load-bearing documentation of FI-ORC-033)
     - `issue_tag/1` (6741–6747)
     - `find_running_by_identifier/2` (6749–6757)
     - `find_running_by_repl_pane_id/2` (6759–6764)
     - `pop_running_entry/2` (6867–6869)
     - `running_seconds/2` (7299–7303)
     - `effective_runtime_seconds/2` (7305–7319, including its comment)
   - Aliases needed in the new file: `alias Aiur.{AgentQueueStore, Issue}`.

2. **Create `src/lib/aiur/orchestrator/event_topics.ex`** defining
   `defmodule Aiur.Orchestrator.EventTopics`. Move, verbatim, lines 550–607:
   - `parse_pr_review_comment_topic/1`, `parse_issue_commented_topic/1`,
     `parse_pr_merged_topic/1`, `parse_pause_request_topic/1`,
     `parse_branch_push_topic/1`, `parse_system_branch_push_topic/1`,
     `classify_event_topic/1` (with its "single-pass topic classifier"
     comment), `tag_topic/2`.
   - All become public `def` with `@spec`. The six regexes move byte-for-byte
     (they define the exact six subscription patterns of FI-ORC-007; do not
     touch the subscription list in `init/1`). No aliases needed — the module
     is pure.

3. **Create `src/lib/aiur/orchestrator/slots.ex`** defining
   `defmodule Aiur.Orchestrator.Slots`. Move, verbatim:
   - `select_worker_host/2` (4596–4615)
   - `preferred_worker_host_available?/2` (4617–4622)
   - `least_loaded_worker_host/2` (4624–4631)
   - `running_worker_host_count/2` (4633–4639)
   - `worker_slots_available?/1` (4641–4643) and `worker_slots_available?/2`
     (4645–4647) — both arities
   - `worker_host_slots_available?/2` (4649–4657)
   - `launch_max_concurrent_agents_override/0` (4727–4732)
   - `max_concurrent_agent_limit/1` (4743–4755)
   - `max_concurrent_agent_status/1` (4756–4768)
   - `available_slots/1` (4770–4777, including the "paused agents keep their
     slot reserved" comment — FI-ORC-011)
   - `resume_worker_slot_available?/2` (6468–6472)
   - `dispatch_slots_available?/2` (6968–6970)
   - Aliases needed: `alias Aiur.{Config, Issue}` and
     `alias Aiur.Orchestrator.{DispatchPolicy, State}`. Moved bodies that
     called `active_running_entry?/`counts now call
     `State.active_running_entry?/1` etc.; `dispatch_slots_available?/2`
     calls `DispatchPolicy.state_slots_available?/2`. The mutual
     `Slots ↔ DispatchPolicy` runtime reference is expected and compiles fine.
   - **Deviation from the name map (intentional, decided here):**
     `apply_session_max_concurrent_agents/2` (4737–4741) does NOT move in this
     wave. It calls the facade-private `notify_dashboard/1` (C22, extracted in
     T-027) and returns a GenServer `{:reply, ...}` tuple; moving it now would
     force a back-edge from `Aiur.Orchestrator.Slots` into `Aiur.Orchestrator`,
     violating the one-direction dependency rule. It stays in the facade,
     updated to call `Slots.max_concurrent_agent_status/1`. T-027 relocates it.

4. **Create `src/lib/aiur/orchestrator/dispatch_policy.ex`** defining
   `defmodule Aiur.Orchestrator.DispatchPolicy`. Move, verbatim:
   - `read_load/1` (2345–2351, with its `@doc false` comment and `@spec`)
   - `prewarm_gate/2` (2374–2381, with comment and `@spec`)
   - `load_gate/3` (2383–2393, with comment and `@spec`) — all five clauses,
     clause order unchanged
   - `sort_issues_for_dispatch/1` (3548–3556)
   - `priority_rank/1` (3558–3559)
   - `issue_created_at_sort_key/1` (3561–3566)
   - `should_dispatch_issue?/4` (3568–3573)
   - `dispatch_candidate?/4` (3575–3593, including the "all dispatch
     preconditions except the global active+paused slot reservation" comment)
   - `state_slots_available?/2` (3594–3600)
   - `effective_state_limit/2` (3602–3616, including the session-aware-cap
     comment — FI-ORC-010)
   - `running_issue_count_for_state/2` (3618–3628)
   - `candidate_issue?/3` (3630–3646)
   - `issue_routable_to_worker?/1` (3648–3652)
   - `todo_issue_blocked_by_non_terminal?/2` (3654–3669)
   - `terminal_issue_state?/2` (3671–3675)
   - `active_issue_state?/2` (3677–3685, including its nil-safety comment)
   - `normalize_issue_state/1` (3687–3696, including its nil-safety comment)
   - `state_slug/1` (3698–3708)
   - `terminal_state_set/0` (3710–3715)
   - `active_state_set/0` (3717–3722)
   - Aliases needed: `alias Aiur.{Config, Issue, SystemLoad}` and
     `alias Aiur.Orchestrator.{Slots, State}`. Moved bodies that called
     `available_slots/1`, `worker_slots_available?/1`, or
     `max_concurrent_agent_limit/1` now call them on `Slots`;
     `running_issue_count_for_state/2` calls `State.active_running_entry?/1`.
   - `terminal_issue_state?/2`, `active_issue_state?/2`, `priority_rank/1`,
     `issue_created_at_sort_key/1`, and `shift_started_at_by_pause_if/3` (in
     State) are helper closures of the moved functions; they are not in the
     name map's key-function list but sit inside the census line ranges (C18,
     C26) and MUST move with their callers.

5. **Edit `src/lib/aiur/orchestrator.ex` (the facade):**
   - Delete every moved definition (and its moved comments) listed above.
   - Add `alias Aiur.Orchestrator.{DispatchPolicy, EventTopics, Slots, State}`
     next to the existing `alias Aiur.Orchestrator.TrackedSet`. Because the
     struct module name is unchanged, every `%State{}` pattern in the facade
     keeps compiling as-is.
   - For `read_load/1`, `prewarm_gate/2`, `load_gate/3` — public functions
     pinned by `test/aiur/orchestrator_load_gate_test.exs` and
     `test/aiur/orchestrator_prewarm_gate_test.exs` calling
     `Orchestrator.load_gate/3` etc. — keep the existing `@doc false` and
     `@spec` lines in the facade and replace each implementation with
     `defdelegate read_load(threshold), to: DispatchPolicy` (and likewise for
     the other two).
   - For every other moved function still referenced by remaining facade code
     (its `handle_*` clauses, public client API, or the `*_for_test` seams at
     lines 2425–2652), keep a one-line delegating `defp` with the same name
     and arity, e.g.
     `defp available_slots(state), do: Slots.available_slots(state)`.
   - Do NOT create a delegate for a moved function with no remaining facade
     references (e.g. `tag_topic/2`) — an unused `defp` fails
     `--warnings-as-errors`. Mechanical loop: add delegates for everything,
     run `mix compile --warnings-as-errors`, delete exactly the delegates the
     compiler reports as unused, repeat until clean.
   - The `*_for_test` seam functions themselves (e.g.
     `parse_pr_review_comment_topic_for_test/1`, `slot_status_for_test/1`,
     `should_dispatch_issue_for_test`/`dispatch_candidate_for_test`/
     `retry_candidate_issue` seams) are NOT moved, renamed, or re-typed —
     their bodies keep working through the delegating `defp`s.
   - `choose_issues/2` (3489–3517), `maybe_schedule_startup_todo_alert`
     (3519–3546), `maybe_dispatch`/`do_maybe_dispatch`/`maybe_choose_under_load`
     /`maybe_choose`/`log_load_hold`/`trigger_and_status`/`maybe_log_base_error`
     (2185–2343, 2353–2372), and `dispatch_issue/4` (3725+) all STAY in the
     facade — they move in T-023.

6. **Edit `src/mix.exs`:** remove the single entry `Aiur.Orchestrator.State`
   from `test_coverage.ignore_modules` (it was exempt as a bare struct; it now
   carries real logic and gets its own test file). Do NOT add
   `Aiur.Orchestrator.EventTopics`, `Aiur.Orchestrator.DispatchPolicy`, or
   `Aiur.Orchestrator.Slots` to the list — new modules are not
   coverage-exempt; the 85% threshold enforces their tests. Do not touch any
   other entry.

7. **Create one test file per new module** (new files; never touch existing
   test files):
   - `src/test/aiur/orchestrator/state_test.exs` — cover: the four entry
     predicates on `%{control: %{status: ...}}` maps; `active_running_count`/
     `paused_running_count` over mixed running maps and non-map input;
     `find_running_by_identifier`/`find_running_key_by_identifier` (integer
     vs string identifier via `to_string`)/`find_running_by_repl_pane_id`/
     `find_issue_id_for_ref`; `pop_running_entry`; `maybe_put_runtime_value`
     (nil value is a no-op); and the clock invariants of FI-ORC-033:
     `apply_pause_runtime_clock` stamps `paused_at` on :working→:paused and
     shifts on :paused→:working; `shift_started_at_by_pause` with
     `paused_reason: :max_agent_duration` only clears `paused_at` and does
     NOT advance `started_at` (the #420 leak), while an ordinary pause shifts
     `started_at` forward by the paused interval; `effective_runtime_seconds`
     freezes at `paused_at`.
   - `src/test/aiur/orchestrator/event_topics_test.exs` — cover:
     `classify_event_topic` returns the correct tagged tuple for each of the
     six topic shapes (`ticket.42.pr.review_comment`,
     `ticket.42.issue.commented`, `ticket.42.pr.merged`,
     `ticket.42.agent.pause.request`, `ticket.42.branch.push`,
     `system.main.branch.push`) and `:nomatch` for an unknown topic; parsers
     reject prefixed/suffixed topics (anchors `\A`/`\z`).
   - `src/test/aiur/orchestrator/dispatch_policy_test.exs` — cover:
     `load_gate/3` and `prewarm_gate/2` full truth tables (mirror the cases in
     `test/aiur/orchestrator_load_gate_test.exs` /
     `orchestrator_prewarm_gate_test.exs` — do not edit those files);
     `read_load/1` returns `:unavailable` for nil/0/negative threshold;
     `sort_issues_for_dispatch` orders by priority rank 1–4 then rank 5, then
     `created_at` (missing dates last), then identifier;
     `candidate_issue?/3` requires binary id/identifier/title/state and
     rejects nil-state issues without crashing;
     `todo_issue_blocked_by_non_terminal?/2` treats an unknown blocker state
     as blocking; `normalize_issue_state`/`state_slug` on mixed
     case/whitespace/nil; `issue_routable_to_worker?/1` defaults true.
   - `src/test/aiur/orchestrator/slots_test.exs` — cover:
     `max_concurrent_agent_limit` precedence (session override > state field;
     build `%State{}` structs with those fields set so `Config.settings!()`
     is not consulted); `available_slots` = cap − (active + paused), floored
     at 0 (FI-ORC-011: a paused entry consumes a slot);
     `max_concurrent_agent_status` reports `draining?: true` when active >
     max; `running_worker_host_count` counts only active entries on the host;
     `launch_max_concurrent_agents_override` reads the app env (set/restore
     it inside the test, non-async).
   - Follow the authoring rules in `docs/refactor/regression-safety.md` §2:
     no `Process.sleep` synchronization, no exact counts on shared
     singletons, `assert_receive` windows ≥ 2000 ms (these tests should need
     none of that — they are pure-function tests).

8. **Run the Agent gate** (below) after each of steps 1–7 lands, and once at
   the end. Every existing test — including all of
   `src/test/aiur/regression/` and every
   `src/test/aiur/orchestrator_*_test.exs` — must pass with zero edits to any
   test file.

## Files

- Create: `src/lib/aiur/orchestrator/state.ex`,
  `src/lib/aiur/orchestrator/event_topics.ex`,
  `src/lib/aiur/orchestrator/dispatch_policy.ex`,
  `src/lib/aiur/orchestrator/slots.ex`,
  `src/test/aiur/orchestrator/state_test.exs`,
  `src/test/aiur/orchestrator/event_topics_test.exs`,
  `src/test/aiur/orchestrator/dispatch_policy_test.exs`,
  `src/test/aiur/orchestrator/slots_test.exs`
- Modify: `src/lib/aiur/orchestrator.ex`, `src/mix.exs`
- Test: the four created test files above; all existing
  `src/test/aiur/orchestrator_*_test.exs` and `src/test/aiur/regression/`
  files run unmodified as the behavior pin.

## Out of scope

- `choose_issues/2`, `maybe_schedule_startup_todo_alert/5`, `dispatch_issue/4`
  and the whole dispatch-execution/thrash-breaker cluster, `RetryEngine`, and
  `Reconciler` — T-023.
- `apply_session_max_concurrent_agents/2` relocation and everything in C22
  (`notify_dashboard/1`, status/snapshot builders) — T-027.
- `Aiur.Orchestrator.TrackedSet` (`src/lib/aiur/orchestrator/tracked_set.ex`)
  and `issue_tracked?/1` / the tracked-set install/refresh functions — they
  stay in place permanently (Publisher closure contract).
- The `*_for_test` seam API: no seam is added, removed, renamed, or re-typed.
- Any edit to any existing file under `src/test/` (including moving tests to
  match the new modules — that is wave-6 cleanup in T-027).
- Any change to `init/1` ordering, `terminate/2`, subscriptions, timers,
  `handle_info`/`handle_call`/`handle_cast` clause heads, or any
  `Process.send_after`/`monitor`/`cancel_timer` site.
- Any behavior, signature, log-message, or config change whatsoever.
- Other giant files (`github/client.ex`, `init.ex`, `agent_runner.ex`, …).

## Inventory-IDs

From `docs/refactor/feature-inventory/orc.md` — the features whose
implementing functions this ticket moves (behavior must be identical after
the move):

- FI-ORC-002 (session cap never clobbered by refresh — `max_concurrent_agent_limit` precedence)
- FI-ORC-007 (event-topic classifier and its six patterns)
- FI-ORC-008 (dispatch ordering — `sort_issues_for_dispatch`)
- FI-ORC-009 (dispatch candidate gates — `candidate_issue?`, `dispatch_candidate?`, `should_dispatch_issue?`, nil-state safety)
- FI-ORC-010 (per-state concurrency caps — `effective_state_limit`, `running_issue_count_for_state`)
- FI-ORC-011 (global cap with paused-slot reservation — `available_slots`, active/paused counts)
- FI-ORC-012 (--max-agents override + runtime set/adjust — `launch_max_concurrent_agents_override`, `max_concurrent_agent_status`)
- FI-ORC-013 (prewarm dispatch gate — `prewarm_gate`)
- FI-ORC-014 (CPU load gate #465 — `load_gate`, `read_load`; /proc never read while disabled)
- FI-ORC-017 (SSH worker-host selection and per-host cap — `select_worker_host`, `least_loaded_worker_host`, `worker_host_slots_available?`)
- FI-ORC-024 (retry capacity gating helpers — `retry_candidate_issue?`, `dispatch_slots_available?`, `resume_worker_slot_available?`)
- FI-ORC-031 (duration cap uses pause-excluded runtime — `running_seconds`, `effective_runtime_seconds`)
- FI-ORC-033 (pause clock freeze/thaw and #420 no-credit semantics — `apply_pause_runtime_clock`, `thaw_pause_clock`, `shift_started_at_by_pause`)
- FI-ORC-040 (sleeping entries count as active — `sleeping_running_entry?`, `active_running_entry?`)

## Characterization-tests

- The orchestrator lifecycle & dispatch-gate characterization file(s) landed
  by T-007 under `src/test/aiur/regression/` (named
  `orchestrator_*_test.exs` there). The entire `src/test/aiur/regression/`
  directory must pass UNMODIFIED.
- Existing behavior pins that must also pass unmodified (they construct
  `%Aiur.Orchestrator.State{}` directly and call the `*_for_test` seams —
  both stay stable through this wave):
  `src/test/aiur/orchestrator_load_gate_test.exs`,
  `src/test/aiur/orchestrator_prewarm_gate_test.exs`,
  `src/test/aiur/orchestrator_max_agents_test.exs`,
  `src/test/aiur/orchestrator_max_duration_test.exs`,
  `src/test/aiur/orchestrator_status_test.exs`,
  `src/test/aiur/orchestrator_deactivate_test.exs`,
  `src/test/aiur/orchestrator_thrash_test.exs`,
  `src/test/aiur/core_test.exs`, `src/test/aiur/workspace_and_config_test.exs`.

A failing characterization test means your change is wrong. Never edit the
test. Stop: comment on the issue describing the failing test, emit
`emit_alert` with `needs_attention: true`, and end your turn without opening
a PR.

## Acceptance criteria

All checks run from the repo root; every one must hold:

- New modules exist at exact paths:
  - `grep -c "^defmodule Aiur.Orchestrator.State do" src/lib/aiur/orchestrator/state.ex` == 1
  - `grep -c "^defmodule Aiur.Orchestrator.EventTopics do" src/lib/aiur/orchestrator/event_topics.ex` == 1
  - `grep -c "^defmodule Aiur.Orchestrator.DispatchPolicy do" src/lib/aiur/orchestrator/dispatch_policy.ex` == 1
  - `grep -c "^defmodule Aiur.Orchestrator.Slots do" src/lib/aiur/orchestrator/slots.ex` == 1
- Each new module has a `@moduledoc`: `grep -c "@moduledoc" <file>` >= 1 for
  all four lib files; `mix lint` (which runs `specs.check`) passes, proving
  `@spec` on every public def.
- The moved concerns are gone from the facade:
  - `grep -c "defmodule State do" src/lib/aiur/orchestrator.ex` == 0
  - `grep -c '\\Aticket' src/lib/aiur/orchestrator.ex` == 0 (all six topic
    regexes moved; there are exactly 5 such lines before this ticket, all in
    the moved block)
  - `grep -cE "defp (load_gate|prewarm_gate|read_load)\(" src/lib/aiur/orchestrator.ex` == 0
    and `grep -cE "defdelegate (load_gate|prewarm_gate|read_load)" src/lib/aiur/orchestrator.ex` == 3
  - Any remaining `defp` in the facade with a moved function's name is a
    one-line delegation: for each name in the Scope lists,
    `grep -A1 "defp <name>(" src/lib/aiur/orchestrator.ex` shows only
    `do: State.…`/`do: EventTopics.…`/`do: DispatchPolicy.…`/`do: Slots.…`
    bodies (no multi-line logic).
- Parent file shrank: `wc -l < src/lib/aiur/orchestrator.ex` <= 7200
  (from 7,617; ~610 lines move out, delegates add back less than 150).
- File-size budget (per the research doc's ~LOC estimates; these moves cannot
  fit the generic 200-line norm without rewriting, which is forbidden):
  `state.ex` <= 400 lines, `event_topics.ex` <= 200, `dispatch_policy.ex`
  <= 450, `slots.ex` <= 350. No NEW function (anything not moved verbatim)
  exceeds 20 logic lines; moved bodies are not rewritten to game any limit.
- Coverage is enforced for the new modules:
  - `grep -c "Aiur.Orchestrator.State" src/mix.exs` == 0
  - `grep -cE "Aiur\.Orchestrator\.(EventTopics|DispatchPolicy|Slots)" src/mix.exs` == 0
  - all four test files exist:
    `ls src/test/aiur/orchestrator/{state,event_topics,dispatch_policy,slots}_test.exs`
- No test file changed:
  `git diff --name-only origin/v2 -- src/test/` is empty.
- The full Agent gate below is green.

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

- `cd src && mix test --cover` — the 85% threshold passes with the four new
  modules counted (none in `ignore_modules`).
- Diff review: every hunk in `src/lib/aiur/orchestrator.ex` is a deletion, a
  one-line delegate, the alias line, or the three `defdelegate`s — zero logic
  edits. The four new lib files contain only moved bodies plus
  `@moduledoc`/`@spec`/aliases.
- FI-ORC-014 spot-check: `Orchestrator.load_gate(99.0, nil, 12)` returns
  `:dispatch` and `Orchestrator.read_load(nil)` returns `:unavailable` in
  `iex -S mix` — the public seams survived (this is what
  `orchestrator_load_gate_test.exs` pins).
- FI-ORC-011/012 spot-check: run `orchestrator_max_agents_test.exs` alone
  (`mix test test/aiur/orchestrator_max_agents_test.exs`) — paused-slot
  reservation and session-cap precedence unchanged.
- FI-ORC-033 spot-check: run `orchestrator_max_duration_test.exs` alone —
  pause freeze/thaw and the #420 no-credit rule unchanged.
- Confirm `git log --oneline` shows no commit touching
  `src/test/aiur/regression/` and the tripwire CI check (T-005) is green.
- Fleet health: the phase-3 aiur run on `v2` stays healthy after merge
  (dispatch, pause/resume, and event routing all exercise the moved code on
  every tick).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
