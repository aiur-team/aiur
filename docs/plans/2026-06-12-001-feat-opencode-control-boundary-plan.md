---
title: opencode<->Aiur Control Boundary
status: active
created: 2026-06-12
origin: docs/brainstorms/2026-06-12-opencode-control-boundary-requirements.md
scope: issue-101 opencode/codex Remote-Control agents only
---

# opencode<->Aiur Control Boundary — Implementation Plan

Builds the three mechanisms decided in the requirements doc
(`docs/brainstorms/2026-06-12-opencode-control-boundary-requirements.md`).
Scope is strictly opencode/codex RC slot agents (the no-pane backend path);
claude-repl and non-RC agents are untouched.

## Problem recap (proven from logs)

Aiur decides queue/pause/close/resume from state it cannot see. Operator
text typed in an opencode pane lives in opencode's **native** queue, invisible
to `AgentQueueStore`, so `queue_depth_for_issue` reads 0 and Ctrl+C #1 picks
`:pause` instead of letting the message deliver. The `:pause` is cosmetic (it
flips control status but codex keeps streaming). Second Ctrl+C kill-panes the
slot's attach pane.

## What the code actually does (corrects two origin-doc assumptions)

Research during planning changed two premises. The plan is built on the
verified behavior, not the origin doc's wording:

1. **`Slot.detach` is already non-destructive.** `slot.ex:598` only removes
   the identifier from `attached_identifiers` and resets the slot to `:ready`.
   It does **not** kill the pane and does **not** delete the opencode session.
   So "detach keeps the session alive" is already true at the slot layer.
2. **Killing the attach pane respawns, it does not delete the session.** When
   the bridge helper's raw `tmux kill-pane` kills the slot's attach pane, the
   slot's `:poll_session` death path (`slot.ex:692-725`) transitions to
   `:attach_spawning` and respawns a fresh attach — the opencode-serve
   `server_pid` and the session in opencode's SQLite survive. Session deletion
   (`reap_session_writer` → `ApiClient.delete_session`, `slot.ex:786`) only
   happens on full slot **teardown**, not on pane death.

Consequence: Mechanism 3 is **not** "stop deleting the session." The session
already persists. The real defect is that the **codex REPL turn** dies
(`repl_agent.ex:588` → `:repl_gone`) and `agent_runner.ex:67` treats that as a
transient error and **re-dispatches with a fresh session** instead of
reattaching the persisted opencode session. See Unit 3.

## The WORKING-vs-IDLE signal (resolves origin open question)

Aiur **does** own an authoritative turn-activity signal for aiur-mediated
codex turns: `Aiur.Opencode.ActiveTurns`. `AgentRunner` registers
`(identifier, aiur_turn_id)` as `:active` before posting the turn marker and
marks it `{:closed, _}` when `run_turn` returns (`active_turns.ex:40-67`).

- **WORKING** = `ActiveTurns.active_turn_ids(issue_identifier) != []`
- **IDLE** = `ActiveTurns.active_turn_ids(issue_identifier) == []`

`ActiveTurns` is already aliased in `orchestrator.ex:27` and used at
`orchestrator.ex:1026`, so the decision path can call it with no new wiring.
This replaces `queue_depth_for_issue` for the no-pane backend — we stop asking
"is there a message in *Aiur's* queue" (always 0) and instead ask "is opencode
mid-turn." Esc on an idle opencode pane is a harmless no-op, so a stale-active
false positive degrades to a wasted keystroke, never a destructive action.

---

## Implementation Units

### Unit 1 — Ctrl+C #1 sends opencode's native interrupt (Esc), pauses only when idle

**Files:**
- `src/lib/aiur/orchestrator.ex` — decision + reply (~3585-3693)
- `src/lib/aiur_web/controllers/observability_api_controller.ex` — pass new action through (~56-64)
- `scripts/aiur-pane-ctrlc` — send the Esc keystroke; keep pane open on the new action
- `src/test/aiur/orchestrator_pane_interrupt_test.exs` (or existing decision-fn test file) — unit tests

**Design:**

Add a new pure decision for the no-pane backend that takes the
*working?* boolean (from `ActiveTurns`) instead of `queue_depth`:

```
# directional sketch — not final code
def pane_interrupt_action_no_pane(paused?, working?) do
  cond do
    paused?  -> :close_pane      # 2nd press on a paused agent
    working? -> :send_interrupt  # native Esc; drain opencode's queue, keep working
    true     -> :pause           # genuinely idle: park it, pane stays open
  end
end
```

- `pane_interrupt_reply/2` no-pane branch (`orchestrator.ex:3604-3619`) computes
  `working? = ActiveTurns.active_turn_ids(issue_identifier) != []` and calls the
  new arity. Stop calling `queue_depth_for_issue` on this branch.
- `perform_pane_interrupt(:send_interrupt, ...)` returns `{{:ok, :send_interrupt}, state}`.
  Aiur does **not** flip control status and does **not** send a pause control
  message — opencode owns the interrupt. No state mutation.
- `:pause` clause is unchanged (still optimistically flips to `:paused` so the
  2nd press reads paused → `:close_pane`).

**Where Esc is sent — the bridge helper, not the orchestrator.** The slot's
opencode-attach `pane_id` is owned by the bridge ($1) and the Slot; the
orchestrator's running entry has `repl_pane_id == nil` for opencode agents, so
it has no pane to `send-keys` to. The helper already runs inside tmux
`run-shell` with `$pane_id`. So:

- Controller returns `{action: "send_interrupt"}`.
- `aiur-pane-ctrlc` adds a case: on `*send_interrupt*`, run
  `tmux send-keys -t "$pane_id" Escape`, log `action=send_interrupt`, keep the
  pane open (`exit 0`). Add `send_interrupt` to the existing keep-open `case`
  match alongside `interrupted|paused|deliver_queue`.

**Exact key:** the pane footer labels Esc as "interrupt" for opencode. Plan
assumes `Escape`. The precise key/sequence is confirmed on-device (see Test
Plan) — if Esc proves wrong, only the helper's `send-keys` argument changes.

**Decisions:**
- Reuse the existing 3-state shape; only the middle branch's input (working?
  vs queue_depth) and action (`:send_interrupt` vs `:deliver_queue`) change.
- Keep the keystroke in the helper to avoid threading the slot's tmux pane_id
  into the orchestrator (it isn't there today and adding it widens scope).

### Unit 2 — Confirm pause reduces to interrupt-via-opencode (no separate live-turn halt)

**Files:** none expected beyond Unit 1; this is a verification + cleanup unit.

With Unit 1, a Ctrl+C on a **working** opencode agent now triggers a real
opencode interrupt (Esc), so the old complaint ("`:pause` is cosmetic, codex
kept streaming") no longer applies — we never choose `:pause` while working.
`:pause` is now reachable only when `ActiveTurns` reports idle, i.e. there is
no live turn to halt. So no new live-turn-halt mechanism is needed.

**Work:**
- Confirm no remaining code path sends the cosmetic pause while a turn is
  active for opencode agents. `send_pause_control_message` stays for the idle
  pause and for non-opencode backends.
- Confirm `queue_depth_for_issue` is still needed by the REPL backend
  (`pane_interrupt_action`, `orchestrator.ex:3666`) — it is — so it is **not**
  deleted, only dropped from the no-pane branch.

### Unit 3 — Reopen reattaches the persisted opencode session instead of fresh-dispatching

**Files:**
- `src/lib/aiur/agent_runner.ex` — `transient_run_error?(:repl_gone)` handling (~57-67)
- `src/lib/aiur/orchestrator.ex` — re-dispatch vs reattach decision on `:repl_gone` for opencode/codex RC agents
- (investigation) `src/lib/aiur/claude/repl_agent.ex:588`, `src/lib/aiur/opencode/attach_pool.ex` attach-hit path

**Design intent:**

Because the opencode session persists (verified above — reopen logged
`attach_pool_hit ... session_id=ses_...`), the fix is to make the
`:repl_gone` recovery for an opencode/codex RC agent **reattach the existing
`session_id`** rather than re-dispatch a fresh agent. The fresh dispatch is
what loses continuity, not session deletion.

**Open execution-time question (flagged, not resolved here):** the reopen in
the captured run failed with `attach_failed reason "no server running on
/tmp/tmux-1001/aiurdev-orangekid"` — a **tmux server** absence, which smells
like a test-harness teardown artifact rather than the steady-state close/reopen
path. Before changing recovery logic, on-device repro must confirm whether, in
a normal (non-end-of-run) close→reopen, the opencode session reattaches
cleanly once we stop the fresh-dispatch. If the tmux-server-gone case is real
in steady state, that is a separate slot/tmux-lifecycle fix and should be
split out. **Do not** broaden this unit speculatively.

**Decision:** keep Unit 3 minimal — route opencode/codex RC `:repl_gone` to
reattach-by-session_id; leave the tmux-server-lifecycle question to on-device
verification before writing that branch.

---

## Test Plan

### Unit-level (deterministic, in-repo — `mise exec -- mix test`)

Pure decision function (`pane_interrupt_action_no_pane/2`, new working?-based arity):
- `paused? = true`  → `:close_pane` (regardless of working?)
- `working? = true, paused? = false` → `:send_interrupt`
- `working? = false, paused? = false` → `:pause`
- Property: `:send_interrupt` never mutates control status (assert state
  returned by `perform_pane_interrupt(:send_interrupt, ...)` is unchanged).

`perform_pane_interrupt`:
- `:send_interrupt` returns `{{:ok, :send_interrupt}, state}` with `state`
  identical to input (no pause message, no status flip).
- `:pause` still flips to `:paused` (existing test preserved).

Bridge helper (`scripts/aiur-pane-ctrlc`) — shell-level if a harness exists,
else covered by on-device check:
- Response containing `send_interrupt` → keeps pane open (`exit 0`), does not
  kill-pane. (Can assert the `case` match with a stubbed `$response`.)

Regression guard:
- REPL backend decision `pane_interrupt_action/2` is unchanged and still reads
  `queue_depth` — keep its existing tests green.

### On-device RC verification (operator-driven; NOT run by the agent)

Standing guardrail: live remote→opencode behavior is verified by the user on
device. These confirm the parts that cannot be unit-tested:
1. Type a message in an opencode pane mid-turn, press Ctrl+C once → message
   delivers, agent keeps working, pane stays open, no "paused" badge.
2. Confirm `Escape` is the correct interrupt key (footer "interrupt" binding);
   if not, adjust the helper's `send-keys` argument only.
3. Press Ctrl+C when genuinely idle → pauses, pane stays open; 2nd press → closes.
4. Close a pane, reopen → same `session_id` resumes (no fresh prewarm/dispatch).
   Capture whether reopen reattaches cleanly or hits "no server running"
   (decides whether the Unit 3 tmux-lifecycle follow-up is needed).

## Sequencing

1. **Unit 1** first (decision + helper) — it is the core behavior change and is
   unit-testable in isolation.
2. **Unit 2** immediately after — mostly verification/grep; confirms the
   cosmetic-pause concern is dissolved by Unit 1.
3. **Unit 3** last and gated on on-device repro of the reopen path, since its
   exact shape depends on whether the tmux-server-gone failure is steady-state
   or a harness artifact.

## Out of scope / non-goals

- claude-repl and non-RC backends (REPL decision path untouched).
- Deep Aiur visibility into opencode internals (rejected in origin doc).
- Unifying opencode input through `AgentQueueStore` (rejected).
- The tmux-server-lifecycle fix, *unless* on-device repro proves it is
  steady-state (then it is a separate plan).
