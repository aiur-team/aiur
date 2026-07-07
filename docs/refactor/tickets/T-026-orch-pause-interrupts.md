# T-026: orchestrator wave 5: pause/resume, interrupts, RC, tokens

**Phase:** 3
**Depends-on:** T-025
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/orchestrator.ex` is a 7,617-line GenServer (774 def/defp clauses)
being decomposed into ~26 focused modules under `src/lib/aiur/orchestrator/`
per the binding name map in `docs/refactor/research-arch/giant-orchestrator.md`
§2. This is **wave 5 of 6** (T-022..T-027). Waves T-022..T-025 already
extracted 18 modules (`State`, `EventTopics`, `DispatchPolicy`, `Slots`;
`Dispatcher`, `RetryEngine`, `Reconciler`; `CommentWake`, `PrAnchored`,
`PushRouting`, `CommentPolling`, `CommandScan`; `IssueSync`,
`AutoSubscriptions`, `TrackerHealth`, `OperatorMessages`, `DigestCoalescer`).

This wave extracts four more: `Aiur.Orchestrator.PauseResume` (the
pause/resume/reactivate state machine), `Aiur.Orchestrator.Interrupts`
(Ctrl+C / pane-interrupt handling), `Aiur.Orchestrator.RemoteControlMode`
(promote/demote a running agent to remote control), and
`Aiur.Orchestrator.TokenAccounting` (codex-update integration plus token /
rate-limit payload parsing).

The pause/resume seam is regression hotspot material (giant-orchestrator.md §4,
risks 11–12): the max-agent-duration budget leak #420 was a mis-credited pause
clock, and the pause/resume/drain races are named refactor-caution zones. The
CRITICAL preserved semantics: an **operator** resume resets `started_at` (fresh
budget) while an **automated/blocker** resume preserves the cumulative overrun;
resume resets `last_codex_timestamp` so the stall watchdog grants a full window;
`do_reactivate` flips control to `:working` **before** dispatch to prevent a
double-claim race; token deltas stay monotonic (per-key highwater marks). This
is a verbatim code **MOVE, not a rewrite**: every function body is copied
byte-for-byte (comments included), public function signatures and observable
behavior are unchanged, and all extracted code keeps executing as plain function
calls inside the orchestrator GenServer process (no new processes, no GenServer
calls back into the orchestrator — that deadlocks; see risk 1).

## Scope (exact)

Line numbers below are from the current `main` snapshot of
`src/lib/aiur/orchestrator.ex` (7,617 lines). Waves T-022..T-025 will have
shifted them and moved many callees into sibling modules. **Locate every
function by its exact name/arity** (each name/arity is unique in the file); use
the line numbers only as orientation.

1. **Precondition check.** Verify these files exist (created by T-022..T-025):
   `src/lib/aiur/orchestrator/state.ex`,
   `src/lib/aiur/orchestrator/slots.ex`,
   `src/lib/aiur/orchestrator/dispatcher.ex`,
   `src/lib/aiur/orchestrator/comment_wake.ex`,
   `src/lib/aiur/orchestrator/operator_messages.ex`.
   If any is missing, STOP: comment the blocker on the issue and end your turn.
   Do not start extraction.

2. **Create `src/lib/aiur/orchestrator/pause_resume.ex`** defining
   `defmodule Aiur.Orchestrator.PauseResume`. Move these functions VERBATIM
   (bodies byte-identical, all comments included) out of
   `src/lib/aiur/orchestrator.ex`:

   Public (`def` + `@spec`; these are called from code remaining in
   `orchestrator.ex` OR from sibling modules — see step 7):
   - `resume_issue/2` (was ~5983)
   - `reactivate_issue/2` (was ~6013)
   - `pause_agent_reply/2` (was ~6025)
   - `send_pause_control_message/2` (was ~6048)
   - `resume_paused_issue/3` (was ~6214; KEEP the default arg `operator? \\ true`)

   Private (`defp`, internal-only to this module):
   - `pause_running_or_inactive/3` (was ~6039)
   - `do_reactivate/2` (was ~6185; move the "flip to :working before dispatch"
     comment block untouched — it documents risk 5)
   - `send_resume_control_message/3` (was ~6233; move ALL inline comment blocks
     — they document risks 11 and FI-ORC-055 verbatim)
   - `reset_last_codex_timestamp/3` (was ~6282)
   - `reset_duration_clock_if_capped/4` (was ~6307; move its comment header)
   - `maybe_reset_started_at/3` (both clauses, was ~6323-6324)
   - `resume_queued_issue/2` (was ~6423)
   - `put_running_control_status/3` (both clauses, was ~6456, ~6466)

3. **Create `src/lib/aiur/orchestrator/interrupts.ex`** defining
   `defmodule Aiur.Orchestrator.Interrupts`. Move these functions VERBATIM:

   Public (`def`; KEEP their existing `@doc` and `@spec` exactly — they are
   already public and are called directly by tests, see step 7):
   - `pane_interrupt_action/2` (was ~6155)
   - `pane_interrupt_action_no_pane/2` (was ~6176)

   Private (`defp`):
   - `interrupt_agent_reply/2` (was ~6059)
   - `pane_interrupt_reply/2` (was ~6080; move its comment header)
   - `perform_pane_interrupt/5` (all four clauses, was ~6114, ~6122, ~6125, ~6143)

4. **Create `src/lib/aiur/orchestrator/remote_control_mode.ex`** defining
   `defmodule Aiur.Orchestrator.RemoteControlMode`. Move these functions
   VERBATIM:

   Private (`defp`):
   - `set_remote_control_reply/3` (was ~6540)
   - `promote_to_remote/2` (was ~6557)
   - `do_promote_to_remote/3` (was ~6590)
   - `demote_from_remote/2` (was ~6611)
   - `teardown_for_redispatch/2` (was ~6649; move the "demonitors BEFORE kill"
     comment untouched — FI-ORC-057 ordering)
   - `add_issue_label/2` (was ~6672)
   - `remove_issue_label/2` (was ~6677)
   - `rc_log_context/1` (was ~6682)
   - `remote_control_trust_opts/0` (was ~6688)
   - `remote_control_summary/1` (was ~6722)
   - `cleanup_stray_remote_control_servers/0` (was ~6734)

5. **Create `src/lib/aiur/orchestrator/token_accounting.ex`** defining
   `defmodule Aiur.Orchestrator.TokenAccounting`. Move these functions VERBATIM:

   Public (`def` + `@spec`):
   - `integrate_codex_update/2` (was ~6766)
   - `apply_agent_token_delta/2` (both clauses, was ~6972, ~6980)
   - `apply_agent_rate_limits/2` (both clauses, was ~6982, ~6992)
   - `record_session_completion_totals/2` (both clauses, was ~6871, ~6888)

   Private (`defp`):
   - `codex_app_server_pid_for_update/2` (all clauses, was ~6796-6807)
   - `session_id_for_update/2` (both clauses, was ~6809, ~6812)
   - `turn_count_for_update/3` (all clauses, was ~6814, ~6826, ~6830)
   - `summarize_codex_update/1` (was ~6832)
   - `apply_token_delta/2` (both clauses, was ~6994, ~6997)
   - `extract_token_delta/2` (was ~7013)
   - `compute_token_delta/4` (was ~7050)
   - `extract_token_usage/1` (was ~7067)
   - `extract_rate_limits/1` (was ~7082)
   - `absolute_token_usage_from_payload/1` (both clauses, was ~7091, ~7106)
   - `turn_completed_usage_from_payload/1` (both clauses, was ~7108, ~7122)
   - `rate_limits_from_payload/1` (all clauses, was ~7124, ~7139, ~7143)
   - `rate_limit_payloads/1` (both clauses, was ~7145, ~7159)
   - `rate_limits_map?/1` (both clauses, was ~7173, ~7189)
   - `explicit_map_at_paths/2` (both clauses, was ~7191, ~7199)
   - `map_at_path/2` (both clauses, was ~7201, ~7211)
   - `integer_token_map?/1` (was ~7213)
   - `get_token_usage/2` (all clauses, was ~7244, ~7258, ~7273)
   - `payload_get/2` (both clauses, was ~7284, ~7288)
   - `map_integer_value/2` (was ~7290)
   - `integer_like/1` (all clauses, was ~7321, ~7323, ~7330)

   Do NOT move `running_seconds/2` (~7299) or `effective_runtime_seconds/2`
   (~7309): the name map places them in `Aiur.Orchestrator.State` (T-022). By
   this wave they already live there; `record_session_completion_totals/2`
   calls them as `State.effective_runtime_seconds/2` (see step 6).

6. **Module heads.** Each new module gets: a `@moduledoc` (2–4 lines stating
   its one-sentence responsibility from the name map, plus "All functions
   execute inside the orchestrator GenServer process."), the aliases its moved
   code references copied from `orchestrator.ex`'s head (e.g. for RC:
   `alias Aiur.Orchestrator`, `alias Aiur.Orchestrator.State`, `alias Aiur.Issue`,
   `alias Aiur.Claude.RemoteControl`, `alias Aiur.Claude.ReplAgent`,
   `Tracker`, `CodingAgent`, `require Logger`; for PauseResume add
   `alias Aiur.Orchestrator.{Slots, Dispatcher, CommentWake, OperatorMessages}`;
   for Interrupts add `alias Aiur.Opencode.ActiveTurns` and the same siblings;
   for TokenAccounting typically just `alias Aiur.Orchestrator.State` and
   possibly none else — `mix compile --warnings-as-errors` flags unused
   aliases), and `@spec` on every public `def` (`mix credo --strict` runs
   `specs.check`, which enforces this).

7. **Rewrite intra-move references (no logic changes).** Inside the moved
   bodies, qualify calls whose targets now live in a sibling module. First
   `grep -rn "def <name>" src/lib/aiur/orchestrator/` to confirm each target's
   actual home (earlier waves are the binding placement); then qualify:

   - Extracted by T-022 `State` → `State.find_running_by_identifier/2`,
     `State.find_running_key_by_identifier/2`, `State.paused_running_entry?/1`,
     `State.maybe_put_runtime_value/3`, `State.running_seconds/2`,
     `State.effective_runtime_seconds/2`, `State.thaw_pause_clock/4`,
     `State.shift_started_at_by_pause/2`, `State.apply_pause_runtime_clock/4`.
   - Extracted by T-022 `Slots` → `Slots.resume_worker_slot_available?/2` and
     the cap/state slot checks `resume_paused_issue/3` uses.
   - Extracted by T-023 `Dispatcher` → `Dispatcher.reset_thrash_budget/2`,
     `Dispatcher.do_dispatch_issue/4`.
   - Extracted by T-024 `CommentWake` → `CommentWake.transition_control_status/4`
     (called by `pause_agent_reply`/`perform_pane_interrupt`).
   - Extracted by T-025 `OperatorMessages` →
     `OperatorMessages.send_running_control_message/3`,
     `OperatorMessages.maybe_emit_agent_control_alert/3`,
     `OperatorMessages.issue_control_capabilities/2`,
     `OperatorMessages.queue_depth_for_issue/2`,
     `OperatorMessages.enqueue_after_reactivate/4`,
     `OperatorMessages.enqueue_after_resume/4`.
     If a grep shows a different home for any of these, call it where it
     actually lives.

   - Targets STILL in `orchestrator.ex` (they belong to LATER wave T-027, or
     are the facade-retained tracked-set function). If the target is still a
     `defp`, flip it to `@doc false def` with a `@spec`, body untouched, and
     call it as `Orchestrator.<name>(...)` (add `alias Aiur.Orchestrator`). If
     an earlier wave already made it public, leave it and just call it. Exact
     list your moved code references:
     `refresh_tracked_set/1` (facade-retained — Publisher closure contract),
     `close_active_chat_streams/2`, `terminate_task/1`, `kill_repl_session/1`
     (→ AgentTeardown, T-027).
   - Cross-references between the four NEW modules stay module-qualified:
     Interrupts' `perform_pane_interrupt(:pause, …)` calls
     `PauseResume.send_pause_control_message/2`; PauseResume's `resume_issue/2`
     calls its own `resume_paused_issue/3`, `resume_queued_issue/2`, and
     `reactivate_issue/2` (same module — unqualified).
   - Do NOT change `self()`, `Process.send_after/3`, `Process.cancel_timer/1`,
     `Process.monitor/1`, `Process.demonitor(ref, [:flush])`, or
     `Task.Supervisor.*` sites in any way — the moved code runs inside the
     orchestrator process; the RC `teardown_for_redispatch/2` demonitor-before-
     kill ordering and the pause-clock timing depend on it (risks 1, 3).

8. **In `src/lib/aiur/orchestrator.ex`:** delete every moved definition, then
   add a one-line wrapper — identical head (same name, arity, guards, default
   args) — ONLY for the moved functions that code remaining in
   `orchestrator.ex` OR sibling modules still call. Every other moved function
   is removed entirely (its callers were moved with it). Exact wrapper list:

   Public `@doc false def` wrappers (called by SIBLING modules via
   `Orchestrator.<name>`, so they MUST stay public):
   - → `PauseResume`: `reactivate_issue/2` (called by Reconciler/CommentWake/
     OperatorMessages), `resume_paused_issue/3` (called by PushRouting/
     OperatorMessages; keep `operator? \\ true`), `send_pause_control_message/2`
     (called by PushRouting).

   Public `def` wrappers with the SAME `@spec` (called directly by tests via
   `Orchestrator.<name>`):
   - → `Interrupts`: `pane_interrupt_action/2`, `pane_interrupt_action_no_pane/2`.

   Private `defp` wrappers (only facade-internal callers — `handle_call`
   clauses, `init/1`, `notify_dashboard`, and the `*_for_test` seams):
   - → `PauseResume`: `resume_issue/2`, `pause_agent_reply/2`.
   - → `Interrupts`: `interrupt_agent_reply/2`, `pane_interrupt_reply/2`.
   - → `RemoteControlMode`: `set_remote_control_reply/3`,
     `remote_control_summary/1`, `remote_control_trust_opts/0`,
     `cleanup_stray_remote_control_servers/0`.
   - → `TokenAccounting`: `integrate_codex_update/2`, `apply_agent_token_delta/2`,
     `apply_agent_rate_limits/2`, `record_session_completion_totals/2`.

   These moved functions get NO wrapper (delete outright — their only callers
   moved with them this wave): `pause_running_or_inactive/3`, `do_reactivate/2`,
   `send_resume_control_message/3`, `reset_last_codex_timestamp/3`,
   `reset_duration_clock_if_capped/4`, `maybe_reset_started_at/3`,
   `resume_queued_issue/2`, `put_running_control_status/3`,
   `perform_pane_interrupt/5`, `promote_to_remote/2`, `do_promote_to_remote/3`,
   `demote_from_remote/2`, `teardown_for_redispatch/2`, `add_issue_label/2`,
   `remove_issue_label/2`, `rc_log_context/1`, and every private
   `TokenAccounting` parser listed in step 5.

   Do NOT edit the bodies of `handle_call`/`handle_info`/`handle_cast` clauses,
   `handle_agent_down/2`, `init/1`, `terminate/2`, `notify_dashboard/1`, or any
   `*_for_test` seam — the wrappers keep every existing call site compiling
   unchanged. In particular the public client API (`pause_agent/2`,
   `resume_agent/2`, `interrupt_agent/2`, `pane_interrupt/2`,
   `pane_interrupt_by_pane_id/2`, `set_remote_control/3`,
   `ensure_remote_control_trust/2`, `note_agent_activity/2`) stays in the facade
   and keeps its exact signatures.

9. **Write the four test files** (new modules are NOT coverage-exempt; the 85%
   threshold plus this ticket's review enforce real tests). Build
   `%Aiur.Orchestrator.State{}` structs directly (all fields default); test
   through each module's public functions; no GenServer needed for the pure
   ones. For side-effecting reply functions, drive them exactly as the existing
   `orchestrator_*_test.exs` files do (via `handle_call` on a started
   orchestrator) is out of scope — instead assert the pure decision helpers and
   the parsers directly:
   - `src/test/aiur/orchestrator/interrupts_test.exs`:
     `pane_interrupt_action/2` returns `:interrupt` when `queue_depth > 0` and
     not paused, `:pause` when idle (`queue_depth == 0`, not paused), and
     `:close_pane` when paused (any depth); `pane_interrupt_action_no_pane/2`
     returns `:send_interrupt` when working and not paused, `:pause` when idle,
     `:close_pane` when paused (working or not) — the FI-ORC-056 decision table.
   - `src/test/aiur/orchestrator/token_accounting_test.exs`:
     `integer_like/1` accepts a non-negative integer and a numeric binary,
     rejects negatives/non-numeric (→ nil); `absolute_token_usage_from_payload/1`
     is preferred over `turn_completed_usage_from_payload/1` for a payload
     carrying both (FI-ORC-059: cumulative usage preferred); `apply_token_delta/2`
     adds a delta into `agent_totals` and initializes from `nil`;
     `compute_token_delta/4` never returns a negative delta (per-key highwater);
     `rate_limits_map?/1` is true only for an integer-valued rate-limit map.
     If a listed helper is `defp`, exercise it through the nearest public
     function (`integrate_codex_update/2` / `apply_agent_token_delta/2`) rather
     than making it public.
   - `src/test/aiur/orchestrator/pause_resume_test.exs`:
     `put_running_control_status/3` sets `control.status` for a known running id
     and is a no-op for an unknown id; `reset_last_codex_timestamp/3` stamps the
     given time on a known entry; `reset_duration_clock_if_capped/4` with
     `operator?: true` on a `%{paused_reason: :max_agent_duration}` entry resets
     `started_at` AND drops `:paused_reason`, while `operator?: false` PRESERVES
     `started_at` and still drops `:paused_reason` (risk 11 / FI-ORC-033); a
     non-`:max_agent_duration` entry is untouched. Exercise the private helpers
     through the module (they are `def`/`defp` on `PauseResume`; if `defp`, keep
     the smallest public surface needed and test via it).
   - `src/test/aiur/orchestrator/remote_control_mode_test.exs`:
     `remote_control_summary/1` returns `nil` unless the entry has BOTH the
     `model:remote` (alias) label AND a captured `session_url`, and returns
     `%{status: :on, session_url: url}` when both are present (FI-ORC-057 — this
     mirrors the existing `remote_control_summary_for_test` assertions in
     `orchestrator_remote_control_test.exs`); `add_issue_label/2` /
     `remove_issue_label/2` add/remove a label on an `%Issue{}` idempotently.
     If these are `defp`, add a `@doc false def` only where a test needs it and
     note it; do not otherwise widen visibility.

10. **Do not modify** `src/mix.exs` (the four new modules must NOT be added to
    `ignore_modules`), any existing test file, `src/lib/aiur/orchestrator/tracked_set.ex`,
    or the T-022..T-025 modules. After steps 2–9 the repo compiles
    warnings-free and the FULL suite passes (run the Agent gate below).

## Files

- Create: `src/lib/aiur/orchestrator/pause_resume.ex`,
  `src/lib/aiur/orchestrator/interrupts.ex`,
  `src/lib/aiur/orchestrator/remote_control_mode.ex`,
  `src/lib/aiur/orchestrator/token_accounting.ex`,
  `src/test/aiur/orchestrator/pause_resume_test.exs`,
  `src/test/aiur/orchestrator/interrupts_test.exs`,
  `src/test/aiur/orchestrator/remote_control_mode_test.exs`,
  `src/test/aiur/orchestrator/token_accounting_test.exs`
- Modify: `src/lib/aiur/orchestrator.ex`
- Test: the four new test files above; the entire existing suite must pass
  unmodified.

## Out of scope

- The other orchestrator modules. StatusReport, WorkspaceCleanup, HumanReview,
  AgentTeardown, RuntimeWatchdog are wave 6 (T-027); their functions stay in
  `orchestrator.ex` this wave. The only permitted touch to them is flipping the
  listed `defp` → `@doc false def` visibility of `close_active_chat_streams/2`,
  `terminate_task/1`, `kill_repl_session/1` (step 7) so RemoteControlMode can
  call them.
- The T-022..T-025 modules (`state.ex`, `slots.ex`, `dispatcher.ex`,
  `comment_wake.ex`, `operator_messages.ex`, and the rest) — call them, never
  edit them.
- The public client API and its `handle_call`/`handle_cast`/`handle_info`
  routing, `init/1`, `terminate/2`, tick scheduling, `notify_dashboard/1`, and
  tracked-set sync (`issue_tracked?/1`, `refresh_tracked_set/1` stay in the
  facade — Publisher closure contract).
- `ensure_remote_control_trust/2` (the serialized trust-seeding `handle_call`,
  FI-ORC-058) stays in the facade; only its helper `remote_control_trust_opts/0`
  moves (with a facade wrapper).
- `src/lib/aiur/orchestrator/tracked_set.ex`, `src/lib/aiur/agent_runner.ex`,
  `src/lib/aiur/tracker.ex`, `src/lib/aiur/coding_agent.ex`,
  `src/lib/aiur/claude/remote_control.ex`, `src/lib/aiur/claude/repl_agent.ex`
  — untouched.
- `src/mix.exs` — untouched (no new coverage exemptions, no dep changes).
- Every existing test file, including all `*_for_test` seam call sites and the
  `orchestrator_interrupt_test.exs` / `orchestrator_remote_control_test.exs`
  direct calls — test moves/renames are a later cleanup wave (research doc W29),
  not this ticket.
- Any behavior change: no renamed functions, no reordered clauses, no changed
  delays/limits/log strings/alert topics, no "improvements" to moved code.

## Inventory-IDs

From `docs/refactor/feature-inventory/orc.md` and
`docs/refactor/feature-inventory/cli.md` — this ticket's Files implement or
touch these entries; their behavior must be byte-for-byte preserved:

- **FI-ORC-011** — global cap with paused-slot reservation: `resume_paused_issue/3`
  gating on `active < cap` plus per-state/worker-host slots (bypassing
  `available_slots`); `resume_queued_issue/2` manual start gating on `active < cap`.
- **FI-ORC-033** — pause clock freeze/thaw + duration-budget semantics: the
  `reset_duration_clock_if_capped/4` / `maybe_reset_started_at/3` operator-vs-
  automated branch and `reset_last_codex_timestamp/3` on resume (the #420 fix —
  the clock-arithmetic half lives in `State` from T-022; this ticket owns the
  policy half).
- **FI-ORC-051** — operator-message enqueue with auto-resume/reactivate: the
  `reactivate_issue/2` (deactivated → fresh task) and `resume_paused_issue/3`
  (paused → resume through the cap gates) bodies now live in PauseResume and are
  driven from OperatorMessages (T-025) via the facade wrappers.
- **FI-ORC-054** — pause/resume/space-key control APIs: `pause_agent_reply/2`,
  `resume_issue/2` (deactivated → reactivate; paused → resume; working → no-op;
  none → `resume_queued_issue/2`), `do_reactivate/2` (flip-to-`:working`-before-
  dispatch race guard).
- **FI-ORC-055** — pause/unpause alerts: `send_resume_control_message/3` emits
  the unpause alert itself (via `OperatorMessages.maybe_emit_agent_control_alert/3`)
  because the sync-flip means the later `:worker_control_state` finds status
  unchanged.
- **FI-ORC-056** — Ctrl+C pane-interrupt state machine: `pane_interrupt_action/2`,
  `pane_interrupt_action_no_pane/2`, `perform_pane_interrupt/5`,
  `interrupt_agent_reply/2`, `pane_interrupt_reply/2` (REPL-pane vs pane-less
  decision tables; `:interrupt_not_supported` for non-REPL backends).
- **FI-ORC-057** — remote-control promote/demote toggle: the whole
  RemoteControlMode module — `remote_unsupported` for remote hosts, trust-first
  ordering, durable `model:remote` label, `teardown_for_redispatch/2` demonitor-
  before-kill, RC summary requiring BOTH label and session URL.
- **FI-ORC-058** — `ensure_remote_control_trust` (stays in facade) consumes the
  moved `remote_control_trust_opts/0` via the facade wrapper.
- **FI-ORC-059** — codex worker-update integration + token accounting: the whole
  TokenAccounting module — `integrate_codex_update/2`, monotonic per-key
  highwater deltas, cumulative-preferred usage, rate-limit payload landing,
  `turn_count` increment on new session id, session-completion runtime totals.
- **FI-CLI-035 / FI-CLI-036** — `aiur pause`/`aiur resume` aggregation the
  orchestrator backs: pause targets running+paused; resume targets only paused
  and can START an idle tracked issue (`resume_queued_issue/2` →
  `'started #N (was: idle)'`). The CLI aggregation itself lives in
  `AgentControlCLI` and is NOT touched; only the orchestrator functions it calls
  move here.

## Characterization-tests

All of `src/test/aiur/regression/` must pass UNMODIFIED. Specifically the
orchestrator characterization files landed by T-007 (Characterization:
orchestrator lifecycle & dispatch gates), which per
`research-arch/giant-orchestrator.md` §4 pin this wave's semantics: the
pause/resume duration-clock operator-vs-automated reset, the resume
`last_codex_timestamp` reset, and the **token-accounting payload shapes**
(absolute vs turn-completed usage, rate-limit paths) — the last was an explicit
W0 characterization gap written before this phase. List them at execution time
with `ls src/test/aiur/regression/ | grep -iE 'orch|token'` (they merge in Phase
1, before this ticket opens) and run them explicitly before opening the PR.

These existing (non-regression-dir) pins must also pass unmodified — they
exercise the moved code through the `*_for_test` seams, direct public calls, and
`handle_call` sends, which is why the seams and wrappers must keep identical
signatures:
`src/test/aiur/orchestrator_interrupt_test.exs` (calls
`Orchestrator.pane_interrupt_action/2`, `.pane_interrupt_action_no_pane/2`,
`.pane_interrupt/2`, `.interrupt_agent/2` directly),
`src/test/aiur/orchestrator_remote_control_test.exs` (calls
`Orchestrator.remote_control_summary_for_test/1` and drives set/promote/demote),
`src/test/aiur/orchestrator_status_test.exs` (token/rate-limit surfaces via
`:snapshot`, FI-ORC-059),
`src/test/aiur/orchestrator_max_duration_test.exs` (pause clocks, FI-ORC-033),
`src/test/aiur/orchestrator_deactivate_test.exs` (reactivate/resume + queue),
`src/test/aiur/core_test.exs`.

## Acceptance criteria

All greps run from the repo root; all must hold:

- `grep -c "defmodule Aiur.Orchestrator.PauseResume do" src/lib/aiur/orchestrator/pause_resume.ex` = 1
- `grep -c "defmodule Aiur.Orchestrator.Interrupts do" src/lib/aiur/orchestrator/interrupts.ex` = 1
- `grep -c "defmodule Aiur.Orchestrator.RemoteControlMode do" src/lib/aiur/orchestrator/remote_control_mode.ex` = 1
- `grep -c "defmodule Aiur.Orchestrator.TokenAccounting do" src/lib/aiur/orchestrator/token_accounting.ex` = 1
- `grep -c "@moduledoc" <file>` >= 1 for each of the four new modules.
- The facade shrinks by at least 1,000 lines vs the PR base:
  `test $(git show origin/v2:src/lib/aiur/orchestrator.ex | wc -l) -ge $(( $(wc -l < src/lib/aiur/orchestrator.ex) + 1000 ))`
  passes. (For orientation, the facade should land under ~2,600 lines after
  this wave; the residual facade plus wave-6 code is all that remains.)
- New-file size caps (TokenAccounting carries the research doc's documented
  exception to the 200-line norm — ~300 of it is pure payload parsing; do not
  split it further and do not exceed the caps):
  `wc -l < src/lib/aiur/orchestrator/pause_resume.ex` <= 450,
  `wc -l < src/lib/aiur/orchestrator/interrupts.ex` <= 250,
  `wc -l < src/lib/aiur/orchestrator/remote_control_mode.ex` <= 320,
  `wc -l < src/lib/aiur/orchestrator/token_accounting.ex` <= 520.
- Moved functions are moved, not rewritten: no NEW function body may exceed 20
  logic lines (wrappers are 1 line); moved bodies are byte-identical (verified
  at-merge via `--color-moved`).
- No pause/resume/interrupt/RC/token IMPLEMENTATION defs remain in the facade
  (wrapped names keep only a 1-line `def`/`defp` head + body; the un-wrapped
  ones below must be gone entirely):
  `grep -cE "^  defp (pause_running_or_inactive|do_reactivate|send_resume_control_message|reset_last_codex_timestamp|reset_duration_clock_if_capped|maybe_reset_started_at|resume_queued_issue|put_running_control_status)\(" src/lib/aiur/orchestrator.ex` = 0;
  `grep -cE "^  defp perform_pane_interrupt\(" src/lib/aiur/orchestrator.ex` = 0;
  `grep -cE "^  defp (promote_to_remote|do_promote_to_remote|demote_from_remote|teardown_for_redispatch|add_issue_label|remove_issue_label|rc_log_context)\(" src/lib/aiur/orchestrator.ex` = 0;
  `grep -cE "^  defp (extract_token_delta|compute_token_delta|apply_token_delta|extract_token_usage|extract_rate_limits|absolute_token_usage_from_payload|turn_completed_usage_from_payload|rate_limits_from_payload|rate_limit_payloads|rate_limits_map\?|explicit_map_at_paths|map_at_path|integer_token_map\?|get_token_usage|payload_get|map_integer_value|integer_like|summarize_codex_update|codex_app_server_pid_for_update|session_id_for_update|turn_count_for_update)\(" src/lib/aiur/orchestrator.ex` = 0.
- Each extracted public entry point has its real def in the new module:
  `grep -cE "def reactivate_issue\(" src/lib/aiur/orchestrator/pause_resume.ex` = 1,
  `grep -cE "def pane_interrupt_action\(" src/lib/aiur/orchestrator/interrupts.ex` = 1,
  `grep -cE "def pane_interrupt_action_no_pane\(" src/lib/aiur/orchestrator/interrupts.ex` = 1,
  `grep -cE "def integrate_codex_update\(" src/lib/aiur/orchestrator/token_accounting.ex` = 1.
- No token/rate-limit PARSING remains in the facade (only the four
  `TokenAccounting` wrappers may reference these names, and only by calling
  them): `grep -cE "^  defp (absolute_token_usage_from_payload|turn_completed_usage_from_payload|compute_token_delta)\(" src/lib/aiur/orchestrator.ex` = 0.
- The public client API is intact (unchanged in the facade):
  `grep -cE "def (pause_agent|resume_agent|interrupt_agent|pane_interrupt|set_remote_control|note_agent_activity)\(" src/lib/aiur/orchestrator.ex` >= 6.
- New modules are NOT coverage-exempt:
  `grep -cE "Orchestrator\.(PauseResume|Interrupts|RemoteControlMode|TokenAccounting)" src/mix.exs` = 0.
- A test file exists per extracted module:
  `test -f src/test/aiur/orchestrator/pause_resume_test.exs && test -f src/test/aiur/orchestrator/interrupts_test.exs && test -f src/test/aiur/orchestrator/remote_control_mode_test.exs && test -f src/test/aiur/orchestrator/token_accounting_test.exs`.
- `git diff --name-only origin/v2...HEAD` lists exactly the 9 files in
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

- Check: `git diff --color-moved=dimmed-zebra origin/v2...HEAD -- src/lib/aiur/orchestrator.ex src/lib/aiur/orchestrator/pause_resume.ex src/lib/aiur/orchestrator/interrupts.ex src/lib/aiur/orchestrator/remote_control_mode.ex src/lib/aiur/orchestrator/token_accounting.ex`
  shows the moved bodies as moved (dimmed), not rewritten; the only in-body
  edits are module-qualification of the calls listed in Scope step 7.
- Check (FI-ORC-033, risk 11): in `pause_resume.ex`,
  `reset_duration_clock_if_capped/4` calls `maybe_reset_started_at(entry, now, operator?)`
  then `Map.delete(entry, :paused_reason)`, and `maybe_reset_started_at/3` has
  the `true → Map.put(:started_at, now)` / `false → entry` split verbatim.
- Check (FI-ORC-055): in `pause_resume.ex`, `send_resume_control_message/3`
  emits the unpause alert via `OperatorMessages.maybe_emit_agent_control_alert(previous_status, :working, updated_entry)`
  itself, and the "Sync-flip happens here" comment survives.
- Check (FI-ORC-056): in `interrupts.ex`, `perform_pane_interrupt(:pause, …)`
  calls `PauseResume.send_pause_control_message/2` and
  `CommentWake.transition_control_status(state, entry, :paused, "pane.ctrl_c.pause")`;
  `interrupt_agent_reply/2` returns `{:error, :interrupt_not_supported}` for a
  non-REPL entry.
- Check (FI-ORC-057, risk 3): in `remote_control_mode.ex`,
  `teardown_for_redispatch/2` calls `Process.demonitor(ref, [:flush])` BEFORE
  `Orchestrator.terminate_task/1`, and `Orchestrator.close_active_chat_streams/2`
  BEFORE the kill; `remote_control_summary/1` returns non-nil only with BOTH the
  `CodingAgent.remote_control_alias_label()` label and a captured session URL.
- Check (FI-ORC-059): in `token_accounting.ex`, `extract_token_delta/2` prefers
  `absolute_token_usage_from_payload/1` over `turn_completed_usage_from_payload/1`,
  and `compute_token_delta/4` keeps deltas non-negative (highwater).
- Run the named pins:
  `mix test test/aiur/orchestrator_interrupt_test.exs test/aiur/orchestrator_remote_control_test.exs test/aiur/orchestrator_status_test.exs test/aiur/orchestrator_max_duration_test.exs test/aiur/orchestrator_deactivate_test.exs test/aiur/core_test.exs test/aiur/orchestrator test/aiur/regression`
  — all green with zero skips.
- Behavior spot-check on `v2` after merge: start `aiurdev` against the sandbox
  repo, pause a running agent (`aiur pause <id>`) and resume it
  (`aiur resume <id>`); confirm the unpause alert fires once and the agent keeps
  its session/turn context (unchanged log strings), and that `aiur agents`
  still shows token totals climbing for a working agent.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
