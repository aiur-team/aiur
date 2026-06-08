---
title: Slot-bound opencode instances with lazy chain pre-warm
created: 2026-05-21
status: ready_for_planning
origin: elixir/docs/brainstorms/2026-05-21-aiur-pane-lifecycle-and-background-attach-requirements.md
related:
  - elixir/lib/aiur/pane_manager.ex
  - elixir/lib/aiur/opencode/attach_queue.ex
  - elixir/lib/aiur/opencode/agent_attach.ex
  - elixir/lib/aiur/opencode/hidden_window.ex
  - elixir/lib/aiur/opencode/warm_server.ex
  - elixir/lib/aiur/opencode/session_writer_registry.ex
  - elixir/lib/aiur/agent_list/app.ex
  - elixir/lib/aiur/agent_list/renderer.ex
---

# Slot-bound opencode instances with lazy chain pre-warm

## Problem frame

The previous round (origin doc, same date) shipped a "1 warm opencode-serve + N per-agent attaches" model. Live use surfaced six follow-up problems that share a common root: the model entangled agent identity with opencode instance lifecycle, which created duplicate-session races, stale token paths, indicator-state drift, and unpredictable open latency.

The fix is an architectural simplification: **opencode instances are bound to pane slots, not to agents.** Each slot owns exactly one opencode-serve + one opencode-attach process for the lifetime of the aiur run. Opening a pane is a `/tui/select-session` against the slot's instance. SessionWriters stay global (one per active agent, writing the shared `~/.local/share/opencode/opencode.db`). Pre-warming chains: instance N+1 begins booting once instance N's serve is ready and aware of all current agents, so the user sees instant open/close on every slot.

This model also dissolves several existing modules — `AttachQueue`, `AgentAttach`, the per-agent pane registry — because per-agent orchestration is no longer needed.

## Actors

- **A1: developer** running `scripts/aiur` to oversee multiple parallel codex agents
- **A2: codex agent** (per-issue worker, autonomous)
- **A3: opencode instance** — opencode-serve + opencode-attach pair bound to one pane slot

## Requirements

### R1: Per-slot opencode instances

- **R1.1**: At aiur boot, exactly one opencode-serve + one opencode-attach process exist for the first pane slot. Both live in the hidden warm tmux window.
- **R1.2**: Each slot's instance has its own workspace directory and its own `opencode.json`. Workspaces are per-slot (e.g. `~/.local/share/aiur/opencode-slot-1`), not per-agent.
- **R1.3**: When the user opens an agent chat in a slot, that slot's opencode instance switches to the agent's session via `/tui/select-session`. The tmux pane moves from hidden to visible.
- **R1.4**: When the user closes a pane, the tmux pane moves back to the hidden window. The opencode instance stays alive, ready to switch to any agent's session on next open.
- **R1.5**: An opencode instance is bound to its slot for the lifetime of the aiur run. The same instance can serve many different agents over time.

### R2: Single opencode session per agent, ever

- **R2.1**: At any point during an aiur run, `opencode session list` MUST show at most one Aiur-owned session per active agent identifier. No duplicates.
- **R2.2**: There MUST be zero sessions whose title is `_warm`, `_placeholder`, or any other internal marker. Every Aiur-created session is titled with the agent's real identifier.
- **R2.3**: On aiur shutdown (any path covered by the prior plan's three-layer cleanup), all Aiur-owned sessions are deleted.

### R3: Indicator follows the currently-visible session, not the historical open

- **R3.1**: The status circle in the agent list (left of the AGE column) MUST be shown ONLY for agents whose session is currently selected in some opencode instance and that instance's pane is currently visible.
- **R3.2**: When the user uses opencode's session switcher (Ctrl+P or equivalent) to change the visible pane to a different agent's session, the circle MUST move accordingly within ~1 second.
- **R3.3**: When the user closes a pane, the circle for that agent disappears even if the opencode instance retains the session in memory.
- **R3.4**: Multiple agents may show circles simultaneously if multiple panes are visible (one per slot).

### R4: Bridge token authentication never fails for live workspaces

- **R4.1**: A workspace's `opencode.json` apiKey MUST always match a live entry in `Aiur.Opencode.TokenRegistry`.
- **R4.2**: Regenerating opencode.json (e.g. when a new agent is added and the slot's models map must include it) MUST NOT rotate the token; rotation happens only when the slot's opencode-serve is itself restarted.
- **R4.3**: The user MUST NOT see "unauthorized: bridge token did not match an active workspace" errors during normal operation. (Bridge requests with truly stale tokens — e.g. from a workspace cloned by a tool outside aiur — may still be rejected; this is acceptable.)

### R5: Open and close are instant after the slot is warm

- **R5.1**: Once a slot's opencode instance is warm and pre-attached, opening any pane into that slot MUST complete in ≤100 ms wall time (tmux move-pane + `/tui/select-session`).
- **R5.2**: Closing a pane MUST complete in ≤100 ms wall time (tmux move-pane to hidden window).
- **R5.3**: First-slot warm-up MUST be hidden from the user — the agent list is fully interactive while the first slot warms in the background.
- **R5.4**: There MUST NOT be a difference of 15+ seconds between fast and slow opens. If a slot is not yet warm when the user requests it, that ONE open may be slow (cold-attach fallback), but subsequent opens into the same slot are warm-fast.

### R6: Lazy chain pre-warm

- **R6.1**: Total opencode instances pre-warmed = the conversation pane slot count `S` (i.e. `(2 × max_vertical_panes) − 1`; e.g. `max_vertical_panes=3 → S=5`). The agent-list pane is not a slot for opencode purposes.
- **R6.2**: At aiur boot, only instance 1 begins pre-warming. Other slots stay cold until triggered.
- **R6.3**: Instance N+1 begins pre-warming when instance N reaches the "ready" state: opencode-serve is up, opencode-attach is connected, and the slot's `opencode.json` declares every currently-active agent identifier as a model.
- **R6.4**: When a new agent appears in the agent list while instances are running, the slot workspaces' `opencode.json` files MUST be updated to include the new agent's model. Already-running opencode-serve processes need to reload the file (or be patched in-memory) so model lookups succeed.
- **R6.5**: When the user closes a slot's pane, the slot's opencode instance is NOT shut down. It stays ready for the next open into that slot.

### R7: Drop dead code; simpler is the goal

- **R7.1**: `Aiur.Opencode.AttachQueue` (per-agent queue) MUST be deleted — it has no role in the slot-bound model.
- **R7.2**: `Aiur.Opencode.AgentAttach` (per-agent attach worker) MUST be deleted — replaced by per-slot attach.
- **R7.3**: `Aiur.Opencode.PersistentPane` (per-agent pane state) MUST be replaced or removed — slot-bound pane state lives in a new per-slot registry.
- **R7.4**: `Aiur.Opencode.SessionWriterRegistry`'s `regenerate_workspace_config` per-agent helper MUST be deleted — per-slot workspace materialization is now the only path.
- **R7.5**: Net change to the codebase should be NEGATIVE lines (less code than today). Verify in the final code-review pass.

## Acceptance examples

- **AE1**: User boots aiur. Within 1s, agent list is rendered + responsive. Pressing j/k navigates instantly. Within ~6s (warm-server time), the first slot's circle is ready to light up on a selected agent.
- **AE2**: User opens agent #5 in slot 1. The visible chat pane is the same physical opencode-attach process that pre-warmed in the background. Open completes in ≤100 ms.
- **AE3**: User opens agent #7 in slot 2. Slot 2's instance was pre-warmed after slot 1 reached ready. Open in ≤100 ms.
- **AE4**: User closes pane in slot 1. Tmux pane moves to the hidden window. Opening any other agent in slot 1 next takes ≤100 ms; the same opencode-attach process now shows the new agent's session.
- **AE5**: User opens agent #5 in slot 1, then presses opencode's Ctrl+P and switches to agent #7's session in the same pane. The agent list's circle moves from #5 to #7 within 1s. Closing the pane: both circles disappear.
- **AE6**: `mise exec -- opencode session list` while aiur is running shows exactly one session per active agent — never duplicates, never `_warm` or `_placeholder` titles.
- **AE7**: User boots aiur, opens panes back-to-back into all `S` slots. Every open completes in ≤100 ms because each slot's instance was already warm by the time the user reached it.
- **AE8**: User boots aiur with no active GitHub agents. All slots stay cold (no opencode-serve spawned). When the first agent appears, slot 1 begins pre-warming. Eventually all S slots are pre-warmed in turn.
- **AE9**: User boots aiur, makes a single API call that creates a fresh bridge token, then chats with the agent. No "unauthorized: bridge token" error appears.

## Scope boundaries

**In scope**

- The seven requirements above.
- Per-slot opencode workspace directories + per-slot `opencode.json` files.
- Slot-bound `SlotRegistry` + slot supervisor.
- Code deletions per R7.

**Deferred for later**

- Persisting slot warm state across aiur restarts (a fresh boot starts cold).
- Configurable pre-warm depth (always equals `S` for now).
- Opencode session reuse across multiple aiur runs (today: sessions are reaped on every shutdown).
- A UI affordance to show which slots are warm vs cold.

**Outside this product's identity**

- Forking opencode or modifying its TUI. opencode 1.15.6 is a fixed black box.
- Multi-user / multi-machine slot pooling.

## Dependencies / assumptions

- **D1**: `~/.local/share/opencode/opencode.db` is a single shared SQLite database that all opencode-serve instances on the machine read/write concurrently (WAL). Multiple slot instances can `/tui/select-session` to any session and see the same data.
- **D2**: opencode 1.15.6 emits an event when its TUI's active session changes (likely via `/event` SSE). Required for R3.2. If not available, R3 falls back to a periodic poll.
- **D3**: opencode-serve reloads `opencode.json` on file change OR the slot's serve can be restarted on agent-list change (R6.4). Verify in planning.
- **D4**: tmux `move-pane -d` continues to work as a bidirectional visible↔hidden swap primitive (verified in prior round).
- **D5**: Bridge `TokenRegistry` retains tokens across `opencode.json` regenerations, so an apiKey written at slot serve startup remains valid for the lifetime of that serve (R4.2).

## Open questions

- **Q1**: How does opencode signal a session change initiated by Ctrl+P inside its TUI? Verify by probing the `/event` SSE stream during planning.
- **Q2**: When a new agent appears, does opencode-serve need a restart to pick up the new model in `opencode.json`, or does it auto-reload? Verify during planning.
- **Q3**: Where does the bridge `TokenRegistry` lookup currently fail (the "unauthorized" error)? Trace during planning; the fix may simply be R4.2 (don't rotate token on regen).
- **Q4**: Where are the 3 placeholder sessions in R2.2 coming from in today's code? Likely candidates: SessionWriterRegistry creating ghost sessions during AttachQueue retry, or stale code paths from the deleted WarmAttach. Trace during planning.

## Required test coverage

Every issue surfaced in this round must have a regression-guarding test before the work is considered done:

- **T1** (R2.1): After driving aiur through `S` opens, assert `opencode session list` length == active-agent count.
- **T2** (R2.2): After a full aiur boot, assert no session title matches `^(_warm|_placeholder)`.
- **T3** (R3.2): Simulate an opencode session change event; assert the agent list's circle moves to the new identifier within 1s.
- **T4** (R4.3): Hit `/v1/chat/completions` with a token from the materialized `opencode.json` of an active slot; assert 200, not 401.
- **T5** (R5.1): Measure open latency for slot N (where N's instance is warm) — assert ≤100ms.
- **T6** (R6.3): Boot aiur; assert instance 2 starts pre-warming ONLY after instance 1 emits its ready phase log.
- **T7** (R7.5): After the migration, assert `git diff --shortstat` shows more deletions than insertions across the affected modules.

## Success criteria

The feature is done when, on a fresh aiur boot with at least `S` active agents:

1. Every pane open completes in ≤100 ms (T5)
2. No "unauthorized" bridge errors appear (T4)
3. `opencode session list` shows exactly one session per active agent and no `_warm` / `_placeholder` titles (T1, T2)
4. The agent-list circle indicator follows session changes, including ones initiated via Ctrl+P inside opencode (T3)
5. After all `S` slots are warm, the user can fill every slot with sub-100ms opens (T5 × S)
6. The codebase has fewer lines of code in the affected modules than before this round (T7)

## Why this matters

The previous round's per-agent attach model was the wrong abstraction. Agents come and go (created, completed, paused) but pane slots are a stable, bounded resource. Binding opencode instances to slots rather than to agents collapses the orchestration: one opencode per slot, one slot per visible pane, one shared SQLite for all session state. Most of the existing complexity — the AttachQueue, the per-agent registry, the priority preemption, the cancellation logic — was solving problems that only existed because of the wrong binding choice. With slot-bound instances, those problems vanish and the codebase shrinks.
