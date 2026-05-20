---
date: 2026-05-19
status: requirements
related:
  - issue: its-everdred/aiur#34
  - pr: its-everdred/aiur#51
---

# Conversation Pane Layout Redux — Requirements

## Problem

Issue #34 was supposed to make conversation panes follow a deterministic slot cycle around the anchored agent-list pane. PR #51 generalised the slot table to a configurable `max_vertical_panes` and added unit tests against a mocked `Aiur.Tmux`. The unit tests pass. The live behaviour is unchanged: every new conversation pane appears appended to the right of the rightmost pane, in a single equal-width row.

Two prior attempts (the original PaneManager landing in old-symphony PR #44 and PR #51 here) shipped with green unit tests and the same regression. Both attempts tried to fix the bug at the Elixir layer. Neither attempt fixed it.

## Root cause

`scripts/aiur.tmux.conf:31-32`:

```text
set-hook -g after-split-window 'select-layout even-horizontal'
```

After every `tmux split-window` — including all of `Aiur.PaneManager`'s carefully-targeted slot splits — tmux fires the hook and forces every pane in the window into a single equal-width row via `select-layout even-horizontal`. The slot recipes execute correctly at the tmux command level; the hook immediately undoes their layout effect.

This hook was likely added when the original implementation just split off the rightmost pane and the operator wanted balanced widths. The hook became actively wrong once PaneManager's anchored-split logic landed. Nothing in the unit test layer can detect this, because the mock tmux does not run the hook.

## Why prior attempts failed in the same way

- Tests assert command strings emitted to a mocked tmux. They cannot observe tmux's actual layout response.
- The hook lives in shell config, outside the Elixir layer. Every fix attempt that stayed inside Elixir was bypassing the real failure point.
- No live-tmux smoke test ever existed. Every regression shipped green.

## In scope

1. Deterministic pane layout that does not depend on tmux's default `after-split-window` behaviour.
2. A live-tmux integration test that opens N conversations through `Aiur.PaneManager` against a real tmux server on a dedicated socket and asserts pane geometry via `tmux list-panes -F`. This is the missing layer that let every prior attempt regress with green unit tests.
3. Delete `Aiur.Tmux.spawn_pane_for/3` and its `{:spawn_pane, ...}` handle_call (`elixir/lib/aiur/tmux.ex:49`, 114). No production callers; legacy `:.{right}` split path. Removing it prevents accidental reintroduction.
4. Replace the `System.get_env("TMUX_PANE")` fallback in `Aiur.PaneManager.init/1` (`elixir/lib/aiur/pane_manager.ex:78`) with an explicit `tmux display-message -p '#{pane_id}'` query through `Aiur.Tmux`. Log at `:warning` and refuse to start if the query fails — silent `nil` was a hidden failure mode in the prior bug landscape.

## Out of scope

- Renaming or restructuring `max_vertical_panes` config — PR #51's plumbing stays.
- Reworking `Aiur.Conversations` / `AgentList.App` / `Aiur.Application` wiring. The bug is downstream of those.
- Mouse/keyboard focus behaviour on slot reuse (existing `select-pane` after split is preserved).
- The `Aiur.PaneWarmPool` scaffold (unrelated, already a no-op).

## Target behaviour

### Layout model

`Aiur.PaneManager` owns a target layout per `(slot_count, slot_occupancy)` state. After every state change that affects layout (open, close, respawn-on-cycle), it computes the target layout string and applies it via `tmux select-layout <string>`. The slot-anchor split chain remains the mechanism for *creating* new panes; the layout string is the mechanism for *positioning* them.

Concretely, for `max_vertical_panes: 3` with all 5 slots occupied:

```text
+-----------+-----------+-----------+
| AgentList |  slot 1   |  slot 2   |
| (anchor)  | (top mid) | (top R)   |
+-----------+-----------+-----------+
|  slot 3   |  slot 4   |  slot 5   |
| (bot L)   | (bot mid) | (bot R)   |
+-----------+-----------+-----------+
```

For `max_vertical_panes: 4` with all 7 slots occupied: 2 rows × 4 columns, agent list in row-0 col-0, conversation slots in the remaining 7 cells in left-to-right, top-then-bottom order.

When fewer slots are occupied, gaps collapse and remaining panes proportionally expand within their row. Specifically: only occupied columns appear in each row; row heights stay 50/50 when both rows have any pane; the row with no panes collapses to zero (the other row takes the full height). The agent-list column is always present.

### Hook removal

`set-hook -g after-split-window 'select-layout even-horizontal'` is removed from `scripts/aiur.tmux.conf`. No replacement hook is added. PaneManager is the sole authority on conversation pane layout.

### Operator-visible behaviour preserved from issue #34

| Ticket # opened | Layout outcome |
|---|---|
| 1st | Agent list + slot 1 side-by-side, agent list ~33%, slot 1 ~67% |
| 2nd | Agent list ~33%, slot 1 ~33%, slot 2 ~33% — all in top row |
| 3rd | Top row 2 panes (agent list, slot 1), bottom row 1 pane (slot 3) under agent list? See open question below |
| 4th–5th | Build out to full 2×3 grid |
| 6th | Replace slot 1 in place via `respawn-pane`; pane id preserved |
| 7th+ | Round-robin replacement |

### Closed-slot recovery

Closing a slot's pane (Ctrl+C inside it) clears that slot's occupancy and triggers a layout reapply. The next open in cycle order reuses the closed slot (recreates the pane via the split recipe) or skips past it according to the existing `cycle_index` semantics. **Cycle pointer behaviour is unchanged from current code.**

### Window resize

The `aiur.tmux.conf` already has `mouse on` and a `geometry_tick` in `AgentList.App` that re-renders the agent list on size change. The layout string is in tmux's "percentage" form (or equivalent), so a window resize naturally redistributes space without needing PaneManager to reapply.

## Open product question (resolve during planning)

When fewer slots are occupied, should empty slots:

- **(a)** collapse entirely, letting siblings expand to fill the row, OR
- **(b)** remain as empty placeholder panes (e.g. a single-line "press Enter to assign" pane)?

Issue #34's "Closing a pane leaves the slot empty; tmux auto-expands neighbors" sentence implies (a). Confirm before the plan locks it in.

## Acceptance criteria

- [ ] `set-hook -g after-split-window` line is removed from `scripts/aiur.tmux.conf`.
- [ ] With `max_vertical_panes: 3`, opening 5 conversations through `Aiur.PaneManager.open_conversation/3` produces a 2×3 grid via `tmux list-panes -F '#{pane_id} #{pane_left},#{pane_top} #{pane_width}x#{pane_height}'`, with agent list at `0,0` spanning row 0 column 0.
- [ ] With `max_vertical_panes: 4`, the same flow produces 2 rows × 4 columns, 7 conversation slots.
- [ ] After all slots are filled, the 6th open reuses slot 1's tmux pane id (verified by capturing pane ids before and after).
- [ ] Closing a slot and then opening another conversation follows the existing cycle pointer (not "fill the gap first").
- [ ] A new integration test under `elixir/test/integration/` (or equivalent) spins up tmux on a temporary socket, runs the above sequence end-to-end, and asserts geometry. Test must be skippable when `tmux` is not on `$PATH` (so CI without tmux still passes) but must run by default when tmux ≥ 3.3 is available.
- [ ] `Aiur.Tmux.spawn_pane_for/3` and its `{:spawn_pane, ...}` handle_call are deleted; no production code references the symbol.
- [ ] `Aiur.PaneManager.init/1` resolves `agent_list_pane` via `tmux display-message -p '#{pane_id}'`. If the query returns no pane id, init logs a `:warning` and refuses to start (returns `{:stop, :no_agent_list_pane}`).
- [ ] Existing `Aiur.PaneManagerTest` and `Aiur.CoreTest` unit tests still pass without modification.
- [ ] `mix format --check-formatted`, `mix lint`, `mix specs.check`, and `make -C elixir all` are green on the change.

## Risks

- **Layout-string format and checksum**: tmux window layout strings carry a 4-char CRC prefix. We will use the `select-layout <string>` form where tmux re-checksums for us, but if we want to compute and store target strings, we need a CRC implementation. Confirm during planning whether we apply via `select-layout <named-or-string>` or programmatically build the string.
- **Tmux version drift**: tmux 3.5 deprecated `split-window -p N%` in favour of `-l N%`. The current code uses `-p N`; tmux 3.5a still accepts it. If the project targets tmux ≥ 3.5 going forward, plan should consider migrating to `-l N%`.
- **Integration test fragility on CI**: tests that spawn real tmux processes need a tmux installation in CI and a way to clean up sockets on failure. The `aiur` script's existing socket-per-instance pattern is a good template.

## Dependencies and assumptions

- tmux ≥ 3.3 on developer machines (already required by the `aiur` script).
- `Aiur.Tmux` GenServer is up before `Aiur.PaneManager.init/1` runs (already true in the supervision tree).
- The first tmux pane in the aiur session is always the agent-list pane (true today because `aiur` starts the session with one pane running the BEAM, and that pane runs the agent-list TUI).

## References

- `elixir/lib/aiur/pane_manager.ex`
- `elixir/lib/aiur/tmux.ex`
- `scripts/aiur.tmux.conf`
- `elixir/test/aiur/pane_manager_test.exs`
- Issue: https://github.com/its-everdred/aiur/issues/34
- Prior PR: https://github.com/its-everdred/aiur/pull/51
