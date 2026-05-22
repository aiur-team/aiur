# Instant pane paint — U0-U9 verification

**Date:** 2026-05-21
**Branch:** `aiur/60-opencode-pane-chat`
**Summary:** Redesigned the chat-pane-open hot path to meet the user's non-negotiable bar — "open the new pane instantly even if opencode isn't ready". Eliminated pre-warm waste, parallelized slot pre-warm, and added an instant placeholder pane that swaps to the real attach in the background.

## Numbers

| Metric | Baseline (pre-U0) | After U0-U5 | Speedup |
|--------|-------------------|--------------|---------|
| Enter → visible pane (cold or warm) | **9 s** | **120 ms** (placeholder) | **~75x** |
| Enter → real convo rendered | **20 s** | **~1 s** warm / **~10 s** cold | 2–20x |
| `pane_open_visible` `wall_ms` | **7841** | **1082** (warm) | 7x |
| Slot pre-warm chain wall time | **38.4 s** | **15.6 s** | **2.5x** |
| `identifier_miss` rebuilds on first open | **YES** (~6 s each) | **NO** | eliminated |
| Agent list sort order | string (`10, 11, 5, 9`) | numeric (`5, 9, 10, 11`) | fixed |
| `--debug` footer in agent list | none | live perf milestones | new |

## What changed

| Unit | Commit | Subject |
|------|--------|---------|
| U0 | `4427ee9` | Always-on `aiur_perf` structured logs |
| U1 | `e4d1434` | Parallel slot pre-warm (all 5 slots concurrent) |
| U2 | `61a15ae` | Pre-seed slot models map from orchestrator |
| U3 | `213214f` | Instant placeholder pane on Enter |
| U4 | `519c5b9` | Agent list sort numerically + time-to-paint test |
| U5 | `eafbddc` | `--debug` agent list footer with live milestones |

## How to measure yourself

Every run writes structured `aiur_perf` lines to `elixir/log/aiur.log` regardless of `--debug`. After any change to the pane-open hot path or slot lifecycle, run `scripts/aiur`, open at least one chat, then:

```bash
# Time from Enter to placeholder visible:
grep "aiur_perf phase=placeholder_spawn_done" elixir/log/aiur.log | tail -1
# -> look for wall_ms=NNN

# Time from Enter to real pane swap complete:
grep "aiur_perf phase=pane_open_complete" elixir/log/aiur.log | tail -1

# Full slot pre-warm chain timing:
grep -E "aiur_perf phase=slot_chain_(parallel_start|complete)" elixir/log/aiur.log

# Identifier_miss rebuilds (should be EMPTY in healthy runs):
grep "aiur_perf phase=slot_identifier_miss" elixir/log/aiur.log
```

## Regression coverage

- `time_to_paint_test.exs` — source guard on `open_opencode_pane` + placeholder swap handler. `perf_regression` tag asserts last `placeholder_spawn_done` ≤ 500 ms.
- `preseed_models_test.exs` — source guard that `handle_continue(:start_serve)` reads from orchestrator + tolerates unavailability.
- `parallel_pre_warm_test.exs` — source guard that `SlotPolicy.handle_info(:start_first_slot)` iterates `1..target` and `slot_ready` handler does NOT start the next slot.
- `agent_list_sort_test.exs` — drives the live `App` GenServer and asserts numeric-ascending order within each emoji bucket.
- `chat_open_perf_test.exs` (existing) — asserts last `open_visible open_ms` ≤ 12_000 ms.

## Architecture changes

### Instant placeholder pane (U3)

```
Enter
  └─> PaneManager.handle_call({:open, ...})
       ├─> spawn_placeholder_pane → tmux split-window in window 0       [120 ms]
       │    └─> reply {:ok, placeholder_pane_id} immediately
       └─> Task.start(drive_real_attach)
            ├─> acquire_slot (waits if needed)
            ├─> Slot.select → respawn_attach_with_session
            └─> send PaneManager :placeholder_swap
                 └─> handle_info({:placeholder_swap, ...})
                      ├─> tmux swap-pane (atomic — preserves layout)    [~300 ms]
                      ├─> tmux kill-pane (placeholder)
                      └─> broadcast :pane_opened
```

The user sees a "Loading opencode for issue-X..." pane within 120 ms. The real attach swaps in seamlessly when ready.

### Pre-seeded models map (U2)

Slot's `handle_continue(:start_serve)` now polls `Orchestrator.list_active_identifiers/0` for up to 3 s before materializing `opencode.json`. The serve boots with every active agent's identifier in its provider map, so the first `Slot.select` for any active agent hits the warm path instead of triggering a full `identifier_miss` rebuild (~6 s saved).

### Parallel pre-warm (U1)

`SlotPolicy.handle_info(:start_first_slot, ...)` iterates `1..target_count` and spawns every slot up-front. The `slot_ready` handler no longer kicks off the next slot. All 5 slots warm concurrently in ~16 s wall time instead of ~38 s sequential.

### Always-on perf logging (U0)

`Aiur.Perf.event/2` and `Aiur.Perf.span_begin/2` / `span_end/2` emit structured `aiur_perf phase=...` lines for every event in the hot path. Always on (not gated on `--debug`) so before/after comparisons survive subprocess restarts.

### Debug footer (U5)

`Aiur.Perf` broadcasts every event on PubSub topic `aiur:perf`. When `--debug` is set, the agent list subscribes and renders a rolling 12-event footer with elapsed time and `wall_ms`.

## Out of scope (intentional non-goals)

- Eliminating the 6–13 s `opencode-serve` cold start. That's bounded by Node.js startup + WebSocket handshake; not something we control.
- Hot-reloading `opencode.json`. opencode 1.15.6 doesn't support it, so we'd need to fork opencode itself.
- The 1–2 s post-swap convo render. opencode-attach has to read SQLite rows + render; it's the TUI's wall time.
