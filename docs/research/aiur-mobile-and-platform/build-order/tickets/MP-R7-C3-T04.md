---
ticket_id: MP-R7-C3-T04
feature_id: MP-R7
chunk_id: MP-R7-C3
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Route orchestrator pane interrupts through the optional interrupt/1 callback
status: ready
blocked_by: [DESIGN-R7, MP-R7-C1-T01, MP-R7-C2-T01]
prior_units: [U4, U2]
prior_boundaries: [ORC (12), CTL (14), CLD (22), CA (20)]
prior_features: [integrations-09]
prior_findings: []
size_owner: n/a (orchestrator/interrupts.ex is 205 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C3-T04 — Orchestrator interrupts via `CodingAgent.interrupt/2`

## Identity and outcome

- Bucket 1, MP-R7, chunk C3. **User value:** none directly. The orchestrator
  stops calling `Aiur.Claude.ReplAgent.interrupt/1`; it asks the running
  entry's harness through the behaviour's existing optional `interrupt/1`
  callback. This is the seam MP-E7 uses when `steer` falls back to
  `emulated_interrupt` on a pane harness.
- **Deliverable:** `CodingAgent.interrupt(backend, session)` facade;
  `orchestrator/interrupts.ex` uses it at its two call sites.
- **Non-goals:** no change to the TUI `Esc`/Ctrl+C pane flow, the
  `:interrupt_not_supported` reply, Remote Control promotion
  (`orchestrator/remote_control_mode.ex`, allowlisted in C3-T05), or the
  app-server `turn/interrupt` path (`app_server/interrupts.ex`).

## Dependencies and blockers

- DESIGN-R7; MP-R7-C1-T01; MP-R7-C2-T01 (provides the `transport` field used for
  the nil-backend fallback below).
- Concurrency: parallel with C3-T01/T02/T03. Touches an orchestrator file:
  rebase over any open prior-U2 lifecycle PR on `orchestrator/interrupts.ex`.

## Verified starting point (base `45a290e3`)

- `src/lib/aiur/orchestrator/interrupts.ex` (205 lines):
  - :7 `alias Aiur.Claude.ReplAgent`.
  - `interrupt_agent_reply/2` :68-79: running entry with a binary
    `repl_pane_id` → `ReplAgent.interrupt(%{tmux: Aiur.Tmux, pane_id: pane_id})`;
    other running entry → `{:error, :interrupt_not_supported}`; none →
    `{:error, :not_running}`.
  - `perform_pane_interrupt(:interrupt, …)` :137-148 ignores the result
    (`_ = ReplAgent.interrupt(…)`) by design (comment :138-143).
- `Aiur.Claude.ReplAgent.interrupt/1` is `defdelegate … to: OperatorInject`
  (`claude/repl_agent.ex:113`); `OperatorInject.interrupt/1`
  (`claude/repl/operator_inject.ex:60-64`) sends Ctrl+C; returns
  `{:error, :invalid_session}` without a pane id.
- Behaviour: `@callback interrupt(session()) :: :ok | {:error, term()}` with
  `@optional_callbacks interrupt: 1` (`coding_agent/backend.ex:141-147`).
  Only the REPL adapter implements it (`git grep "def interrupt"`: also
  `muse/turn_control.ex:7`, which is an internal turn-control function, not the
  callback).
- Running entry: the running backend is recorded at
  `running_entry.session_execution.backend` (`orchestrator/state.ex:440-458`);
  `repl_pane_id` is set by `handle_repl_session_runtime/3` (:421-438).
- Tests: `src/test/aiur/orchestrator/interrupts_test.exs`,
  `src/test/aiur/orchestrator_interrupt_test.exs`,
  `src/test/aiur/claude/repl/operator_inject_test.exs`.

## Chosen design

```elixir
# Aiur.CodingAgent (PROPOSED)
@spec interrupt(backend() | nil, Backend.session()) :: :ok | {:error, term()}
def interrupt(backend, session) do
  with {:ok, %{adapter: adapter}} <- Map.fetch(backends(), resolve_pane_backend(backend)),
       true <- function_exported?(adapter, :interrupt, 1) do
    adapter.interrupt(session)
  else
    _ -> {:error, :interrupt_not_supported}
  end
end
```

- `backend` comes from `get_in(running_entry, [:session_execution, :backend])`.
- `resolve_pane_backend(nil)`: a running entry can hold a `repl_pane_id`
  before `session_execution` is recorded (both arrive as separate runtime
  messages). Today the pane is interrupted regardless. To preserve that, a nil
  backend resolves to the single registry entry whose derived
  `transport == :tmux_pane` (MP-R7-C2-T01). The C1-T01 contract test gains the
  rule "at most one entry has `transport: :tmux_pane`"; if a second pane
  harness is ever added, this fallback must be revisited (the test fails first).
- Call `Code.ensure_loaded?/1` before `function_exported?/3`:
  `function_exported?/3` returns `false` for a module that is not yet loaded,
  which in interactive-mode test runs would misreport the callback as absent.
- The session argument stays `%{tmux: Aiur.Tmux, pane_id: pane_id}`; it is what
  the adapter's callback receives today.

## Implementation steps

1. Add `interrupt/2` and private `resolve_pane_backend/1` to `coding_agent.ex`
   with `@spec` and `@doc`.
2. `interrupts.ex`: drop the `ReplAgent` alias; at :71-72 and :147 call
   `CodingAgent.interrupt(running_backend(entry), %{tmux: Aiur.Tmux, pane_id: pane_id})`,
   with `running_backend/1` reading `session_execution.backend`.
3. Keep the `%{repl_pane_id: pane_id} when is_binary(pane_id)` match; it still
   decides whether a pane exists.
4. Add the "at most one tmux_pane entry" rule to MP-R7-C1-T01's test.

## Non-happy paths

- Backend without the callback but with a pane id (impossible today) →
  `{:error, :interrupt_not_supported}` — same reply the non-pane branch gives.
- Pane gone / tmux error: `OperatorInject.interrupt/1` result propagates in
  `interrupt_agent_reply/2` and is ignored in `perform_pane_interrupt/5`,
  exactly as today.
- Fallback to headless `claude` after a failed REPL spawn: no `repl_pane_id`
  → non-pane branch, unchanged.

## Compatibility and rollout

No config, CLI or rendered change. Rollback: revert.

## Verification

1. `src/test/aiur/coding_agent_test.exs`:
   `test "interrupt/2 dispatches to the adapter's optional callback"` — with
   backend `"claude-repl"` and a stub tmux module that records `send-keys`,
   the recorded keys equal what `OperatorInject.interrupt/1` sends. Mutation:
   make `interrupt/2` always return `{:error, :interrupt_not_supported}` → fails.
2. `test "interrupt/2 reports interrupt_not_supported for adapters without the callback"`
   — backend `"codex"` → `{:error, :interrupt_not_supported}`. Mutation: drop
   the `function_exported?` guard → `UndefinedFunctionError` fails the test.
3. `src/test/aiur/orchestrator/interrupts_test.exs`:
   `test "pane interrupt still fires before session execution is recorded"` —
   running entry with `repl_pane_id` and `session_execution: nil` → stub tmux
   receives Ctrl+C. Mutation: remove the nil fallback in
   `resolve_pane_backend/1` → test fails.
4. Existing interrupt tests pass unchanged (guards).

Commands (isolated `HOME`, GitHub tokens unset):

```text
env -C src mise exec -- mix test test/aiur/coding_agent_test.exs test/aiur/orchestrator/interrupts_test.exs test/aiur/orchestrator_interrupt_test.exs test/aiur/claude/repl/operator_inject_test.exs
mise exec -- rg -n 'ReplAgent' src/lib/aiur/orchestrator/interrupts.ex
```

Last command prints nothing. Manual (with the C4 foreground run): in the TUI,
open a `claude-repl` agent's chat pane, queue a message mid-turn and press the
interrupt key; `tmux capture-pane` shows the turn cut and the message
delivered, as before.

## Completion and handoff

- [ ] `interrupts.ex` names no Claude module.
- [ ] Tests 1–3 fail with their production hunks reverted (PR body lists commands).
- Docs: none.
- Dependents: MP-R7-C3-T05; MP-E7-C3/C4 (emulated-interrupt steer uses
  `CodingAgent.interrupt/2` for pane harnesses).
