# Opencode pre-warm: spaghetti audit & simplification proposal

**Date**: 2026-05-23
**Branch**: `updated-opencode-logic`
**Context**: Iteration #N of "make Enter open opencode instantly". Latest regression: 50 s boot, all agents still ⏳. Pause-then-resume flashes red even when capacity is free. We keep adding layers without removing any.

This doc audits what we've built, names the spaghetti, and proposes a simpler
shape. **No code changes until we agree on the shape.**

## What we have today — every layer that tracks "where is agent X?"

| Layer | State | Updated by | Read by |
|---|---|---|---|
| `Slot` GenServer | `visible_identifier`, `pane_id`, `attached_identifiers`, `pending_select`, `known_identifiers`, `active_identifier/session_id` (dup of visible) | own callbacks | `Slot.snapshot` (call) |
| `SlotRegistry` (ETS) | `%{visible_identifier, pane_id}` per slot | Slot via `update_pane_state` | `find_visible/1`, `pane_state/1` (lock-free) |
| `AttachPool` GenServer | `attachments[id] = %{attached_slots, visible_in}`, `active_identifiers`, `in_flight`, `fanned_out_slots`, `fully_warmed_slots` | PubSub from Slot + `consume`/`mark_visible` casts | `consume` (call), `snapshot` (call) |
| `AgentList.state` | `attach_state[id]`, `visible_sessions[slot]`, `opened_panes`, `started_slots` | PubSub from Slot + AttachPool | renderer (marker emoji) |
| `PaneManager.state` | `identifier_to_pane`, `pane_to_identifier`, `pane_to_slot`, `slot_panes`, `placeholder_panes`, `last_attached_pane_id` | `open_conversation` / pane-died events | tmux layout, attach/close handling |
| `Orchestrator.state` | `running[id]` with `:active`/`:paused` work_state | run lifecycle | dispatch precondition, capacity math |

**Six modules. Same conceptual fact ("agent 14 is visible in slot 1 / pane %9") stored in five of them.**
Every transition fans out a `:slot_visible_changed`, `:slot_session_changed`, `:slot_attach_added`, `:slot_attach_removed`, `:attach_state_changed`, or `:attach_consumed`. AttachPool's mailbox bears the brunt; when fan-out is in flight, `consume` times out at 5 s and PaneManager falls into the cold placeholder path — even when the slot is already painted. (We bandaged that today with `SlotRegistry.find_visible`, which works but adds yet another redundant view of the same fact.)

## What's slow & wrong right now

1. **Boot fan-out attaches 6 × 6 = 36 sessions before any agent is ⚪.**
   Each slot independently calls `Slot.attach` for every active identifier in its rest list. Each attach is 0.5–15 s. 36 attaches serialized through 6 slot mailboxes = the 50 s boot the user just saw. The user's perception: "5x slower than before."

2. **Pause does not free a capacity slot.**
   `Orchestrator.available_slots = max - (active + paused)`. The code comment explicitly says paused agents "keep their slot reserved" so the auto-poll doesn't claim them. But the user wants pause to free capacity for manual resume of a queued ⏳ agent. Two different goals collided in one function.

3. **Leadoff reassignment is hand-rolled.**
   `kickoff_fan_out`, `fanned_out_slots`, `do_seed_pairing`, `seed_leadoff_reassignment` — all to answer "when a slot frees up, which queued identifier should it paint?". Currently driven by `Slot.snapshot` calls from inside AttachPool's handle_cast — adds more synchronous GenServer dependencies.

4. **AttachPool is a synchronous middleman.**
   PaneManager → AttachPool → Slot is a 3-hop synchronous call chain. Any one can wedge the others. The lock-free `SlotRegistry.find_visible` patch covered the painted-already case. Everything else still hops.

5. **Five emoji-marker inputs.**
   Renderer's `compute_markers` reads `opened_panes`, `attach_state`, `visible_sessions`, plus orchestrator status, plus pause state. Bugs in any one show up as a wrong emoji.

## What we actually need

A user pressing Enter on agent X wants:
- Open in <100 ms if a slot already has X's session loaded.
- Open in <2 s if a slot is free and just needs to load X.
- Surface "no capacity, pause something" if every slot is occupied with a different agent.

That's it. Three cases.

## Proposed simpler shape

### 1. One paint per slot at boot. Drop fan-out.

Today: each slot pre-attaches every active identifier (36 attaches at boot).
Proposed: each slot paints **only** its rotational leadoff identifier at boot (6 paints). Other identifiers attach **lazily** when the user opens them.

- Boot cost: 6 × ~1 s = ~6 s. Hits the <10 s bar.
- First open of a leadoff agent: <100 ms (already painted).
- First open of a non-leadoff agent: ~1 s (one attach call) or ~6 s (serve rebuild if identifier not in models map).
- Re-open of any previously-opened agent: <100 ms (still painted in some slot).

Trade-off: the first non-leadoff Enter pays a real cost. We can hide it behind a placeholder pane — the existing `open_with_placeholder` flow works for this. It's the rare case, not the common one.

### 2. `SlotRegistry` (ETS) becomes the single source of truth.

Today's state map collapses to:
- `Slot.visible_identifier/pane_id/status` — already mirrored to `SlotRegistry`.
- Drop `AttachPool.attachments` entirely. Anything that needs "who's visible where?" reads ETS directly.
- AgentList's marker computation reads ETS directly. No `attach_state` map, no `visible_sessions` map, no `:attach_state_changed` broadcast. Renderer subscribes to a single `:slot_state_changed` event ("re-render now") and pulls fresh state from ETS on each tick.
- `AttachPool` shrinks to a thin policy module (or disappears): "given the active identifier list and current `SlotRegistry` snapshot, which slot should paint which identifier next?". Pure function, no GenServer state.

### 3. Pause frees a capacity slot.

Change `Orchestrator.available_slots` to count `active_running_count` only — drop `paused_running_count` from the sum. Resume goes through `resume_paused_issue` which already bypasses the auto-poll check, so the "auto-poll claims paused slot" failure mode the original comment worried about doesn't actually happen now.

Test: pause #4 → active drops 6→5 → ⏳ agent's marker goes 🔘 (slot free for it) → Enter on the ⏳ agent paints it → opens.

### 4. PaneManager keeps its own view, but stops being a state store.

`identifier_to_pane`, `pane_to_slot`, `slot_panes` — keep, they're tmux bookkeeping that genuinely belongs to the layout owner. But drop `pane_to_identifier` (inverse of identifier_to_pane), `last_attached_pane_id` (move to AgentList — it's a UI focus concept), and `open_queue` (with eager fan-out gone, no one waits on `:slot_ready`).

### 5. Collapse the broadcast surface.

Today's broadcasts: `:slot_visible_changed`, `:slot_session_changed`, `:slot_attach_added`, `:slot_attach_removed`, `:slot_ready`, `:attach_state_changed`, `:attach_consumed`, `:pane_opened`, `:pane_closed`.

Proposed: `:slot_state_changed` (fired when a slot's `SlotRegistry` value changes — payload is just `slot_index`). Subscribers re-read ETS for fresh state. Three concepts (paint, attach, free) collapse into one signal.

## What we delete

- `AttachPool.attachments`, `fanned_out_slots`, `in_flight`, `fully_warmed_slots`
- `kickoff_fan_out`, `do_seed_pairing`, `seed_leadoff_reassignment`
- `AgentList.attach_state`, `AgentList.visible_sessions`
- `PaneManager.open_queue`, `PaneManager.open_queue_timers`, `PaneManager.last_attached_pane_id`
- `Slot.active_identifier`, `Slot.active_session_id` (already noted as dups of visible)
- Most `Slot.attach` call sites (kept only for the lazy "open a non-leadoff agent" path)
- `:slot_attach_added`, `:slot_attach_removed`, `:attach_state_changed`, `:attach_consumed` broadcasts
- Most of `enter_opens_new_pane_test.exs`'s file-source-grep assertions become moot

## Risks & open questions

- **Lazy attach on non-leadoff open**: is ~1 s acceptable for "first time you click a queued agent"? Or should we keep some background attach for the next-likely-clicked agent?
- **Identifier-miss rebuild (6 s)**: opencode-serve's models map is set at start. New identifiers trigger a serve rebuild. We need to pre-seed all 7 ticket identifiers into all serves at boot — already done, just confirming this stays.
- **Pause-during-poll race**: with paused not counting against capacity, the auto-poll could now claim a slot mid-pause-resume. Need to check `Orchestrator.dispatch` precondition still rejects the wrong cases.
- **PaneManager tmux state**: PaneManager's `slot_panes` still has to mirror what tmux thinks. Drift here was a real bug before. Reconcile-on-open stays.

## Suggested order of work (if we agree)

1. Fix pause → capacity (1 line in `Orchestrator.available_slots`). Verify red flash gone.
2. Drop the fan-out: each slot paints only its leadoff at boot. Verify <10 s boot.
3. Collapse `AttachPool` to a stateless policy module. Verify warm-open hot path still works.
4. Migrate `AgentList` markers to ETS reads. Verify markers correct after pause/resume.
5. Delete dead state, broadcasts, tests.

Each step independently shippable. After each: build release, run aiur, drive it, capture logs, paste here.

## What I want from you before I touch any code

- **Is dropping eager fan-out OK?** It's the biggest single simplification but it makes non-leadoff opens 1 s instead of 100 ms. Acceptable trade?
- **Is "pause frees capacity" really what you want?** Today's `available_slots` doc-comment is explicit that pause keeps the slot — was that ever correct, or was it a mis-spec from day 1?
- **Anything in the "What we delete" list you want to defend?** Some of those may be load-bearing for a use case I'm not seeing.
