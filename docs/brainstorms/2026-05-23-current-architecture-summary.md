# Current architecture summary — pre-warm, panes, opencode, attach

**Branch**: `prewarm-simplification` (forked off `updated-opencode-logic` at commit `e48c383`)
**Purpose**: My understanding of how the system works *today*, before any refactor. If anything here is wrong, correcting me now saves hours of misdirected work.

## 1. Boot lifecycle (cold start)

```
user runs `scripts/aiur --debug --clear`
  → script clears aiur*.log, creates tmux session aiur-orangekid-default on socket aiur-orangekid
  → spawns the BEAM via mise + bin/aiur
  → BEAM supervision tree:
      Aiur.Application
        ├─ Phoenix.PubSub (Aiur.PubSub)
        ├─ Aiur.Tmux (one GenServer; serializes tmux CLI calls)
        ├─ Aiur.Opencode.SlotRegistry.Registry  (unique keys :slot_index → {pid, value})
        ├─ Aiur.Opencode.SessionWriterRegistry.Registry (duplicate keys :identifier)
        ├─ Aiur.Opencode.TokenRegistry           (token → slot_index)
        ├─ Aiur.Opencode.PrewarmSupervisor
        │     └─ Aiur.Opencode.SlotPolicy   (decides slot_count, boots Slots)
        │     └─ Aiur.Opencode.AttachPool   (tracks fan-out + warm-pane state)
        │     └─ Aiur.Opencode.SlotSupervisor
        │           └─ Aiur.Opencode.Slot (×N — one per pre-warm slot)
        ├─ Aiur.PaneManager
        ├─ Aiur.Orchestrator (Codex/worker dispatch, capacity policy)
        └─ Aiur.AgentList.App (TUI renderer + input loop)
```

`SlotPolicy.default_target_count` = `max(grid_capacity, max_concurrent_agents)` = 6 today.
Six `Slot` workers start in parallel.

## 2. One `Slot`'s lifecycle

```
Slot.init(slot_index)
  → SlotRegistry.register_self(slot_index)            # ETS row created
  → status: :booting
  → handle_continue(:start_serve)
      → WorkspaceSetup.materialize_slot(...)          # writes opencode.json with all active identifiers pre-seeded into models map
      → Aiur.Opencode.Server.start_link(...)          # spawns opencode-serve as a port
  → status: :serve_starting → waits for Server :ready
  → handle_continue(:spawn_attach)
      → Tmux.split into aiur-hidden window (off-screen)
      → spawn opencode-attach --session <sentinel-session>
      → maybe_start_pipe_pane (debug-only stderr capture)
  → status: :ready
  → broadcasts {:slot_ready, slot_index} on "opencode:slots"
  → Aiur.Perf.event(:slot_ready, ...)
```

Slot state of interest:
- `pane_id` — tmux pane id of the opencode-attach in aiur-hidden.
- `visible_identifier` — which identifier's session is currently painted in this pane (nil until `set_visible` runs).
- `attached_identifiers` — MapSet of identifiers whose sessions exist in this serve.
- `known_identifiers` — identifiers in this serve's models map (pre-seeded from opencode.json at start_serve).

## 3. AttachPool's fan-out (the slow part)

When all six slots reach `:ready` and `AttachPool` has been seeded with the active identifier list:

```
AttachPool.handle_info({:slot_ready, slot_index}, state)
  → kickoff_fan_out(state, slot_index)
      if slot already in fanned_out_slots: skip
      else:
        leadoff = active_identifiers[(slot_index - 1) mod N]
        rest    = all other active_identifiers
        start_leadoff_task(slot, leadoff)
          → Slot.set_visible(slot, leadoff)            # HTTP attach + opencode-attach respawn
        for id in rest:
          start_attach_task(slot, id, leadoff: false)
            → Slot.attach(slot, id)                    # HTTP session create only, no paint
        add slot to fanned_out_slots
```

With 6 slots and 6 active identifiers: 6 leadoff paints + 30 rest attaches = **36 HTTP operations** through 6 Slot GenServer mailboxes. Each `Slot.attach` takes 0.5–15 s (opencode-serve under load); each `Slot.set_visible` kills+respawns opencode-attach (~1–3 s).

Result the user just saw: 50 s before any agent flips ⚪.

## 4. State scoreboard (who knows "agent X is visible in slot Y")

| Module | State key | Purpose |
|---|---|---|
| `Slot` | `visible_identifier`, `pane_id` | The actual truth for one slot |
| `SlotRegistry` (ETS) | `%{visible_identifier, pane_id}` per slot | Lock-free mirror of above |
| `AttachPool` | `attachments[id].visible_in` (slot index) | Inverse index for `consume` lookup |
| `AttachPool` | `attachments[id].attached_slots` (MapSet) | Which slots have id's session loaded |
| `AttachPool` | `fanned_out_slots`, `in_flight`, `fully_warmed_slots` | Bookkeeping for fan-out tasks |
| `AgentList.state` | `attach_state[id] = %{attach_count, visible_in}` | Marker emoji input |
| `AgentList.state` | `visible_sessions[slot_index] = id` | Marker emoji input (slot-keyed) |
| `AgentList.state` | `opened_panes :: MapSet(id)` | 🟢 marker source |
| `AgentList.state` | `started_slots`, `fully_warmed_slots` | Bottom-row warmth glyphs |
| `PaneManager` | `identifier_to_pane`, `pane_to_identifier`, `pane_to_slot`, `slot_panes`, `placeholder_panes`, `last_attached_pane_id` | tmux layout bookkeeping |
| `Orchestrator` | `running[id]` (`:active` or `:paused` work_state) | Capacity precondition |

## 5. Opening a pane (`Enter` on agent X)

```
AgentList.handle_cast(:activate)
  → dispatch :new_pane  (= same as Shift+Enter; the old "swap in place" path was removed)
  → PaneManager.open_conversation(id, "__aiur_opencode__ <stuff>")
      → handle_call({:open, id, ...})
          → Aiur.Perf.event(:pane_open_request, id)
          → reconcile_visible_panes (drops stale tracked panes via tmux list-panes)
          → identifier_to_pane has id? → focus existing pane, return.
          → else open_opencode_pane:
              # LOCK-FREE FAST PATH (just added):
              case SlotRegistry.find_visible(id):
                {:ok, slot, pane_id} →
                  AttachPool.mark_visible(id, slot)         # cast
                  move_warm_pane_visible(state, id, slot, pane_id)
                    → Tmux.move_pane_visible (out of aiur-hidden into window 0)
                    → apply_layout
                    → broadcast :pane_opened
                :not_found →
                  case AttachPool.consume(id, exclude_visible: true):
                    {:ok, ...} → move_warm_pane_visible
                    :miss     → open_with_placeholder    # placeholder pane + async_drive_attach
```

The lock-free path catches the "leadoff agent" case. The `consume` path catches "non-leadoff attached agent". `open_with_placeholder` is the fallback for "no slot has this agent attached at all" — 5–7 s cold spawn.

## 6. Marker emoji rules (renderer)

```
opened_panes contains id           → 🟢 (visible in window 0)
attach_state[id].visible_in set    → ⚪ (painted in some slot, not opened)
attach_state[id].attach_count ≥ 1  → 🔘 (session exists in some slot, not painted)
none of the above                  → ⏳ (no slot has this id yet)
```

Overrides: paused → ⏸, queued → ⚫, error/done → AgentEvents glyph.

## 7. Pause / resume / capacity

- **Pause** (`Space` on a running agent): Orchestrator marks `running[id].work_state = :paused`. PaneManager's pane (if open) stays. `attach_state` unaffected.
- **Orchestrator capacity math**:
  ```
  available_slots = max_concurrent_agents - (active_running_count + paused_running_count)
  ```
  Paused agents **count against** capacity. The comment says this is intentional — "pause should not free a slot for auto-poll to claim". But the user's workflow is: pause #4 → manually unpause a ⏳-queued agent. With current math, that unpause sees 0 available slots → red flash "below_active_count".
- **Manual resume** (`Space` on paused or `Enter` on queued ⏳ that we want to start):
  - Paused → resume_paused_issue **bypasses** the capacity check.
  - Queued ⏳ → goes through normal dispatch → hits the capacity check.

The user wants: pause should free a slot **for manual resume only**, not for auto-poll. Today's code doesn't distinguish.

## 8. Broadcasts in flight

PubSub topic `opencode:slots`:
- `{:slot_ready, slot_index}`
- `{:slot_visible_changed, slot_index, identifier_or_nil}`
- `{:slot_session_changed, slot_index, identifier_or_nil}`
- `{:slot_attach_added, slot_index, identifier}`
- `{:slot_attach_removed, slot_index, identifier}`

Topic `attach_pool`:
- `{:attach_state_changed, identifier, attach_count, visible_in}`
- `{:attach_consumed, identifier, pane_id, slot_index}`
- `{:agent_inactive, identifier}`

AgentPubSub (separate, identifier-scoped):
- `:pane_opened`, `:pane_closed`, `:running_changed`, etc.

Every slot transition emits 2–4 broadcasts. AttachPool's handle_info processes each slot_* event and re-derives its own state, then re-broadcasts attach_state_changed. AgentList processes both topics. Bus traffic during fan-out is heavy.

## 9. What the simplification will change (recap of agreed direction)

1. **Drop eager fan-out.** Each slot paints only its leadoff at boot. `rest` attaches removed. Boot goes from 50 s → ~6 s.
2. **`SlotRegistry` ETS is the single source of truth.** AttachPool's `attachments`/`fanned_out_slots`/`in_flight` deleted. AgentList's `attach_state`/`visible_sessions` deleted. Renderer reads SlotRegistry directly on each tick.
3. **AttachPool becomes a stateless policy module** (or disappears entirely). The "find a slot for this identifier" question is answered by scanning SlotRegistry; the "paint it" verb is `Slot.set_visible`.
4. **Pause frees capacity for manual resume only.** Add a `:manual` flag to dispatch precondition that subtracts `paused_running_count` from the math. Auto-poll path stays as-is.
5. **Collapse broadcasts to one signal.** `:slot_state_changed` with `slot_index` payload. Subscribers re-read ETS. Drop `:slot_visible_changed`, `:slot_session_changed`, `:slot_attach_added`, `:slot_attach_removed`, `:attach_state_changed`, `:attach_consumed`.

## 10. Order of work (confirmed)

1. Pause → capacity (1 line in `Orchestrator.available_slots`, plus dispatch precondition tweak). Manual test: pause #4, unpause ⏳ #7, no red flash, pane opens.
2. Drop fan-out: each slot paints only its leadoff. Delete `kickoff_fan_out`'s `rest` loop, delete `fanned_out_slots` re-fire guard's reason for existing. Manual test: boot to all ⚪ in <10 s.
3. Collapse `AttachPool` to policy module. Delete `attachments`, `attach_state_changed`. Manual test: warm open still <100 ms, placeholder path still works for never-attached identifiers.
4. Migrate `AgentList` markers to ETS reads. Delete `attach_state`, `visible_sessions`. Manual test: markers stay correct through pause/resume + open/close.
5. Delete dead state, broadcasts, tests.

Each step: small focused commit, push, manual verification with logs pasted back here before moving to the next step.

## What I want you to correct

- Is anything in section 4 (state scoreboard) wrong about ownership / purpose?
- Is the `Slot.attach` "rest" loop in section 3 actually the bottleneck, or am I blaming the wrong thing?
- Is anything in section 7 (pause/resume) inconsistent with how you experience it?
- For step 1 of section 10 — is the right scope just `available_slots`, or do you want the manual-resume flag threaded everywhere?
