---
title: opencode-attach dies a few seconds after /tui/select-session
type: brainstorm
status: open
date: 2026-05-22
---

# opencode-attach dies a few seconds after `/tui/select-session`

## Problem (one sentence)

The fast-path in-place session swap (`POST /tui/select-session` against an already-rendered opencode-attach) appears to work — pane content updates to the new conversation — and then 1.5–25 s later opencode-attach silently exits, tmux destroys the pane, our poll detects it gone, and PaneManager applies a single-pane layout. User sees the new pane "flash for a moment then close, agent list + pane 1 end up taking up 50-50."

## What we actually know (vs guess)

From the user's run (21:50:46.797 swap → 21:50:50.431 death detected):

| Timestamp | Evidence | Meaning |
|---|---|---|
| 46.808 | `opencode_http POST /tui/select-session status=200` | API call succeeded |
| 46.809 | `slot_select_via_api_done wall_ms=11` | Internal swap path complete |
| 46.829 | `move-pane -s %3 -t default:0 -h` → `ok []` | tmux didn't error (pane was visible already; move-pane silently no-op'd) |
| 46.847 | `aiur_tmux_layout slot_panes=1=>%3 …{62x29,0,0,0,61x29,63,0,3}` | Layout applied, 2 panes |
| 47.833 | `capture-pane -p -t %3` returns clean issue-16 conversation + opencode footer | opencode-attach is rendering normally |
| 48.347, 48.862 | `display-message -p -t %3` returns `["%3"]` | pane alive |
| 49.387, 49.906, 50.418 | `display-message` returns `[]` (3 polls 519 ms apart) | pane gone for tmux too |
| 50.431 | `pane_died capture_at_death=capture_failed` | even capture-pane can't find it |
| 50.461 | `aiur_tmux_layout slot_panes=1=>_ … ccfd,124x29,0,0,0` | single-pane layout |

Death window: between 48.862 and 49.387 — **525 ms**. In that window the log shows **only** display-message polls. No Aiur tmux operation. No PubSub broadcast we trigger. No HTTP traffic to opencode-serve. opencode-attach simply exits.

Opencode-serve process for slot 1 (PID 2821893) did NOT restart; there's no second `opencode_server phase=ready` for slot 1. **The serve is alive; only opencode-attach died.**

## What we don't know

- **Exit reason / signal**. tmux destroys the pane when the process inside exits, but we have no way to see the exit code or stderr because: (a) Aiur.Tmux does NOT use control mode, so `subscribe_events` returns no events (the docstring spells this out); (b) opencode-attach's stderr goes to the tmux pane buffer, which we capture but only the rendered TUI, not raw stderr.
- **Whether `/tui/select-session` is the trigger**, or whether something else (SIGWINCH from `move-pane`, opencode-serve internal state, a load-related race) is.
- **What's different between the user's env (dies in 3 s) and mine (alive past 30 s, 5 rapid swaps)**. Same code, same workflow file, same agents. Hardware, opencode version, tmux version, latent processes, or something in their codex/agent stream that mine doesn't have.

## Hypotheses worth testing

**H1 — `/tui/select-session` semantics.** opencode 1.15.6's attach process treats the message as "host is reassigning me to a different session, close the WebSocket and exit". Spike in #85 only tested swapping between two near-empty sessions; real conversations with running tool calls (`sleep 300`) may hit a different code path.

**H2 — race with SIGWINCH from `move-pane`.** tmux's `move-pane` (even when no-op'd as `source==target`) emits a SIGWINCH to the pane's process. If the SIGWINCH lands in the same scheduling slice as the just-arrived /tui/select-session HTTP response, the TUI's resize-handler may interact badly with the session-load handler.

**H3 — opencode-serve issues an event the attach can't handle.** When session changes server-side, the serve broadcasts events on its WS. If the new session is mid-tool-call (`sleep 300`), the event stream during the swap may include partial / out-of-order events the attach UI panics on.

**H4 — Process exhaustion / Bun runtime issue.** opencode-attach is a Bun process. Bun has its own GC and scheduling. The user has been running aiur for an extended session with many slot bounces; the host may have lingering opencode processes that compete for resources. Mine is a fresh boot.

**H5 — Concurrent slot bring-up triggers the death.** In the user's death window, slot 3's bring-up is in progress (started at 46.862, mid-`opencode-serve` startup). Maybe simultaneous CPU/IO pressure during slot 3 boot starves slot 1's attach.

## Investigation paths (no implementation yet)

| Path | Effort | Signal value |
|---|---|---|
| Enable `tmux pipe-pane` per chat pane in `--debug` mode | Low | High — captures opencode-attach's stderr+stdout. We'd see crash output if any. |
| Add control-mode tmux connection | Medium | High — `%pane-died` carries exit reason; %window-pane-changed correlates SIGWINCH timing |
| Capture opencode-serve stderr inside the death window | Low | Medium — confirms whether serve is sending anything bad to attach |
| Replicate **without** Aiur (raw `opencode serve` + `opencode attach` + `curl /tui/select-session`) | Medium | Highest — isolates upstream bug from our orchestration |
| `opencode --version` on user's machine + mine | Trivial | Confirms version parity |
| Strace one opencode-attach process during a swap | Medium | High — exact signal/syscall that kills it |

## Design alternative (the user's framing)

> "aren't we just adding an additional pane pre-warming code in that new hidden pane and then just displaying it when the user presses enter?"

Yes — that's the original PR #65 warm-attach model: **one opencode-attach pane per active agent**, each spawned with `--session <agent's session>`, all sitting in `aiur-hidden` painted and ready.

| | Current design (#85, with `/tui/select-session`) | One-pane-per-agent |
|---|---|---|
| opencode-serve processes | M (one per slot, default 5) | M still (slot supplies serve; sessions are per-serve) — OR collapse to 1 |
| opencode-attach processes | M (one per slot's leadoff) + ephemeral respawns | N (one per active agent) |
| Memory @ 5 active agents | ~5 attaches × 50–100 MB ≈ 350 MB | same 5 attaches ≈ 350 MB |
| Open agent in new pane | Move slot-N's pane visible (warm-fast if N has the agent attached) | Move agent-X's pane visible (always warm-fast, no slot lookup) |
| Open agent in same pane (swap) | `POST /tui/select-session` (fast IF it works; **kills attach in user's env**) | Move current visible pane back to hidden, move target pane to that slot (no API call, always reliable) |
| New agent activated | Each slot starts a SessionWriter for it; eventual attach via Slot.attach (no pane spawned) | Spawn a new `opencode attach --session <id>` in aiur-hidden, wait for paint |
| Done agent | Slot.detach broadcast → AttachPool drops → pane closes if visible | kill the agent's hidden pane + close visible if showing it |
| `/tui/select-session` usage | Required for in-place swap | Never called |

The cost we pay in the alternative: spawning more `opencode-attach` processes upfront (still bounded by active-agent count, typically ≤ 10). The benefit: no /tui/select-session = no opencode-attach death after swap.

The "slot" concept can stay — it's still useful for serve-per-slot isolation and the visible grid mapping — but agents and panes become 1:1 instead of N:1 within a slot.

## Open questions for the user

1. Should we add `tmux pipe-pane` capture in `--debug` mode FIRST so the next repro tells us the exit reason? (~30 min of work) Without it we're hypothesis-spinning.
2. Are you OK paying the resource cost (~50–100 MB per active agent) for the one-pane-per-agent redesign IF the investigation shows /tui/select-session is genuinely unfixable in 1.15.6?
3. If we keep the swap path AND can't fix the death, is "always respawn (slow but stable)" an acceptable fallback for in-place swap? (~5–7 s per Enter, same as initial cold open)

## Recommended next step

Add the `pipe-pane` stderr capture (path 1 from the investigation table). It's the smallest change that gives us the most signal — we get to see what opencode-attach prints in the seconds before it dies. If it prints nothing (silent exit), we know we need control mode for exit-reason. If it prints a crash message, we have the smoking gun.

After that single round-trip of investigation we'll know whether to fix `/tui/select-session` usage or pivot to the one-pane-per-agent design.
