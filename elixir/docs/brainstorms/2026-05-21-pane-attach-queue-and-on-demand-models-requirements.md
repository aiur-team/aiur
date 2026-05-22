---
title: refactor: Queue pane opens, on-demand slot models, fix pane title
type: refactor
status: active
date: 2026-05-21
---

# refactor: Queue pane opens, on-demand slot models, fix pane title

## Problem Frame

Live use of the slot-bound opencode work (origin: `elixir/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md`) surfaced three concrete bugs and one model simplification:

1. **Title bug.** Every chat pane chrome shows `Build · Aiur · Aiur` instead of the agent identifier (e.g. `Build · issue-13`). Cause: `elixir/lib/aiur/opencode/protocol.ex:86` hardcodes `name: "Aiur"` for every model in the slot's `opencode.json`, plus the provider's own `name` is also `"Aiur"` (line 93). opencode renders `<provider.name> · <model.name>`, so both literal strings collide on screen as `Aiur · Aiur`.

2. **Pre-warm race.** Opening agents faster than chain pre-warm supplies fresh slots produces inconsistent results.
   - Repro: opened issues 13 → 17 → 12 in quick succession during boot.
   - #13 worked. #17 never produced a visible pane. #12 opened in an unexpected tmux pane location with no agent logs.
   - Cause: `SlotSupervisor.acquire_slot/0` returns `{:error, :no_ready_slot}` when no slot is `:ready`; `PaneManager.open_opencode_pane/4` falls back to `PaneSession.start` (cold-attach), which is a parallel opencode-serve + tmux split path. Cold-attach's race semantics during chain pre-warm are buggy (drops/misroutes).

3. **Session-list leakage.** When the user opened #12 (third selection), that pane's Ctrl+P session list contained all three prior sessions (#13, #17, #12). Cause: every slot's `opencode.json` declares every active agent as a model (`WorkspaceSetup.materialize_slot/5` passes `agent_identifiers = list_active_identifiers()`), so opencode sees every aiur agent as an available model in every slot. Combined with the shared SQLite (`~/.local/share/opencode/opencode.db`), opencode's session picker bleeds sessions across panes.

The model simplification: a slot's `opencode.json` should declare ONLY the agent currently attached to it. New agents are added explicitly — by the user opening a pane (or by the explicit "attach this agent to current pane" affordance, in scope below). This deletes the `wait_for_active_identifiers/2` boot wait and the full-list seeding, and removes the reason for `Slot.schedule_serve_rebuild/2`'s "rebuild on identifier_miss with full list" path.

## Requirements

### R1 — Pane title shows agent identifier
**R1.1** Each opencode pane's chat chrome MUST display the agent identifier (e.g. `issue-13`) instead of the literal string `Aiur`. The exact rendered string is implementation choice (`issue-13`, `#13`, the ticket title) but it MUST be derived from the agent identifier, not from a global constant.

**R1.2** The provider name in opencode.json MAY remain `aiur` (it appears in the model picker as the provider group); the model name MUST NOT.

### R2 — Pane opens are queued, never cold-routed
**R2.1** `PaneManager.open` MUST return `{:ok, pane_id}` (or `{:error, reason}` with a USER-meaningful reason) regardless of slot pre-warm timing. The caller never sees a misrouted pane, a missing pane, or a pane in the wrong tmux window.

**R2.2** When no slot is `:ready` at open time, PaneManager MUST queue the user's intent (identifier + caller `from` ref) and reply once a slot reaches `:ready`. Queue ordering MUST be FIFO so users see opens land in the order they hit Enter.

**R2.3** The legacy cold-attach path (`PaneSession.start`, `cold_attach/4` inside `PaneManager`) is REMOVED. There is only one open path: acquire a slot, select identifier, move pane visible.

**R2.4** If pre-warm never produces a ready slot (e.g. configuration error, all slots `:failed`), the queued open MUST time out (60 s suggested) and reply `{:error, :no_ready_slot}` so the AgentList can surface it. No silent hangs.

### R3 — Slot's opencode.json declares only attached agents
**R3.1** `WorkspaceSetup.materialize_slot/5` MUST NOT accept or use a "seed with all active identifiers" argument. The initial models map is EMPTY (or contains only the slot's sentinel `_slot-N` identifier, never any `issue-X`).

**R3.2** When `Slot.select(slot_pid, identifier)` is called for an identifier NOT currently in the slot's models map, the slot MUST add that identifier to its models map and restart its opencode-serve so opencode picks up the new model. This is the only path by which a slot's models map grows.

**R3.3** The boot-time `wait_for_active_identifiers/2` in `Slot.handle_continue(:start_serve, ...)` is DELETED. Slot 1 no longer waits ~6 s for the orchestrator's first enumeration before materializing its workspace — it materializes empty and ready in ~3 s.

**R3.4** Existing Ctrl+P session-list bleed across panes (sessions persist in shared SQLite) is OUT OF SCOPE. Acceptable: a pane that has been used for multiple agents over time shows all those sessions in Ctrl+P. This is opencode's behavior and is not user-blocking.

### R4 — Manual "attach to current pane" affordance
**R4.1** The agent list MUST support an `a` keybind (or equivalent — choose during planning) that attaches the SELECTED agent to the currently-FOCUSED visible pane. The currently-focused pane's slot rematerializes its workspace + restarts its serve with the newly-attached agent.

**R4.2** This is distinct from `Enter` (open in new pane). When the user has no focused chat pane (only the agent list is visible), `a` MAY behave like `Enter` (open in next available slot) OR refuse with a message — pick during planning.

**R4.3** The previously visible agent in that slot is NOT torn down; its SessionWriter stays alive and its session persists in SQLite, so a future open of that agent can pick it back up. Only the slot's model binding changes.

## Actors

- **A1** Developer running aiur in interactive CLI mode
- **A2** Codex agent (writes turn output to shared SQLite via SessionWriter)
- **A3** opencode-serve instance (per slot)
- **A4** opencode-attach TUI process (per slot's tmux pane)

## Key Flows

- **F1** Open agent before any slot ready: user hits Enter on issue-13 at t=2 s; slot 1 not ready until t=8 s. PaneManager queues the open. At t=8 s, slot 1 broadcasts `:slot_ready`. PaneManager dequeues, drives `Slot.select`, moves pane visible, replies to AgentList. Total user-perceived wait: ~6 s. **R2.1, R2.2.**
- **F2** Quick succession during boot: user hits Enter on 13, 17, 12 within 1 s while only slot 1 is `:ready`. PaneManager opens 13 immediately in slot 1, queues 17 + 12. At t=12 s slot 2 ready → dequeue 17 → slot 2. At t=18 s slot 3 ready → dequeue 12 → slot 3. All three panes appear in user-typed order. **R2.2.**
- **F3** Slot N selects identifier already in its models map: warm path, no rebuild, ≤100 ms. **R3.2 (negative case).**
- **F4** Slot N selects identifier NOT in its models map: rebuild adds JUST the new identifier (not all 10), restart serve, attach pane respawns. ~5 s pause acceptable. **R3.2.**
- **F5** Manual attach: user opens issue-13 in slot 1, then highlights issue-7 and presses `a`. Slot 1 rebuilds with `extra_identifiers=[13, 7]`, `Slot.select(slot1_pid, "issue-7")` runs. Pane stays in same tmux location, shows issue-7's session. **R4.1, R4.3.**

## Acceptance Examples

- **AE1** (R1.1) Open agent issue-13. Chat pane chrome shows `Build · issue-13 · 100ms` (or equivalent containing `issue-13`), NOT `Build · Aiur · Aiur`.
- **AE2** (R2.2) Reproduce the original race: open issues 13, 17, 12 within 1 second of aiur boot. All three panes eventually appear in user-typed order; no pane goes missing; no pane lands in the wrong window. Log line `aiur_pane_manager phase=open_queued identifier=17` is observable for the queued cases.
- **AE3** (R3.1) Inspect `~/.local/share/aiur/opencode-slot-1/opencode.json` immediately after slot 1 reaches `:ready` and BEFORE any user open. Models map is empty (no `issue-N` keys). Aiur boot-to-interactive elapsed_ms ≤ 4 s (down from current ~14 s).
- **AE4** (R3.2) Open agent issue-13 in a fresh slot. Inspect slot 1's `opencode.json` AFTER select. Models map contains exactly one key: `issue-13`.
- **AE5** (R3.4) Open agent issue-13, then close + open agent issue-7 in the same slot (via R4 attach). Slot 1's `opencode.json` now has both `issue-13` and `issue-7` keys. Ctrl+P inside the pane shows both sessions — this is acceptable.
- **AE6** (R4.1) Open issue-13. Highlight issue-7 in agent list. Press `a`. Within ~5 s the same tmux pane is showing issue-7's chat content with `Build · issue-7 · ...` in the chrome. No new tmux pane is created.
- **AE7** (R2.4) Force pre-warm to fail (e.g. break opencode binary path temporarily). Open an agent. Within 60 s, AgentList shows an error or the open returns `{:error, :no_ready_slot}` — no silent hang.

## Scope Boundaries

### In Scope
- Title bug fix in `opencode.json` model name
- Queue-based open in `PaneManager`; delete cold-attach branch and `PaneSession` machinery if unused elsewhere
- Drop full-agent-list seeding from `WorkspaceSetup.materialize_slot/5`; remove `wait_for_active_identifiers/2`
- Slot rebuild on identifier_miss adds JUST the missing identifier (incremental), not the full list
- New `a` keybind in agent list for "attach selected agent to focused pane"

### Out of Scope
- Filtering opencode's Ctrl+P session picker to hide other agents' sessions (would require modifying opencode itself; not user-blocking)
- Per-slot SQLite isolation (would require opencode-serve flag we don't control)
- Auto-refresh of agent list during long pre-warm (the freeze fix from prior round already handles tick responsiveness)
- Session sharing across slots (each agent's SessionWriter remains identifier-keyed globally; multiple slots cannot show the same agent simultaneously — opening an already-visible agent re-focuses its current pane, already implemented)

## Dependencies / Assumptions

- opencode 1.15.6 honors a single-model `opencode.json` (the slot's sentinel model alone, with no `issue-N` entries) — slot can boot before any agent is attached. **Assumption: should verify during planning with a one-line probe; if opencode refuses an empty models map, the sentinel `_slot-N` placeholder is sufficient.**
- The bridge does NOT need to know about model names; it routes by request body's `model` field (`identifier_from_model/1`). No bridge changes for R1.
- `Aiur.PaneManager` already has the in-process queue infrastructure (`GenServer.from` deferral) — adding an open queue is mechanical, no new supervision needed.
- Slot rebuild path is already proven for the identifier_miss case (just need to change "full list" to "incremental").

## Open Questions (resolve during planning)

1. Exact pane-title rendering: `issue-13` literal vs `#13` vs ticket title (lookup via `Orchestrator` — adds a sync call). Default to literal `issue-13` unless planning finds a cheap title-fetch path.
2. Keybind for "attach to focused pane": `a` is intuitive but conflicts with no existing binding — verify in `elixir/lib/aiur/agent_list/input.ex` during planning.
3. What does "focused pane" mean when the user has multiple chat panes? Most-recently-active vs tmux's `pane_active` flag vs an explicit aiur-tracked focus. Default: tmux's `pane_active` for the chat-pane window.
4. When a queued open is waiting and the user hits Enter on a DIFFERENT agent, does the new intent supersede the queued one (latest-wins) or queue alongside (FIFO)? Default: queue alongside per R2.2.
