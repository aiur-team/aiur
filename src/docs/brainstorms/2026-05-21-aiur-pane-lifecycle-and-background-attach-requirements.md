---
title: Aiur pane lifecycle, background attach, and autonomous agent loop
created: 2026-05-21
status: ready_for_planning
origin: docs/brainstorms/2026-05-20-opencode-prewarm-and-history-injection-requirements.md
related:
  - elixir/lib/aiur/pane_manager.ex
  - elixir/lib/aiur/opencode/warm_server.ex
  - elixir/lib/aiur/opencode/warm_attach.ex
  - elixir/lib/aiur/opencode/session_writer.ex
  - elixir/lib/aiur/opencode/session_writer_registry.ex
  - elixir/lib/aiur/shutdown.ex
  - elixir/lib/aiur/orchestrator.ex
  - scripts/aiur
---

# Aiur pane lifecycle, background attach, and autonomous agent loop

## Problem frame

The opencode pre-warm work (yesterday's brainstorm + plan) shipped, but the user's first interactive run surfaced six behavioral defects that block the feature from being useful:

1. Closing a chat pane should **hide**, not destroy — reopening must be near-instant and preserve the same opencode session.
2. Prefilled history (codex turns + agent self-talk) is **not visible** in the opencode pane on first open; the user sees an empty chat (or a single user-style blue bubble).
3. Agents no longer **act on their own** — they only respond when the user types. The autonomous codex-turn loop that drove agents through their assigned IssueLog work is gone or unreachable through the opencode pane.
4. The current pre-warm only covers the **first** pane; subsequent panes fall back to a cold attach. The user wants every agent's chat to be pre-attached in a hidden window, with the user-selected one prioritized.
5. On quit (especially abrupt quit, e.g. Ctrl+C, terminal-close, parent-bash exit), **opencode sessions are not reaped**, leaving orphans in `~/.local/share/opencode/opencode.db` and `opencode session list`.
6. The placeholder titles `_warm` and `_placeholder` **leak into the visible TUI's input bar** ("Build Aiur _warm", "_placeholder 3 sessions") when a pane is shown before the agent's real session takeover completes.

These compound: (1) and (4) together describe the desired pane lifecycle (every agent has one persistent, pre-attached pane; user open/close is just swapping into and out of the visible window). (2) and (3) together describe what users see when they look at a pane (the agent's real autonomous transcript, live, with full back-history rendered as agent messages). (5) and (6) are the housekeeping that keeps the system honest — no orphans, no internal labels bleeding through.

## Actors

- **A1: developer** running `scripts/aiur --interactive` in a terminal to oversee multiple parallel codex agents from a single tmux session.
- **A2: codex agent** (the per-issue worker) — works autonomously on its assigned IssueLog work, surfaces transcript to the user via opencode.
- **A3: opencode TUI / server** — third-party chat UI that Aiur embeds. Aiur owns its sessions, its SQLite, and its hidden tmux windows.

## Requirements

### R1: Closing a pane preserves the session

- **R1.1**: When the user presses the close key on a visible chat pane, the tmux pane MUST NOT be killed. The tmux pane MUST be moved (via `tmux join-pane -d` or equivalent move semantics) back to the hidden warm window so it stays running with the same opencode-attach PID, same opencode session ID, and same SessionWriter.
- **R1.2**: Reopening the same agent's chat MUST move that pane back into the visible window without any new opencode-attach spawn, new session creation, or DB writes. The latency target is the time tmux takes to move a pane (<50 ms typical).
- **R1.3**: The opencode session associated with that pane MUST survive any number of open/close cycles for the lifetime of the aiur run. The session is only deleted on aiur shutdown (see R5).

### R2: First-open shows full prior history as agent transcript

- **R2.1**: When a user opens an agent chat for the first time in this aiur run, the opencode pane MUST render the agent's prior IssueLog history (codex turn outputs, tool calls, agent self-talk) **before** the TUI displays the session. The user MUST NOT see an empty chat or a single user-style bubble.
- **R2.2**: Every replayed history entry MUST render as an **assistant** message in the opencode TUI (`role: "assistant"`), not as a user message. The user should perceive that they are catching up on a transcript the agent has been generating.
- **R2.3**: After history rows are committed to opencode's SQLite, Aiur MUST ensure the TUI re-reads the session (via a `/tui/select-session` round-trip OR a synthetic nudge after `select-session` has already been issued — whichever proves reliable in opencode 1.15.6). An empty pane that "fills in" 1–2 seconds late is a failure mode, not an acceptable degradation.

### R3: Agents run continuously, opencode is a viewer

- **R3.1**: Whenever an agent is assigned an open issue from the IssueLog, that agent's codex turn loop MUST run autonomously without waiting for user input in the opencode pane. The agent advances its work the same way it did before the opencode pane existed.
- **R3.2**: The SessionWriter for each agent MUST mirror live codex turn output into the opencode SQLite as it happens, so the user sees the transcript scroll live in the pane.
- **R3.3**: User-typed messages in the opencode pane are **interjections**, not the trigger for work. Routing user messages back into the codex agent as additional context is in scope (the bridge already does this) but the agent's progress MUST NOT depend on a user message arriving.
- **R3.4**: When an agent has no assigned issue, it sits quiet — no synthetic self-prompts, no "anything to do?" loops.

### R4: Every agent's pane is background-pre-attached, user selection jumps the queue

A precise four-step state machine, in the order the user described:

- **R4.1**: At `aiur --interactive` boot, the agent-list view and a background opencode warm process begin loading in parallel. The agent-list view appears as soon as it is ready, independent of opencode's status.
- **R4.2**: If the user selects an agent chat **before** opencode finishes its initial boot: Aiur MUST finish opencode boot, attach the **selected** agent's pane first, fully render it in the visible window, and only then begin background-attaching the remaining agents in agent-list order.
- **R4.3**: If opencode finishes its initial boot **before** the user selects any chat: Aiur MUST begin background-attaching agents in agent-list order, into the hidden warm window, one at a time (or with bounded concurrency — see open question Q1).
- **R4.4**: If the user selects an agent chat **during** background-attach: the queue MUST yield. If the selected agent's attach is currently in flight, its pane MUST be moved to the visible window immediately and finish rendering there (the user sees the final stages of load, not a separate loading screen). If the selected agent has not started attaching yet, the in-flight background attach completes, the selected attach jumps to the front, and the rest resume after the selected one is visible and rendered.
- **R4.5**: Across all R4 paths, attaching a pane means: create the opencode session, spawn an opencode-attach in the hidden warm window, select the session, replay history, and confirm the TUI is showing the agent's transcript. Once that completes, the pane is "ready."

### R5: All Aiur-owned opencode sessions are reaped on quit, including abrupt quit

- **R5.1**: Catchable signals (SIGINT from Ctrl+C, SIGTERM, SIGHUP) MUST trigger `Aiur.Shutdown.cleanup/1` before the BEAM halts. This is the path already partially covered; R5.1 is verifying it actually runs end-to-end through tmux.
- **R5.2**: `scripts/aiur` MUST install a bash `trap` on EXIT (and SIGINT/SIGTERM/SIGHUP) that runs a best-effort `opencode session delete` for every session ID Aiur recorded during this run. The bash trap is a second line of defense for cases where the BEAM dies before its handler runs (e.g. an exception during shutdown).
- **R5.3**: For uncatchable failures (SIGKILL, power loss, OOM kill), the existing boot-time GC in `Aiur.Opencode.WarmServer` MUST reap orphans on the next aiur run by enumerating Aiur-owned sessions and deleting those whose providerID matches Aiur's marker.
- **R5.4**: Reaping MUST only delete sessions Aiur created in this run or prior runs. Sessions a user created with `opencode` directly MUST NOT be touched. (Identification: providerID marker on the session, as in the current implementation.)
- **R5.5**: After a clean exit, `mise exec -- opencode session list` MUST show zero Aiur-owned sessions.

### R6: Internal session titles never appear in the visible TUI

- **R6.1**: The placeholder titles `_warm` and `_placeholder` MUST NOT be visible to the user at any point. The TUI's input bar suffix, model name area, and session title bar MUST always show the agent's real label by the time the pane enters the visible window.
- **R6.2**: When a hidden pane is promoted to visible (whether from cold attach, warm hand-off, or background-attach), the underlying opencode session MUST have been renamed via `/session/<id>` or similar API to the agent's real title **before** the user sees it.
- **R6.3**: If the rename API is not available or fails, the fallback is to create each background-attached session with the agent's real title from the start, so there is no rename window at all.

## Acceptance examples

- **AE1 (close = hide)**: User opens agent #42, types a message, closes the pane, immediately reopens agent #42. The same conversation is visible. No new opencode session ID has been created. Round-trip <100 ms.
- **AE2 (history)**: A new agent has run 8 codex turns before the user opens its pane. When the user opens the pane, all 8 turns are visible as assistant messages, scrollable, with the latest at the bottom. The agent is still actively running.
- **AE3 (autonomy)**: User opens an agent's pane, watches it work for 30s, closes the pane without typing anything. Reopens 60s later. The pane shows 60s of additional autonomous activity.
- **AE4 (background load)**: User runs aiur, immediately selects agent #2 from the list. Agent #2 attaches first. While they watch agent #2, agents #1, #3, #4, #5 quietly background-attach. Switching to any of them is sub-100ms (no loading screen).
- **AE5 (Ctrl+C)**: User presses Ctrl+C in the aiur terminal. Aiur exits. `opencode session list` shows zero Aiur-owned sessions.
- **AE6 (no leaks)**: At no point during normal use does the user see `_warm` or `_placeholder` in any visible TUI text.

## Scope boundaries

**In scope**

- The six requirements above.
- The persistent-pane model: one opencode-attach process per agent, kept alive in a hidden tmux window.
- Bounded-concurrency background attach (single inflight is acceptable; parallel is allowed if it doesn't destabilize opencode — see Q1).
- Renaming opencode session titles via API at attach time.
- Bash trap in `scripts/aiur`.

**Deferred for later**

- Pruning resident opencode-attach processes when too many agents accumulate (assume N≤10 agents for now).
- Survival across aiur restarts (today: a fresh aiur boot starts from zero panes; sessions get reaped).
- User-configurable concurrency or pre-warm counts.
- A UI affordance to show background-attach progress.

**Outside this product's identity**

- Embedding opencode protocol changes upstream — we treat opencode 1.15.6 as a fixed black box.
- Replacing opencode with a custom TUI.

## Dependencies / assumptions

- **D1**: tmux `join-pane -d` reliably moves a running pane between windows without disrupting its PTY or PID. (Verified by yesterday's spike; we lean on the same behavior here.)
- **D2**: opencode 1.15.6 honors `POST /tui/select-session` when called against an attach already in the same hidden window. (Verified yesterday for the warm hand-off; we extend it to N panes.)
- **D3**: opencode 1.15.6 exposes a session-rename endpoint OR we can set the title at create time and never rename. (To verify in planning — Q3 below.)
- **D4**: BEAM correctly delivers SIGINT to the foreground process group when aiur is launched from a terminal. (Standard.)
- **D5**: Codex turn output already flows through bridge → SessionWriter when an agent is active. (Existing path; verify in planning the loop actually runs continuously and not only on user prompt.)

## Open questions / unverified assumptions

- **Q1**: Should background-attach happen one at a time, or with bounded parallelism (e.g. up to 3 in flight)? One-at-a-time is simplest and the safest first cut. **Deferred to planning.**
- **Q2**: How are user-typed messages routed into the autonomous codex loop today? The existing bridge handles `chat/completions`, but does the agent runner pull user messages as additional turn context, or does typing replace the next agent action? **Deferred to planning** — code read needed.
- **Q3**: Does opencode 1.15.6 expose a session-title-update endpoint? If yes, prefer rename-on-attach. If no, fall back to creating each session with the agent's real title from the start. **Deferred to planning** — quick API probe.
- **Q4**: Is `tmux join-pane -d` (move without detach) the right primitive for visible↔hidden swaps, or do we need a different combination (`break-pane`, `swap-pane`)? **Deferred to planning** — quick tmux check.

## Success criteria

The feature is done when, on a single aiur run started from a clean opencode session list, the user can:

1. Press `q` after opening 4 different agent panes, and `opencode session list` afterward shows zero Aiur-owned sessions.
2. Press Ctrl+C from inside aiur or kill the parent terminal window, and on the next aiur run, boot-time GC reports zero orphans to reap (because the bash trap already cleaned up).
3. Open agent #3 first; subsequent switches to agents #1, #2, #4 each take <100 ms with no visible loading screen.
4. Open any agent and immediately see prior codex turn history as agent-style messages, with the agent continuing to type new messages while the user watches.
5. Never see the strings `_warm` or `_placeholder` in any visible part of the TUI.
6. Close any pane and reopen it later, seeing the same conversation continue uninterrupted.

## Why this matters

Yesterday's plan delivered the *infrastructure* for opencode integration — a warm server, a writer registry, a shutdown chokepoint. This brainstorm is about making the *behavior* match a user's mental model: agents are autonomous workers running in parallel; the opencode TUI is a viewer onto each one's transcript; opening and closing a pane is a glance, not a setup. Without these six fixes, the integration is technically alive but practically unusable.
