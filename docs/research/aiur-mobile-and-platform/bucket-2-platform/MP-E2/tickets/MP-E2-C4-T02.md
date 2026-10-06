---
ticket_id: MP-E2-C4-T02
feature_id: MP-E2
chunk_id: MP-E2-C4
bucket: 2-platform
title: Codex capture-and-hold of requestUserInput behind a config gate
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C4-T00, MP-E2-C4-T01]
prior_units: [U4, U6]
prior_boundaries: [CDX #21, RUN #18, LIFECYCLE]
prior_features: [MP-R7 (MP-R7-C2-T02 reserved callbacks; plan §9 pre-R7 rule)]
prior_findings: [D10, R-Q1, contract §10 item 6, harness-adapter §6 items 1–2]
size_owner: "CODEX (codex/approvals.ex 356 — one call site); AGENT_CORE (app_server/turn_loop.ex 152); LIFECYCLE (runtime_watchdog.ex 376, token_accounting.ex) — guard lines only"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C4-T02 — Codex capture-and-hold of `requestUserInput` behind a config gate

## Identity and outcome

- Bucket 2, MP-E2, chunk C4.
- **User value:** a Codex worker that asks a real question waits for the answer inside
  the tool call, and is not killed as "stalled" or paused for overrunning while it waits.
- **Deliverable:**
  1. Config `decisions.native_capture.codex` (default `false`).
  2. With the gate on, the non-approval branch of the Codex `requestUserInput` handler calls
     `NativeCapture.capture/2` and keeps the JSON-RPC request unanswered (held).
  3. Loop state `held_native_questions`, events `:native_question_held` /
     `:native_question_resolved`, running-entry `:native_hold`, watchdog exemptions.
- **Non-goals:** replying (C4-T03); release paths (C4-T04); launch flag (C4-T05).

## Dependencies and blockers

- **DESIGN-E2** (§6.8 unit-row copy is C7-T03; this ticket shows nothing new);
  **C4-T00** PASS on Q1–Q3; C4-T01.
- **Pre-R7 rule (plan §9):** if MP-R7-C3/C4 has not moved the Codex adapter, the only
  edit in `codex/approvals.ex` is one call into `Aiur.Commands.NativeCapture.Codex`
  (PROPOSED thin module) so MP-R7 moves one call site. If MP-R7-C2-T02 has landed, also
  report `native_question: :in_band_hold` for codex when the gate is on (C4-T05).
- May run concurrently with C4-T03 (different files) after C4-T01.

## Verified starting point (`45a290e3`)

- `src/lib/aiur/codex/approvals.ex:148-169` requestUserInput clause; `:241-258`
  auto-approve branch (non-approval → `:256` non-interactive answer); `:260-262` gate-off
  branch; `:264-281` non-interactive reply; return values `:approved | :approval_required
  | :input_required | :unhandled | {:error, :port_closed}` (`:23`).
- `src/lib/aiur/codex/turn_loop.ex:153-215` maps those returns (`:approved` →
  `{:continue, OperatorDelivery.maybe_process_safe_checkpoint(…)}` `:187-189`).
- `src/lib/aiur/app_server/turn_loop.ex:9-52` receive loop; `after state.timeout_ms`
  `:48-50` (idle timeout = `agent.turn_timeout_ms`, set at `app_server/adapter.ex:113`).
  Loop state built at `app_server/adapter.ex:106-125` (+ `backend.loop_state_extras/1`).
- Watchdog: stall `orchestrator/runtime_watchdog.ex:322-375` (`last_activity_timestamp/1`
  `:373-375`); max duration `:56-75` (`maybe_pause_overrunning_entry/5`).
- Running-entry updates from worker events: `orchestrator/token_accounting.ex:44-60`
  (`integrate_codex_update/2`), routed from `orchestrator.ex:144-149`.
- Turn context: `metadata`/`execution_context` in `codex/turn_loop.ex:156-163`
  (`tool_call_scope` = issue identifier; `tool_call_thread_id`).

## Chosen design

- **Gate:** `Config.decisions_native_capture?(:codex)`; off ⇒ byte-identical behaviour.
- **Where:** in `maybe_auto_answer_tool_request_user_input/8` (both clauses), before
  replying non-interactively: `NativeCapture.Codex.handle(port, id, params, ctx)`:
  - builds the normalized map (`native_ref = "codex:" <> thread_id <> ":" <> turn_id <> ":" <> to_string(id)`);
  - `capture/2` → `{:policy, :approval}` ⇒ fall through to today's code;
    `{:release, text}` ⇒ reply `{"answers": {qid: {"answers": [text]}}}` for every question
    (today's shape) and return `:approved`;
    `{:command, decision}` ⇒ return the new atom `{:held, native_ref, hold_info}`.
- `Aiur.Codex.TurnLoop.handle_turn_method/5` maps `{:held, ref, info}` to
  `{:continue, put_in(state.held_native_questions[ref], info)}` and emits
  `:native_question_held` (`%{decision_id, native_ref, since}`) via `Messages.emit_message/4`.
  No safe-checkpoint processing while held (the turn is blocked inside the tool).
- **Loop state:** `held_native_questions: %{}` added in `app_server/adapter.ex:106-125`
  (shared default; only Codex fills it now; Claude C5 reuses it).
- **Watchdogs:** `TokenAccounting.integrate_codex_update/2` sets
  `running_entry.native_hold = %{decision_id, since}` on `:native_question_held` and
  clears it on `:native_question_resolved`. `RuntimeWatchdog`:
  `maybe_restart_stalled_entry/5` and `maybe_pause_overrunning_entry/5` return `state`
  unchanged when `:native_hold` is set. The receive loop's own idle timeout remains the
  hard bound (C4-T04 releases there).
- **Unrelated operator messages while held:** `{:agent_queue_updated, …, true}` must not
  interrupt the turn (an interrupt would cancel the pending tool). With a non-empty
  `held_native_questions`, `Interrupts.handle_operator_queue_update/2`
  (`app_server/interrupts.ex:35-54`) first offers the queue to the native-reply claimer
  (C4-T03); if nothing matches it returns `{:continue, state}` (the item waits for the
  turn boundary, today's `queue_next` behaviour).

## Implementation steps

1. Config field `decisions.native_capture.codex` + accessor + docs entry (same embed
   pattern as C2-T05; `reference/configuration.md`).
2. PROPOSED `src/lib/aiur/commands/native_capture/codex.ex` (≈120 lines).
3. `codex/approvals.ex`: one call in each non-approval branch; return type gains
   `{:held, String.t(), map()}`.
4. `codex/turn_loop.ex`: one `case` clause.
5. `app_server/adapter.ex`: `held_native_questions: %{}` default.
6. `app_server/interrupts.ex`: held guard in `handle_operator_queue_update/2`.
7. `orchestrator/token_accounting.ex` and `orchestrator/runtime_watchdog.ex`: the
   `:native_hold` set/clear and two guards.

## Non-happy paths

- Gate on but store unavailable → `{:release, …}` ⇒ today's text; never wedges the turn.
- Two questions in one turn → two held entries; both tracked.
- Pause/interrupt/port exit while held → C4-T04 (until it lands, keep this ticket's gate
  default `false` and do not enable it in any shipped config).
- Malformed request (no question ids) → today's `:input_required` path unchanged.
- Approval-shaped requests → never captured (D10), test below.

## Compatibility and rollout

- Default off. Ships dark; C8-T04 decides default-on after the DESIGN-E2 owner decision
  about the `UnderDevelopment` Codex flag.
- Rollback: the gate keeps old behaviour; a Command created by a held request remains a
  normal Command.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur/codex/approvals_test.exs test/aiur/commands/native_capture/codex_test.exs \
  test/aiur/orchestrator/runtime_watchdog_test.exs test/aiur/app_server/interrupts_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| `approvals_test` "gate off: question fixture still gets the non-interactive answer" | one response frame with today's text | gate check |
| "gate on: question fixture creates a Command and sends no response" | zero frames written to the port double; return `{:held, ref, _}` | step 3 |
| "gate on: approval fixture still auto-approves" | `"Approve this Session"` frame | D10 fall-through |
| "gate on: secret fixture replies with the secret release text and stores nothing" | frame contains secret text; temp store has no question text | release branch |
| `runtime_watchdog_test` "entry with native_hold is not restarted as stalled" | stall elapsed > timeout, entry untouched | stall guard |
| "entry with native_hold is not paused for max duration" | as stated | max-duration guard |
| `app_server/interrupts_test` "queue update while held does not interrupt" | no `turn/interrupt` frame | interrupts guard |

Mutation check per row (worktree). Manual (AGENTS.md wrapper-tmux recipe, Executor repo
root only): run `scripts/aiurdev --test` with a scratch config setting
`decisions.native_capture.codex: true` and `codex.command: "codex app-server --enable default_mode_request_user_input"`;
prompt a Codex worker to ask a question; confirm the AgentList row stays running (not
stalled) and `/commands` shows the new Command; capture `0.1` to see the held tool call.

## Completion and handoff

- [ ] Gate, hold, watchdog exemptions; default off.
- Docs: `reference/configuration.md` (`decisions.native_capture.codex`).
- Dependents: C4-T03, C4-T04, C4-T05, C5-T02, C7-T03.
