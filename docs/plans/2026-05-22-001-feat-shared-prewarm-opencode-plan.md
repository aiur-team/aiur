---
title: "feat: Shared opencode pre-warm — multi-agent attach with lazy expansion"
type: feat
status: active
date: 2026-05-22
origin: https://github.com/aiur-team/aiur/issues/85
---

# feat: Shared opencode pre-warm — multi-agent attach with lazy expansion

## Overview

Restructure opencode pre-warm from **one slot = one agent** to **one slot = all active agents**. Each pre-warmed opencode instance carries every active agent session; any chat pane can switch to any agent via `/tui/select-session`. Initial boot pre-warms only Slot 1; subsequent slots warm lazily as the user opens panes. New 4-state per-row marker (⏳ → 🔘 → ⚪ → 🟢) replaces the binary "open pane" glyph. New keybinds: `Enter` swaps the session in the last-used chat pane; `Shift+Enter` opens in a fresh pane; `Option+Tab` inside a chat pane returns focus to the agent list pane. A 🖥️ row under the bottom nav surfaces how many opencode instances are fully warmed.

---

## Problem Frame

Today's `Slot` is bound to a single identifier via `Slot.select/2`. The pre-warmer (`SlotPolicy` + `AttachPool`) picks the first N agents off the active set, claims one slot per agent, and respawns `opencode attach --session <id>` in each. Result:

- Only N of M active agents are reachable instantly. The other M − N must wait for a full pre-warm cycle (5–7 s) at first open.
- If the user skips the first N agents and opens #6 first, the four pre-warms for #1–#5 were wasted.
- Pre-warm cost is fixed at N × full-attach regardless of how many panes the user actually opens.

The new model fixes all three: every Slot can show any agent, lazy expansion pays cost only when the user demands more panes, and fan-out runs in parallel across all Slots that are warming.

Verified spike (opencode 1.15.6): `/tui/select-session` works per-serve (i.e. when each Slot owns its own opencode-serve), so multi-serve architecture is preserved; shared-serve was rejected (call is server-wide and broadcasts to all attaches). See origin issue's Spike section.

---

## Requirements Trace

- **R1.** At startup, Slot 1 boots its opencode-serve and begins attaching all currently-active agents. Slots 2..N do **not** boot yet.
- **R2.** When the user opens the first chat pane (any agent), Slot 2 begins pre-warming. When the (N-1)th chat pane opens, Slot N begins. Cap at `Aiur.Config.max_vertical_panes()` (default 5).
- **R3.** Each booting Slot starts its attach fan-out at the agent matching its index (Slot i → agent at position i), then continues with `i+1, i+2, ..., wrap → 1, 2, ...` until all active agents are attached.
- **R4.** When a new agent enters the active set, every currently-running Slot starts attaching it in parallel.
- **R5.** When an agent leaves the active set (PR merged, `agent:done`, removed), it is detached from every Slot's serve. If it was the visible session in any chat pane, that pane closes.
- **R6.** Each agent row shows a 4-state marker based on `(attach_count, visible_count, visible_in_some_pane?)`:
  - ⏳ when `attach_count == 0`
  - 🔘 when `attach_count >= 1` but `< visible_count + 1`
  - ⚪ when `attach_count >= visible_count + 1`
  - 🟢 when the agent is the visible session in any chat pane
- **R7.** `Enter` on a non-visible row → calls `/tui/select-session` on the last-used chat pane's serve to swap that pane to the selected agent. Beep / no-op on ⏳.
- **R8.** `Shift+Enter` on a row → opens that agent in a new chat pane (current `Enter` behavior). Beep / no-op when the row's status is ⏳ or 🔘. Calls `SlotPolicy.bump/0` to start the next Slot if there is one left to warm.
- **R9.** `Option+Tab` inside any chat pane → tmux focuses the agent list pane.
- **R10.** A 🖥️ row sits under the bottom nav of the agent list, one 🖥️ per fully-warmed Slot (a Slot is "fully warmed" when its attached-identifiers set equals the active-agents set).
- **R11.** `aiur_perf` log lines emit on every attach state transition: attach added, attach removed, visible-set, fan-out start, fan-out done, detach, slot bumped, agent active-set change. Always-on, not behind `--debug`.
- **R12.** Wall-time deltas for "first-attach → ⚪-loose" (would have flipped on first attach) and "first-attach → ⚪-strict" (current threshold rule) are computable from log replay for the same run.
- **R13.** Existing functionality preserved: opening an agent, switching focus across panes, closing chat panes, `q`/`Ctrl+C` shutdown, pause/resume, max-agent adjust.

---

## Scope Boundaries

- Re-opening done agents from a separate filtered view — tracked by #84.
- Persisting attach state across `aiur` restarts.
- Cross-pane drag/drop or any mouse UX.
- Sharing a single opencode-serve across all attaches (spike-rejected for 1.15.6).
- Renaming `AttachPool` to `AttachRegistry` — keep the module name `Aiur.Opencode.AttachPool` to minimize churn; rewrite its internals only.
- Changing `max_vertical_panes` default.
- An "always-strict" or "always-loose" config switch — both timings are surfaced for measurement; the strict rule ships as the only enforced rule in this PR.

---

## Context & Research

### Relevant Code and Patterns

- `elixir/lib/aiur/opencode/slot.ex` — current `Slot` GenServer (772 lines). State machine `:booting → :serve_starting → :attach_spawning → :ready → :active`. `select/2` binds to one identifier and respawns the attach pane with `--session`. `known_identifiers` MapSet tracks the slot's opencode.json model entries; identifier-miss path rebuilds the serve.
- `elixir/lib/aiur/opencode/slot_policy.ex` — chain-pre-warmer (112 lines). Currently boots all `target_count` slots in parallel at init.
- `elixir/lib/aiur/opencode/attach_pool.ex` — per-identifier pre-warm pool (505 lines). State machine `pending → warming → warm → consumed`. One slot per identifier.
- `elixir/lib/aiur/opencode/session_writer.ex` — per-(identifier, base_url) writer. One writer per agent today; will be one writer per (agent, slot) pair (one per agent's session in each slot's serve).
- `elixir/lib/aiur/pane_manager.ex` — owns pane↔identifier mapping. `open_opencode_pane` does the warm-path acquire + move-pane visible. Tracks `last_attached_pane_id` already (introduced for the `a` keybind).
- `elixir/lib/aiur/agent_list/app.ex` — agent-list orchestrator. Subscribes to PubSub topics; maintains `warm_identifiers` MapSet and `running_open_pane` map.
- `elixir/lib/aiur/agent_list/renderer.ex` — `@open_pane_glyph "●"` at line 36, rendered at line 471. This is the cell we replace with the 4-state emoji.
- `elixir/lib/aiur/agent_list/input.ex` — stdin raw-mode dispatcher. Currently handles `\r`, arrow CSI, single chars. No support for CSI-u modifier sequences.
- `scripts/aiur.tmux.conf` — Aiur's isolated tmux conf. Already binds `Tab` / `BTab` for pane cycle; `M-Tab` is free.

### Institutional Learnings

- The current `Slot.select` cannot rely on `POST /tui/select-session` to render-switch from welcome → conversation (opencode 1.15.6 limitation noted in slot.ex L508–L514). Confirmed by the multi-serve spike in origin: **conversation → conversation works**, **welcome → conversation requires attach respawn with `--session`**. So a Slot's pane must boot with `--session <leadoff_agent>` from the start, and subsequent in-pane swaps can use `/tui/select-session` cheaply.
- PR #83 (already in main) made `SessionWriter` replay survive transaction-level contention; we can run many writers in parallel against one slot's serve without re-hitting the corruption bug.
- The `BTab` binding (Shift+Tab) is already taken in `scripts/aiur.tmux.conf` for "cycle left". Picking `Option+Tab` (`M-Tab`) for back-to-nav avoids collision.

### External References

- `opencode` 1.15.6 `attach` command — accepts `--session <id>` for boot-time session selection. `/tui/select-session` HTTP API works for conversation→conversation, not for welcome→conversation.

---

## Key Technical Decisions

- **Multi-serve preserved.** One opencode-serve per Slot. Spike already rejected shared-serve.
- **Slot owns a set of attached identifiers + at most one visible identifier.** Replaces today's single `active_identifier` field. Visibility is decoupled from attach state.
- **Lazy expansion driven by PaneManager → SlotPolicy.bump/0.** PaneManager calls `bump` after a `:new_pane` open succeeds. SlotPolicy is idempotent: same call twice does not start a second slot.
- **Strict ⚪ threshold ships; loose timing is logged for measurement.** Both wall times are computable from `aiur_perf` log replay; we ship only the strict rule. Avoids dual code paths and avoids burning a real "loose-mode" config the user later has to maintain.
- **Per-Slot session DB stays slot-local.** Each Slot's opencode-serve has its own SQLite. SessionWriter creates one session per agent in each slot's serve. No cross-slot session sharing.
- **AttachPool module retained, internals rewritten.** Renaming the module ripples through tests + callers for no gain. The renaming was a brainstorm-time naming preference; the implementation owns its own clarity.
- **Boot-time session selection.** Each Slot's attach pane is launched with `--session <leadoff>` for the deterministic leadoff agent (Slot i → agent i). Subsequent swaps use `/tui/select-session`.
- **Per-slot leadoff hardening.** If Slot i's leadoff agent (active-list index i, 0-based or 1-based — confirmed during implementation as 1-based, matching slot indexing) is gone before the slot boots, fall back to the next-available index without altering the rest of the fan-out order.
- **Shift+Enter encoding fallback.** Detect via CSI-u (`\e[13;2u`) when available; fall back to `O` (capital-O) as the open-in-new-pane keybind for terminals that can't disambiguate Shift+Enter. Document both in the help overlay. This is a real terminal-portability concern — many terminals collapse Shift+Enter into Enter.

---

## Open Questions

### Resolved During Planning

- *How does `/tui/select-session` behave once both panes are rendering conversations?* Per-serve, per-pane. Multi-serve architecture isolates the call.
- *Does pre-warm need to wait for the orchestrator's active-agent list?* Yes — Slot 1 boot already waits up to 3 s for `Orchestrator.list_active_identifiers/2` to populate (slot.ex `safely_list_active_identifiers/0`). Reuse for Slots 2+.
- *Should done agents close their visible panes immediately?* Yes (R5). Failing to close would leave the pane talking to a serve whose session was just deleted.

### Deferred to Implementation

- *Exact session-writer fan-out concurrency limit per slot* — depends on how the rewritten writers behave under N parallel ensures against one serve. Tune during U3 with `aiur_perf` data.
- *Whether 🖥️ row config name becomes `opencode.warm_status_row` (renaming the misnomered `lightning_status_row`)* — the config touches `Aiur.Config`, decide during U5.
- *Exact byte sequence the user's terminal emits for `Shift+Enter`* — confirmed during U6 (manual test in iTerm, Terminal.app, and Termius if available). Fallback key `O` documented regardless.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

### State machines

```
Slot (per-slot worker)
─────────────────────
   :booting                                   ← workspace + opencode-serve start
   :serve_starting                            ← await Server.await_ready
   :attach_spawning                           ← tmux split-pane attach --session <leadoff>
   :ready                                     ← attach pane rendered first conversation
                                                attached_identifiers grows in background
                                                visible_identifier = leadoff or nil
                                                bg: SessionWriter.ensure for every other
                                                    active agent, push attach_added events

AttachPool (per-identifier registry)
───────────────────────────────────
   per identifier: %{
     attached_slots: MapSet,
     visible_in:      slot_index | nil
   }

Renderer cell (per agent row)
─────────────────────────────
   attach_count = MapSet.size(attached_slots)
   visible      = visible_in != nil
   visible_count_total = count over all identifiers where visible_in != nil

   ⏳ ← attach_count == 0
   🔘 ← attach_count >= 1 and < visible_count_total + 1
   ⚪ ← attach_count >= visible_count_total + 1
   🟢 ← visible == true
```

### Open flow

```
[Enter on row X (non-visible, status >= 🔘)]
        │
        ▼
PaneManager.open_opencode_pane(X, :swap_in_last_used)
        │ find slot_index with X ∈ attached_slots, prefer last-used pane's slot
        ▼
Slot.set_visible(slot_pid, X)
        │ POST /tui/select-session on slot's serve
        ▼
broadcast :visible_changed → AgentList recomputes markers

[Shift+Enter on row X (status == ⚪)]
        │
        ▼
PaneManager.open_opencode_pane(X, :new_pane)
        │ find slot whose pane is NOT currently visible AND has X attached
        ▼
Slot.set_visible(slot_pid, X) + Tmux.move_pane_visible(...)
        │
        ▼
SlotPolicy.bump() ← start next Slot's pre-warm
```

---

## Implementation Units

- [ ] **U1. Refactor Slot to attach_many / set_visible model**

  **Goal:** Replace `Slot.select/2`'s "bind to one identifier" model with `attach/2`, `detach/2`, `set_visible/2`. Each Slot's state tracks an `attached_identifiers` MapSet and an optional `visible_identifier`.

  **Requirements:** R1, R3, R4, R5, R7 (Slot side of the swap), R13.

  **Dependencies:** none.

  **Files:**
  - Modify: `elixir/lib/aiur/opencode/slot.ex`
  - Modify: `elixir/lib/aiur/opencode/slot_supervisor.ex` (call-site doc/comment updates)
  - Modify: `elixir/lib/aiur/opencode/workspace_setup.ex` (doc/comment updates)
  - Test: `elixir/test/aiur/opencode/slot_test.exs`

  **Approach:**
  - Replace `active_identifier` / `active_session_id` with `attached_identifiers :: MapSet.t(String.t())`, `visible_identifier :: String.t() | nil`, `visible_session_id :: String.t() | nil`.
  - `attach(server, identifier)` — runs `SessionWriterRegistry.ensure/2` against the slot's serve, awaits replay, adds identifier to set, broadcasts `{:slot_attach_added, slot_index, identifier}`. Idempotent.
  - `detach(server, identifier)` — removes from set; if it was the visible identifier, clears visibility and kills the attach pane (slot returns to attach-less :ready). Broadcasts `{:slot_attach_removed, slot_index, identifier}`.
  - `set_visible(server, identifier)` — first call (no current visible): respawn attach pane with `--session`. Subsequent calls: POST `/tui/select-session` on the slot's serve. Broadcasts `{:slot_visible_changed, slot_index, identifier}`. Returns `{:ok, pane_id}`.
  - `clear_visible(server)` — clears visible, no pane destroy (idle pane keeps its current render until a new `set_visible` lands).
  - Keep the boot-time `safely_list_active_identifiers/0` path but have it return its result up to the new caller — Slot does not auto-attach all active identifiers itself; the caller (a new `Slot.attach_many/2` convenience that loops over a list) drives it. Slot 1's startup uses `attach_many` with the active-agent list, leadoff = first.
  - Preserve identifier-miss rebuild as a fallback for `set_visible` when the agent isn't in the serve's models map yet.
  - Preserve poll loop for pane death: poll any time `visible_identifier != nil`.

  **Patterns to follow:** existing `do_select` / `select_with_respawn` shape in slot.ex L447–L546.

  **Test scenarios:**
  - Happy path: `attach/2` for two identifiers, then `set_visible/2` for the first → pane renders that conversation; `set_visible/2` for the second → pane swaps to the second's session.
  - Happy path: `attach_many/2` with three identifiers in order; assert `attached_identifiers` ends as the full set, no respawns triggered (no `set_visible` yet).
  - Edge case: `set_visible/2` for an identifier NOT yet in `attached_identifiers` → returns `{:error, :not_attached}` without rebuilding the serve.
  - Edge case: `detach/2` of the visible identifier → kills the attach pane and clears visibility; subsequent `set_visible/2` on a still-attached identifier respawns the pane cleanly.
  - Edge case: `attach/2` on an identifier the slot's opencode.json doesn't know yet → triggers identifier-miss rebuild, preserving `attached_identifiers` and `visible_identifier` through the rebuild.
  - Error path: `attach/2` on a `:failed` slot → returns `{:error, {:slot_not_ready, :failed}}`.
  - Error path: replay timeout from `SessionWriter.await_replay` propagates as `{:error, reason}` from `attach/2` (not a crash).
  - Integration: PubSub broadcasts `:slot_attach_added`, `:slot_attach_removed`, `:slot_visible_changed` on the existing `Slot.slots_topic/0` topic with the new payload shapes.

  **Verification:** all of slot_test.exs passes against the new API; no caller of `Slot.select/2` remains in `lib/`.

- [ ] **U2. Refactor SlotPolicy to lazy expansion + bump API**

  **Goal:** Boot only Slot 1 at init. Expose `bump/0`; each call starts the next slot in sequence up to `max_vertical_panes`.

  **Requirements:** R1, R2.

  **Dependencies:** U1.

  **Files:**
  - Modify: `elixir/lib/aiur/opencode/slot_policy.ex`
  - Test: `elixir/test/aiur/opencode/slot_policy_test.exs` (new)

  **Approach:**
  - At init, only start Slot 1 (instead of all `target_count` in parallel).
  - On Slot 1 ready, do NOT chain — wait for `bump/0`.
  - `bump/0`: if `highest_started < max_vertical_panes`, start `highest_started + 1`. Idempotent under concurrent calls.
  - Keep `:slot_ready` subscription for `:chain_complete` telemetry (now fires when the last bumped slot reports ready, or never if user never bumps to the max).

  **Patterns to follow:** existing `handle_info(:start_first_slot, ...)` in slot_policy.ex.

  **Test scenarios:**
  - Happy path: init starts only Slot 1; SlotRegistry shows exactly one slot after a 2-second wait.
  - Happy path: `bump/0` starts Slot 2; second `bump/0` starts Slot 3; etc., up to `max_vertical_panes`.
  - Edge case: `bump/0` past `max_vertical_panes` is a no-op; returns `:ok`.
  - Edge case: two concurrent `bump/0` calls race, only one Slot N+1 starts.
  - Error path: if SlotSupervisor returns `{:error, _}` on a bump, `highest_started` does not increment, so a retry bumps the same slot.

  **Verification:** integration test where calling `SlotPolicy.bump/0` `max_vertical_panes` times stands up the full grid.

- [ ] **U3. Rewrite AttachPool internals as multi-attach registry**

  **Goal:** Track which slots have each identifier attached, plus which slot currently has it visible. Keep the module name `Aiur.Opencode.AttachPool` to limit blast radius.

  **Requirements:** R3, R4, R5, R6 emoji inputs, R13.

  **Files:**
  - Modify: `elixir/lib/aiur/opencode/attach_pool.ex`
  - Modify: `elixir/test/aiur/opencode/attach_pool_test.exs` (existing; rewrite)
  - Test: `elixir/test/aiur/opencode/attach_pool_test.exs`

  **Approach:**
  - Replace per-identifier `%{status, slot_index, pane_id}` struct with `%{attached_slots: MapSet, visible_in: slot_index | nil}`.
  - Drive state from new Slot PubSub events: `:slot_attach_added`, `:slot_attach_removed`, `:slot_visible_changed`.
  - Public API:
    - `attach_count(identifier)` — returns integer (0 when unknown).
    - `visible_count()` — total number of identifiers currently visible across all slots.
    - `find_slot_for(identifier, prefer_slot \\ nil, exclude_visible \\ false)` — finds a slot that has identifier attached. With `exclude_visible: true`, skips slots whose visible_identifier matches another agent (so we don't steal the user's currently-shown session).
    - `snapshot()` — returns the full map for debugging / renderer consumption.
  - Remove `seed/2`, `consume/2`, `:attach_warming`, `:attach_warm` — those are subsumed by the new event flow.
  - Add a new event broadcast on the `attach_pool` topic when totals change: `{:attach_state_changed, identifier, attach_count, visible_in}` so AgentList can recompute markers without polling.
  - Fully-warmed Slot detection: maintain `fully_warmed_slots :: MapSet` keyed on slot_index, updated when (active_agents ⊆ attached_in_slot). Broadcast `{:slot_fully_warmed, slot_index}` and `{:slot_warmth_dropped, slot_index}`.

  **Test scenarios:**
  - Happy path: simulate `:slot_attach_added` events for two slots × two identifiers; `attach_count/1` returns 2 for each, `visible_count/0` returns 0.
  - Happy path: `:slot_visible_changed` for one slot+identifier; `visible_count/0` returns 1, `find_slot_for` returns that slot.
  - Edge case: `:slot_attach_removed` brings attach_count back to 0; `:attach_state_changed` event fires with `attach_count: 0` so renderer drops marker to ⏳.
  - Edge case: `:slot_attach_added` for an agent that's already attached in that slot is idempotent.
  - Edge case: `find_slot_for(id, prefer_slot: nil)` returns `nil` when nothing is attached.
  - Integration: agent-active-set adds an identifier; Slot worker broadcasts attach_added for each slot; AttachPool aggregates and emits one `:attach_state_changed` per change.

  **Verification:** attach_pool_test.exs passes; old test names referencing `:warm`, `:consumed`, `seed` are deleted or rewritten.

- [ ] **U4. AgentList consumes new events; computes 4-state emoji per row**

  **Goal:** Replace the binary `warm_identifiers` MapSet + `running_open_pane` map with a per-identifier state record. AgentList listens to `:attach_state_changed`, `:slot_fully_warmed`, `:slot_warmth_dropped`. Renderer is fed the data structure it needs to pick the emoji.

  **Requirements:** R6, R10, R13.

  **Dependencies:** U3.

  **Files:**
  - Modify: `elixir/lib/aiur/agent_list/app.ex`
  - Test: `elixir/test/aiur/agent_list/app_test.exs` or `elixir/test/aiur/agent_list/agent_list_test.exs` (whichever currently exists; add coverage)

  **Approach:**
  - State holds `attach_state :: %{identifier => %{attach_count: non_neg_integer(), visible_in: slot_index | nil}}` and `fully_warmed_slots :: MapSet`.
  - On `:attach_state_changed` PubSub: merge into `attach_state`, recompute, push render.
  - On agent leaves active set: drop entry; render.
  - Pass `attach_state` and `fully_warmed_slots` to the renderer in addition to current state.

  **Test scenarios:**
  - Happy path: PubSub `:attach_state_changed` updates the AgentList's `attach_state` and triggers a render with the right marker count.
  - Edge case: agent's `visible_in` flips from `nil` → slot 1 → `nil`; renderer transitions ⚪ → 🟢 → ⚪.
  - Integration: drive a synthetic two-slot, two-agent scenario; observe the row emoji at each step.

  **Verification:** app/agent-list tests pass; old `warm_identifiers` MapSet no longer present.

- [ ] **U5. Renderer 4-state emoji column + 🖥️ row**

  **Goal:** Remove `@open_pane_glyph "●"`. Replace the gap-rendered glyph with the 4-state cell (⏳/🔘/⚪/🟢). Add a 🖥️ status row beneath the bottom nav: one 🖥️ per fully-warmed slot, plus empty placeholders so the count reads instantly.

  **Requirements:** R6, R10.

  **Dependencies:** U4.

  **Files:**
  - Modify: `elixir/lib/aiur/agent_list/renderer.ex`
  - Modify: `elixir/lib/aiur/config.ex` (add `opencode.warm_status_row` config, replacing the placeholder `lightning_status_row` name if it exists)
  - Test: `elixir/test/aiur/agent_list/renderer_test.exs` or matching existing renderer test

  **Approach:**
  - Drop `@open_pane_glyph` and the `[" ", @open_pane_glyph, " "]` site (renderer.ex L471).
  - Compute the marker from `attach_state` for the row's identifier and `visible_count` total.
  - 🖥️ row: write under the existing footer row. Width = `inner_width`; content = `"🖥️ " * fully_warmed_count` left-padded into the available width. Each 🖥️ + space is exactly 3 terminal columns.
  - Help overlay legend updated to show the 4 emoji and their meanings.

  **Patterns to follow:** existing footer / bottom-border render in renderer.ex L96–L108.

  **Test scenarios:**
  - Happy path: render a frame with 3 agents, 0 attached → all rows show ⏳.
  - Happy path: 1 attached to slot 1, 0 visible → ⚪ (since `1 >= 0 + 1`).
  - Edge case: 1 attached, 1 visible (same agent) → 🟢. The next-most-attached agent with `attach_count: 1` is 🔘 (since `1 < 1 + 1`).
  - Edge case: 🖥️ row shows N glyphs when `fully_warmed_slots` count is N.
  - Integration: render before and after a `:visible_changed` event; assert the swapped agent transitions ⚪ → 🟢 and the previous transitions 🟢 → ⚪.

  **Verification:** renderer tests pass; manual run shows the new column.

- [ ] **U6. Input: Shift+Enter open-in-new-pane + Enter swap semantics**

  **Goal:** Detect Shift+Enter in raw mode; route Enter → swap-in-last-used; route Shift+Enter → new-pane.

  **Requirements:** R7, R8.

  **Dependencies:** U7 (PaneManager modes must exist first to wire to; can be developed in lockstep but committed in this order).

  **Files:**
  - Modify: `elixir/lib/aiur/agent_list/input.ex`
  - Modify: `elixir/lib/aiur/agent_list/app.ex` (add `activate_new_pane/1` cast)
  - Test: `elixir/test/aiur/agent_list/input_test.exs` (existing or new)

  **Approach:**
  - In raw-mode read loop, recognize the CSI-u sequence `\e[13;2u` (Shift+Enter under modifyOtherKeys-2 / kitty keyboard protocol) → dispatch to `App.activate_new_pane/1`.
  - Also accept `O` (uppercase) as a fallback for terminals that don't emit CSI-u for Shift+Enter. Document both in help overlay.
  - `\r` and `\n` stay routed to `App.activate/1` (now means swap-in-last-used).
  - Enable modifyOtherKeys in `enter_raw_mode/1`: emit `\e[>4;2m` and `\e[?2017h` on entry, restore on `terminate/2`. Idempotent.

  **Test scenarios:**
  - Happy path: feed `\r` → `App.activate/1` called once.
  - Happy path: feed `\e[13;2u` → `App.activate_new_pane/1` called once.
  - Happy path: feed `O` → `App.activate_new_pane/1` called once.
  - Edge case: feed `\eO` (some terminals send this for F-keys) — no false activation.
  - Edge case: terminate restores stty AND emits `\e[>4;0m` to disable modifyOtherKeys.
  - Integration: end-to-end through `enter_raw_mode` + read loop with a fake `input_fun`.

  **Verification:** manual CLI test confirms Shift+Enter works on the user's terminal; if not, `O` still works.

- [ ] **U7. PaneManager: swap-in-last-used vs new-pane open modes**

  **Goal:** Add a mode parameter to the opencode-open path. Track last-used chat pane already exists (`last_attached_pane_id`); reuse it. On `:new_pane` mode, call `SlotPolicy.bump/0` after the pane goes visible.

  **Requirements:** R2, R7, R8, R13.

  **Dependencies:** U1, U2, U3.

  **Files:**
  - Modify: `elixir/lib/aiur/pane_manager.ex`
  - Modify: `elixir/lib/aiur/agent_list/app.ex` (call new API with mode)
  - Test: `elixir/test/aiur/pane_manager_test.exs`, plus a new mode-specific scenario.

  **Approach:**
  - `open_opencode_pane(identifier, opts \\ [])` — `opts` may include `mode: :swap_in_last_used | :new_pane`. Default `:new_pane` (matches today's behavior for non-Enter triggers).
  - `:swap_in_last_used` — look up `last_attached_pane_id`; ask AttachPool which slot serves that pane (via `pane_to_slot`); call `Slot.set_visible(slot_pid, identifier)`. No pane move.
  - `:new_pane` — find a slot with identifier attached AND whose pane isn't currently visible (via AttachPool.find_slot_for); if none has it attached, fall back to attach-then-visible. Move pane visible. After success: `SlotPolicy.bump()`.
  - Update `last_attached_pane_id` after every successful set_visible.

  **Test scenarios:**
  - Happy path `:swap_in_last_used`: with one chat pane open, calling swap on a different identifier flips the visible session in the same pane.
  - Happy path `:new_pane`: with one chat pane open, calling new on a different identifier spawns a new chat pane and bumps SlotPolicy.
  - Edge case `:swap_in_last_used` with `last_attached_pane_id == nil`: fall through to `:new_pane`.
  - Edge case `:new_pane` when no slot has identifier attached: AttachPool kicks off attach in some slot, PaneManager waits up to `@open_queue_timeout_ms` for `:attach_added`, then proceeds.
  - Edge case: `:new_pane` past `max_vertical_panes` open: existing cycle behavior preserved (recycle oldest slot).
  - Integration: full open of two agents in two panes; swap one to a third agent; assert pane count stays 2 and 🖥️ row, attach state, markers all reconcile.

  **Verification:** existing pane_manager_test.exs passes; new mode test passes.

- [ ] **U8. tmux Option+Tab binding back-to-nav**

  **Goal:** From inside any chat pane, `Option+Tab` (Alt+Tab) focuses the agent-list pane.

  **Requirements:** R9.

  **Dependencies:** none (decoupled from Elixir changes).

  **Files:**
  - Modify: `scripts/aiur.tmux.conf`

  **Approach:**
  - Add `bind-key -n M-Tab select-pane -t :.0` to the conf, alongside the existing `Tab` / `BTab` lines. Pane 0 is the agent list by Aiur convention; the `C-c` handler in the same file already keys off `pane_index == 0`.
  - Add a brief comment explaining the convention so it isn't bonded to a "magic" pane index.

  **Test scenarios:**
  - Manual: launch aiur, open 2+ chat panes, hit `Option+Tab` from each — focus should jump back to the agent list.
  - Test expectation: no unit test (pure tmux config).

  **Verification:** manual CLI run.

- [ ] **U9. Detach-on-done lifecycle**

  **Goal:** When an agent leaves the active set, detach it from every Slot's serve and close any pane currently showing it.

  **Requirements:** R5.

  **Dependencies:** U1, U3.

  **Files:**
  - Modify: `elixir/lib/aiur/agent_list/app.ex` (already watches agent state; broadcast detach)
  - Modify: `elixir/lib/aiur/opencode/attach_pool.ex` (handle `:agent_inactive` event)
  - Modify: `elixir/lib/aiur/pane_manager.ex` (close pane if pane was showing the removed agent)
  - Test: `elixir/test/aiur/regression/done_agent_detach_test.exs` (new)

  **Approach:**
  - AgentList watches `AgentPubSub` for active-set deltas; emits `{:agent_inactive, identifier}` on `attach_pool` topic.
  - AttachPool drives `Slot.detach(slot_pid, identifier)` for every slot the identifier was attached to. Awaits replies before clearing local state to avoid race with concurrent `:new_pane` requests.
  - PaneManager listens for `:slot_visible_changed` with `nil` payload; if the cleared identifier matched the pane's current agent, closes the pane.

  **Test scenarios:**
  - Happy path: agent A attached to slots 1+2, visible in slot 1. Agent transitions inactive. Pane closes; slots 1+2 broadcast `:slot_attach_removed`; renderer drops row to ⏳ then row disappears entirely.
  - Edge case: agent inactive while in attach_added queue (race) — no orphaned attached state.
  - Edge case: agent inactive while not attached anywhere — no-op.

  **Verification:** new regression test passes; manual CLI verifies pane auto-closes when an agent finishes.

- [ ] **U10. aiur_perf instrumentation + measurement report**

  **Goal:** Always-on `aiur_perf` event lines for every attach lifecycle transition; a compact end-of-run / on-demand report that prints first-attach-to-⚪-loose vs first-attach-to-⚪-strict deltas per identifier from the same log.

  **Requirements:** R11, R12.

  **Dependencies:** U1, U3.

  **Files:**
  - Modify: `elixir/lib/aiur/opencode/slot.ex`, `attach_pool.ex` — add Aiur.Perf events for the new transitions.
  - Add: `elixir/lib/aiur/opencode/warmth_report.ex` — module that takes the in-memory perf log (or replays from file) and computes the deltas.
  - Modify: `scripts/aiur` — accept a `--warmth-report` flag that exits the run after dumping the report.
  - Test: `elixir/test/aiur/opencode/warmth_report_test.exs` (new)

  **Approach:**
  - Reuse `Aiur.Perf.span_begin/2` and `Aiur.Perf.event/2` (already used in slot.ex, attach_pool.ex).
  - New events: `:slot_attach_added`, `:slot_attach_removed`, `:slot_visible_changed`, `:slot_fully_warmed`, `:slot_warmth_dropped`, `:slot_policy_bumped`, `:agent_inactive`.
  - WarmthReport reads from `Aiur.Perf` event log and computes per-identifier: t0 = first `:slot_attach_added`, t_loose = same as t0 (would have been ⚪ on first attach), t_strict = first time `attach_count >= visible_count + 1`. Print delta as a markdown table.

  **Test scenarios:**
  - Happy path: feed a synthetic perf log with 2 identifiers, 3 attaches each; assert the report computes the correct strict vs loose deltas.
  - Edge case: identifier never reaches strict threshold — report shows `strict: never`.
  - Edge case: identifier inactive before strict threshold — row marked `dropped`.

  **Verification:** WarmthReport unit tests pass; `scripts/aiur --warmth-report` exits cleanly with the table.

- [ ] **U11. End-to-end feature test**

  **Goal:** A single integration test that walks the full flow and asserts the design end-to-end.

  **Requirements:** R1–R12 covered.

  **Dependencies:** U1–U10.

  **Files:**
  - Add: `elixir/test/aiur/regression/shared_prewarm_e2e_test.exs`

  **Approach:**
  - Test starts aiur in a sandboxed mode (tmux mock + opencode-serve mock or a stripped-down test bridge). Seed 3 fake-active agents.
  - Walks the steps:
    1. After init, only Slot 1 exists in SlotRegistry; only Slot 1 has attached identifiers.
    2. Eventually Slot 1's `attached_identifiers == active_set`; `:slot_fully_warmed` fires; renderer shows 1 🖥️.
    3. Open first chat pane (agent X) — Slot 2 starts pre-warming. Marker for X becomes 🟢.
    4. Eventually Slot 2 is also fully warmed; renderer shows 2 🖥️. Other rows transition 🔘 → ⚪ as fan-out catches up.
    5. Shift+Enter on a ⚪ row → second pane opens; SlotPolicy bumps (no Slot 3 if max=2).
    6. Enter on a non-visible row from last-used pane → swap session in that pane; markers update.
    7. Drop an agent inactive → its pane closes, its row drops to ⏳ then disappears.

  **Test scenarios:**
  - Happy path: full sequence above.
  - Edge case: max_vertical_panes = 1 (no Shift+Enter slack) — every row stays 🔘 max, never reaches ⚪.
  - Edge case: 5 active agents, max_vertical_panes = 2 — both slots eventually fully warmed.

  **Verification:** the test runs green standalone; `mix test --only e2e` includes it.

---

## System-Wide Impact

- **Interaction graph:** `Aiur.Opencode.Slot` lifecycle now drives three new PubSub events that `AttachPool`, `PaneManager`, `AgentList.App` all subscribe to. The existing `:slot_session_changed` event from `Slot` is retired in favor of `:slot_visible_changed` with matching payload but the new event name avoids stale subscribers seeing surprising semantics.
- **Error propagation:** Replay timeouts and respawn failures must propagate as `{:error, _}` returns from the new `Slot.attach/2` and `Slot.set_visible/2`, not crashes. This continues PR #83's pattern of surfacing failures rather than killing the worker.
- **State lifecycle risks:** Concurrent `attach/2` + `detach/2` on the same identifier during a pane bump. Mitigation: `SessionWriterRegistry.ensure/2` is idempotent; detach is awaited before AttachPool clears the entry.
- **API surface parity:** All `Slot.select/2` call sites updated (attach_pool, pane_manager — only library callers). Tests touched: slot_test.exs, attach_pool_test.exs, regression/warm_state_transitions_test.exs, regression/warm_marker_semantics_test.exs, regression/warm_attach_open_test.exs, regression/prewarm_complete_time_test.exs.
- **Integration coverage:** U11 plus the new regression test in U9 covers the lifecycle. Unit tests alone won't catch `/tui/select-session` not switching from welcome → conversation.
- **Unchanged invariants:** `Aiur.PaneManager.Layout`, the tmux grid math, `q`/`Ctrl+C` shutdown, `Tracker` integration, pause/resume.

---

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| Shift+Enter not emittable by user's terminal | `O` fallback keybind documented in help overlay. Manual test in U6 confirms which one works. |
| `/tui/select-session` regression in a future opencode release | Spike captured the behavior in 1.15.6; pin or document the version dependency in `lib/aiur/opencode/protocol.ex` |
| Replay storms from N writers against one serve | PR #83 already mitigated SQLite contention. If U3's parallel ensures still wedge, throttle fan-out per slot via a small Task.Supervisor concurrency cap. |
| `last_attached_pane_id` going stale (pane died, user closed it) | Already handled by existing `:slot_session_changed nil` watcher; the new `:slot_visible_changed nil` extends the same path. |
| Renderer width drift (4-state emoji rendering as 1 or 2 cols depending on font) | Reserve `@state_cell_width = 3` and pad consistently; verified against monospaced renderer test. |
| Modifying input.ex to enable modifyOtherKeys could break terminals that don't grok it | Idempotent enable + restore; skip when `skip_raw_mode` is set in tests. |
| Test seam erosion from rewriting AttachPool | Keep public API minimal; add a `snapshot/0` for test access. |

---

## Documentation / Operational Notes

- Help overlay (the `?` keybind) updated to show:
  - 4-state legend (⏳/🔘/⚪/🟢)
  - New keybinds (Enter, Shift+Enter or O, Option+Tab)
  - The 🖥️ row meaning
- `scripts/aiur --warmth-report` flag documented in `--help`.
- `opencode.warm_status_row` config documented in `Aiur.Config` module docstring.

---

## Sources & References

- Origin issue: [#85](https://github.com/aiur-team/aiur/issues/85)
- Related issue: [#84](https://github.com/aiur-team/aiur/issues/84) — done-agent restart (out of scope here)
- Recent PR: #83 (replay transaction batching) — already on main
- Prior work: PR #65 (slot/opencode-as-pane work)
- Spike notes captured in #85's "Spike already done" section
