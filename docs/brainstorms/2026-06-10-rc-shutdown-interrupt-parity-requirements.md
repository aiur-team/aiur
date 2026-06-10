---
date: 2026-06-10
topic: rc-shutdown-interrupt-parity
---

# Remote Control Shutdown and Interrupt Parity

## Summary

Aiur's Claude Remote Control sessions need the same lifecycle and interruption semantics operators expect from the local chat pane: closing Aiur ends the live remote agent, messages from either surface appear in the shared conversation, and Ctrl+C gives the operator a predictable way to pause, drain queued messages, or kill the visible chat pane.

---

## Problem Frame

The RC dual-chat path is usable enough to launch issue #101 with a live Claude remote session, but the last manual run exposed three operator-visible gaps. After Aiur was closed, the remote Claude app still showed issue #101 as live. A message sent from the Claude remote app affected the Claude session but did not appear in the opencode conversation pane. A message sent from opencode stayed queued until the operator used Claude's native stop button from the remote app, which interrupted the agent and caused the pending opencode message to be consumed.

These gaps make the two surfaces feel like separate control planes rather than one shared agent session. They also leave the operator without a local way to do what Claude and Codex already support: interrupt the current turn at a safe point, add new context, and let the agent continue with that context.

---

## Actors

- A1. Operator: controls an active issue from Aiur's TUI, opencode chat pane, and sometimes Claude Remote Control.
- A2. Running agent: performs issue work and may be mid-tool, mid-turn, paused, or deactivated.
- A3. Aiur runtime: owns local tmux panes, queue state, issue labels, and opencode session rendering.
- A4. Claude Remote Control surface: shows and accepts messages for the same persistent Claude session.

---

## Key Flows

- F1. Shutdown tears down the remote-capable agent
  - **Trigger:** The operator quits Aiur or `scripts/aiurdev stop` stops the runtime.
  - **Actors:** A1, A2, A3, A4
  - **Steps:** Aiur stops local chat panes, terminates the persistent Claude REPL process tree, and records enough diagnostics to prove the local owner is gone.
  - **Outcome:** No local process can continue driving the issue, and a later startup cannot inherit a stale RC process or pane.
  - **Covered by:** R1, R2, R9

- F2. Remote-origin message appears locally
  - **Trigger:** The operator sends a message from Claude Remote Control.
  - **Actors:** A1, A2, A3, A4
  - **Steps:** Claude records the message in the shared transcript, Aiur tails that transcript, normalizes the user turn, and renders it in the opencode chat pane.
  - **Outcome:** The opencode conversation shows the same user turn that the Claude app accepted.
  - **Covered by:** R3, R4, R10

- F3. Opencode message drains after local interrupt
  - **Trigger:** The operator sends a message from opencode while the agent is busy, then presses Ctrl+C once.
  - **Actors:** A1, A2, A3
  - **Steps:** Aiur interrupts the active turn without killing an in-flight tool process prematurely, drains pending operator messages into the next agent turn, and resumes the agent with the new context.
  - **Outcome:** The pending message leaves the visible queued state and the agent continues with that context.
  - **Covered by:** R5, R6, R7

- F4. Ctrl+C pauses or kills according to current state
  - **Trigger:** The operator presses Ctrl+C with no pending message or while already paused.
  - **Actors:** A1, A2, A3, A4
  - **Steps:** Aiur maps the keypress to pause semantics when the agent is working, keeps the issue paused when there is no queued context to drain, and kills only the visible opencode pane when Ctrl+C is pressed again while paused.
  - **Outcome:** The agent-list state remains authoritative: space or a remote message can resume remote-capable paused agents; a killed pane does not silently resume work.
  - **Covered by:** R6, R7, R8

---

## Requirements

**Remote lifecycle**
- R1. Closing Aiur must terminate every local persistent Claude REPL process, tmux pane, and descendant process owned by the current run.
- R2. Stopping Aiur must not schedule issue retries or leave a local worker able to continue issue #101 after shutdown begins.
- R3. Remote Control session visibility must reflect live local ownership where Aiur can control it; stale remote entries must not be mistaken for active local agents.

**Shared transcript parity**
- R4. User turns sent from Claude Remote Control must be rendered into the opencode conversation for the same issue.
- R5. User turns sent from opencode must be delivered to the persistent Claude session and must leave the queued state once consumed or explicitly failed.
- R6. Aiur must log remote-origin and opencode-origin user turns with enough source metadata to debug ordering and delivery failures without exposing secrets.

**Interrupt and pause semantics**
- R7. Pressing Ctrl+C once while a working agent has queued operator messages must interrupt at the backend's safe point, drain the queued message into the next turn, and continue the agent with the new context.
- R8. Pressing Ctrl+C once while a working agent has no queued operator messages must pause the agent until the operator sends another message or explicitly resumes it.
- R9. Pressing Ctrl+C while the agent is already paused must close the visible opencode pane and keep the agent paused; resuming requires the agent list space key or, for remote-capable agents, a new remote-control message.
- R10. Interrupt handling must preserve the existing "do not cut off mid-tool execution" invariant: active tool work may finish before the interruption is applied.

**Diagnostics and verification**
- R11. The next manual run must preserve enough chat transcript and runtime log evidence to distinguish remote-origin messages, opencode-origin messages, local interrupts, remote interrupts, prompt delivery failures, and shutdown cleanup.
- R12. The implementation must be covered by focused tests plus a full manual CLI run using the real `scripts/aiurdev --test3 --force --allow-remote` path.

---

## Acceptance Examples

- AE1. **Covers R1, R2, R3.** Given issue #101 is running as a remote-capable Claude REPL session, when the operator quits Aiur, local process checks show no Aiur-owned Claude, opencode, BEAM, tmux, or issue workspace process remains.
- AE2. **Covers R4, R6.** Given issue #101 is open in opencode and Claude Remote Control, when the operator sends `hello` from the Claude app, opencode renders a user row for `hello` and the issue log records it as remote-origin user input.
- AE3. **Covers R5, R7, R10.** Given opencode shows `hi` as queued while the agent is working, when the operator presses Ctrl+C once, the current tool-safe point completes, the message is delivered, the queued marker clears, and the agent resumes with `hi` in context.
- AE4. **Covers R8.** Given the agent is working and no operator message is queued, when the operator presses Ctrl+C once, the agent enters paused state and no new turn is started until the operator resumes or sends a message.
- AE5. **Covers R9.** Given the agent is paused and the opencode pane is visible, when the operator presses Ctrl+C again, the visible pane closes while the agent remains paused in the agent list.

---

## Success Criteria

- Operators can use Aiur and Claude Remote Control as two views of one session, not two diverging conversations.
- A local Aiur shutdown leaves no local agent process able to continue issue work.
- The Ctrl+C flow matches the operator's existing Claude/Codex mental model.
- The manual test evidence includes visible opencode rendering, log correlation, process cleanup proof, and GitHub CI remains green.

---

## Scope Boundaries

- This work does not add a new remote-control product surface.
- This work does not require deleting historical Claude-side session entries that Claude keeps after the local process is gone.
- This work does not change issue #99/#100/#101 event-flow task semantics except as needed for verification.
- This work does not merge PR #256 without explicit operator approval.

---

## Key Decisions

- Ctrl+C is the local operator interrupt primitive: it should drain queued context when present, pause when no context is queued, and close the pane only when already paused.
- Remote-origin user messages are first-class transcript events: they should be visible in opencode, not merely inferred from agent behavior.
- Shutdown correctness is local-process correctness: Aiur can guarantee it is no longer driving the remote session even if Claude's app keeps a stale historical entry visible.

---

## Dependencies / Assumptions

- The persistent Claude REPL transcript contains remote-origin user turns; if it does not, implementation must add a diagnostic proving that limitation.
- opencode's Ctrl+C behavior can be intercepted or mapped through the existing chat-completions/orchestrator control path without forking opencode.
- The final manual verification requires valid Claude Remote Control access and GitHub tracker auth.
