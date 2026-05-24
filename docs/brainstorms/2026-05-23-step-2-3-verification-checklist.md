# Manual verification checklist — steps 2 & 3

**Branch**: `prewarm-simplification`
**Commits to verify**: `537ea19`, `f503db6`, `85268f4`, `3618a78`, `6a7e42f`
**Why this is a doc, not done**: the parent Claude session's bash subprocess wedged on a long-running aiur background process. Even subagent shells inherit the corrupted state. Manual verification needs a fresh terminal.

## Reset & launch

```bash
# Kill any stale aiur leftovers
pkill -9 -f beam.smp; pkill -9 -f opencode
tmux -L aiur-orangekid kill-server 2>/dev/null

# Clear old logs
rm -f ~/github/aiur/elixir/log/aiur*.log

# Launch (this attaches your terminal to the agent list)
cd ~/github/aiur && scripts/aiur --debug --clear
```

## Test 1 — Boot wall-clock (target <20s, observed 12s)

Watch the agent list during boot.

| Expected | What it means |
|---|---|
| 3 ⚪ markers appear within ~12s | `pre_warmed_sessions=3` honored, leadoffs painted |
| 3 of the 6 active agents show ⏳ persistently | Unpaired-attach loop is gone; they only flip when a slot frees |
| Bottom debug row: `⬜ ⬜ ⬜` (3 glyphs) | Slots ready, new "leadoff-attached = fully warmed" semantics |

Failure modes:
- All ⏳ for >25s → fan-out still happening somewhere we missed
- Bottom row stuck `🔲 🔲 🔲` → `slot_fully_warmed` not firing for the new criterion
- 6 glyphs on bottom row → `pre_warmed_sessions` setting not read

## Test 2 — Warm open <100ms (Enter on ⚪)

With cursor on a ⚪ agent, press **Enter**.

| Expected | What it means |
|---|---|
| Chat pane appears instantly (visually <100ms) | `SlotRegistry.find_visible` fast path fires |
| Marker flips ⚪ → 🟢 | `pane_opened` broadcast works |
| Opencode UI is immediately interactive | No respawn or cold-start in the way |

In another terminal, verify the path taken:
```bash
grep -E "warm_open_registry_hit|attach_pool_consume_hit|placeholder_spawn_start" ~/github/aiur/elixir/log/aiur.log | tail -5
```
Want to see `warm_open_registry_hit` (the lock-free path from commit `e48c383`).

## Test 3 — Cold open on ⏳ (Enter on unpainted)

Cursor on a ⏳ agent, press **Enter**.

| Expected | What it means |
|---|---|
| Placeholder pane appears immediately (<200ms) | `open_with_placeholder` fired |
| Real opencode UI swaps in within ~10s | `async_drive_attach` eventually wires up |
| Marker eventually flips ⏳ → 🟢 | Placeholder swap works |

Verify in logs:
```bash
grep -E "placeholder_spawn|placeholder_visible|async_drive_attach_done" ~/github/aiur/elixir/log/aiur.log | tail -10
```

## Test 4 — Pause/resume red-flash diagnosis (critical)

The user-reported regression: 5 active 1 paused, Enter on a ⚫ queued agent → red flash even though there's a free slot.

Steps:
1. With 6 active agents, navigate to one and press **Space** to pause it.
2. Cursor on a ⚫ queued agent, press **Space** (start it).
3. If you see a red flash on the max chip, check the log immediately:
   ```bash
   grep "user-action.*resume_failed" ~/github/aiur/elixir/log/aiur.log | tail -3
   ```

This will print one of:
- `reason=:max_concurrent_agents_reached` → real capacity bug, need to fix `available_slots`
- `reason=:not_resumable` → `dispatch_candidate?` returning false; check `state_slots_available?` or `worker_slots_available?`
- `reason=:dispatch_failed` → `claimed` set didn't get the issue
- `reason=:no_running_agent` → the queued issue isn't in `last_polled_issues` (polling timing)
- (no entry) → the flash isn't from a resume_agent failure — investigate other event sources

The diagnostic was committed (`537ea19`) precisely so we don't have to guess.

## What to paste back to me

- Boot wall-clock (seconds from launch to all 3 ⚪)
- Whether warm open felt instant
- The exact `resume_failed reason=` if red flash fired
- Anything unexpected (errors in aiur.log, marker stuck states, etc.)

I'll proceed to step 4 (AttachPool state collapse) once steps 1-3 are confirmed clean and we have a definitive answer for the red-flash cause.
