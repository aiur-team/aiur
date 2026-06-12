# opencode<->Aiur Control Boundary — Requirements

**Date:** 2026-06-12
**Scope:** issue-101 opencode/codex Remote-Control agents only.

## Problem (proven from logs)

A run on agent #101 (pane `%6`) showed:

1. Operator text typed in the opencode pane sits in **opencode's native queue** ("QUEUED" badge), invisible to Aiur's `AgentQueueStore`. The message reached Aiur's bridge (`AgentChat.send`) only 70s later, at teardown.
2. So Ctrl+C #1 read `queue_depth_for_issue = 0` and chose `:pause` (orchestrator.ex:3686-3692) instead of delivering the queued message.
3. Aiur's `:pause` is cosmetic — it flips control status + queues `{:pause_agent}` (orchestrator.ex:3654), but codex kept streaming its live turn (new tool calls after "paused").
4. Closing the pane (2nd Ctrl+C) tore down the tmux/codex session → `:repl_gone; re-dispatch with a fresh session`. Reopen could not resume.

Root cause: Aiur makes queue/pause/close/resume decisions from state it cannot fully see — opencode owns the queue, the live turn, and the session.

## Decisions

1. **opencode owns queue + interrupt.** Aiur stops tracking `queue_depth` for opencode/codex agents. Its decision table no longer needs queue visibility for these backends.
2. **Ctrl+C #1 → opencode's native interrupt** (Esc, per the pane footer's "interrupt" binding). opencode interrupts its current turn and drains its queued operator message, continuing to work. Aiur pauses **only when the agent is truly idle** (nothing working, nothing queued). Second Ctrl+C on a paused agent closes the pane (unchanged).
3. **Session persists across pane close.** Closing only **detaches** the tmux pane; the codex REPL + opencode session keep running in the background. Reopen **reattaches/resumes** where it left off — no `:repl_gone`, no fresh dispatch.

## Success criteria

- Type a message in an opencode pane mid-turn, press Ctrl+C once → message delivers, agent keeps working, pane stays open. No "paused" when work/queue exists.
- Press Ctrl+C when the agent is genuinely idle → pauses, pane stays open. Second press → closes.
- Close a pane, reopen it → same opencode session resumes (same `session_id`), not a fresh prewarm/dispatch.

## Non-goals

- Other backends (claude-repl, non-RC agents).
- Aiur gaining deep visibility into opencode internals (explicitly rejected — opencode owns it).
- Unifying opencode input through `AgentQueueStore` (rejected).

## Open questions for planning

- Exact key/sequence to trigger opencode's interrupt from the Ctrl+C bridge without quitting opencode.
- How "truly idle" is detected for the pause-only-when-idle branch under the new ownership model.
- Mechanism to keep the codex/opencode session alive on pane close (detach vs kill) and how reopen reattaches.
