---
title: fix: Chat pane live layout reconciliation
type: fix
status: active
date: 2026-05-22
origin: https://github.com/its-everdred/aiur/issues/64
---

# fix: Chat pane live layout reconciliation

## Problem Frame

Issue #64 reports that opening a chat pane after another pane has been closed can still lay out the new pane as though the closed pane were visible. The current layout builder is deterministic, but `PaneManager` can feed it stale slot occupancy when tmux panes disappear outside the explicit `close_conversation/2` path.

## Scope Boundaries

- Fix visible chat-pane layout and slot release on open/close reconciliation.
- Keep the existing `Aiur.PaneManager.Layout` grid model.
- Do not redesign AttachPool, SlotSupervisor, or the pre-warm lifecycle beyond the slot-ready signal needed when a slot is deselected.

## Implementation Units

### U1. Reconcile PaneManager with live tmux panes

Files:
- `elixir/lib/aiur/tmux.ex`
- `elixir/lib/aiur/pane_manager.ex`
- `elixir/lib/aiur/opencode/slot.ex`
- `elixir/test/aiur/tmux_test.exs`
- `elixir/test/aiur/pane_manager_test.exs`

Approach:
- Add a structured `Tmux.list_panes/2` helper for `list-panes -t <window> -F "#{pane_id}"`.
- Before chat-pane opens, compare PaneManager's tracked visible pane ids and placeholders with `list-panes` for `state.window_target`.
- Drop stale pane and placeholder entries, clear their slot occupancy, broadcast pane closure where applicable, and call `Slot.deselect/1` for stale opencode slot panes so the slot can be reused.
- Make `Slot.deselect/1` emit `{:slot_ready, slot_index}` when it transitions from active to ready, so pending opens and AttachPool can react.

Test Scenarios:
- Tmux helper emits the expected command and parses pane ids.
- A stale placeholder missing from live `list-panes` is removed before the next placeholder open chooses its visual slot.
- A stale middle slot is reused visually by the next placeholder open instead of forcing the new pane into the lower split.

### U2. Keep placeholder and warm opens on the balanced layout path

Files:
- `elixir/lib/aiur/pane_manager.ex`
- `elixir/test/aiur/pane_manager_live_test.exs`

Approach:
- Assign placeholders to the first currently-free visual slot and include them in `slot_panes_list/1` so `apply_layout/1` can size them immediately after `split-window`.
- Keep warm opens using the slot index from AttachPool/SlotSupervisor, but run them after live reconciliation so stale visible panes do not distort the layout.
- Add a live tmux regression for external close then open, asserting geometry through `list-panes -F`.

Test Scenarios:
- Open pane 1, kill it externally, open pane 2, and assert pane 2 receives pane 1's prior chat-area geometry.
- Existing multi-pane layout tests continue to pass.

## Verification

- `mix test test/aiur/tmux_test.exs test/aiur/pane_manager_test.exs test/aiur/pane_manager_live_test.exs`
- `mix test`
- `mix compile --warnings-as-errors`
- Lint/format with the repository's existing Mix tasks.
- Manual CLI verification before opening the draft PR: run `scripts/aiur`, open/close chat panes, and inspect `tmux list-panes -F` geometry for the close-then-open cycle.
