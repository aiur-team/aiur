---
title: KA2 Claude REPL panes survive the daemon - Plan
type: feat
date: 2026-10-09
topic: keep-agents-restart
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/keep-agents-restart/brainstorm.md
base_main_sha: 9940eed44
---

# KA2 Claude REPL panes survive the daemon - Plan

## Goal Capsule

- **Objective:** `claude-repl` agent panes live on a tmux server that the
  daemon's own session does not share, and Claude hook events that arrive
  while the dashboard is down are kept, not dropped.
- **Product authority:** [brainstorm.md](brainstorm.md) (R3, R5).
- **Open blockers:** none.
- **Product Contract preservation:** unchanged.

---

## Problem Frame

The BEAM runs in a pane of the private tmux session
(`AIUR_TMUX_SESSION` on socket `AIUR_TMUX_SOCKET`), and
`Aiur.Claude.Repl.Launcher` opens REPL panes on that same server. `cmd_stop`
runs `kill-session` and `kill-server`, so every REPL agent dies with the
daemon. Claude hooks run `curl -sS -m 2` to `POST /api/v1/<id>/claude-hook`
(`Aiur.Claude.HookSettings.hook_command/2`); while the dashboard is down a
`Stop` hook is lost and the runner never sees the turn end.

## Requirements

- R3 and R5 from the brainstorm, for REPL agents.
- KA2-R1. REPL agent panes run on a dedicated agent tmux server
  (`<socket>-agents`); the daemon session and chat panes stay where they are.
- KA2-R2. Every hook event is appended to a per-agent spool file before the
  POST is attempted; the POST outcome never fails Claude.
- KA2-R3. A normal `aiur stop` and the BEAM-death watchdog still kill the
  agent server (today's behaviour).

## Key Technical Decisions

- **Separate tmux server, same conf.** `-L <socket>-agents -f <conf>`. The
  engine exports `AIUR_AGENT_TMUX_SOCKET`; `Aiur.Tmux` takes the socket per
  call, defaulting to the agent socket for agent panes. Operator attach to an
  agent pane uses the agent socket (dashboard and `aiur agents` print it).
- **Spool before POST.** Hook command becomes: append the stdin JSON as one
  line to `<runtime-state>/claude-hooks/<identifier>.ndjson`, then `curl` as
  today. The byte offset of a line is its cursor (no shared counter is needed).
  Kept in shell so Claude needs nothing new. The daemon records the byte
  offset it has processed per agent in the session handle.
- **Dedup on replay** by the `(session_id, hook_event_name, transcript
  offset or timestamp)` key, because an event can be both spooled and posted.
- **Spool rotation** when the agent's session ends; size cap 16 MiB per agent.

## Implementation Units

### U1. Agent tmux server

**Goal:** REPL panes open on the agent server; stop and watchdog still kill it.
**Requirements:** KA2-R1, KA2-R3.
**Dependencies:** none.
**Files:** `src/lib/aiur/tmux.ex`, `src/lib/aiur/claude/repl/launcher.ex`,
`src/lib/aiur/claude/repl/reaper.ex`, `src/lib/aiur/process_reaper.ex` (pane
entries carry the socket), `packaging/npm/aiur-cli/libexec/aiur-engine.sh`
(`run_session` exports the agent socket; `cmd_stop`, `reap_aiur_agents`,
`sweep_dead_tmux_sockets` include it), `src/test/aiur/tmux_test.exs`,
`src/test/aiur/claude/repl/launcher_test.exs`, `src/test/aiur_engine_test.exs`.
**Approach:** add the agent socket to the instance record so `stop` from a
fresh shell finds it. Pane ids are per server, so every pane operation passes
the socket explicitly.
**Patterns to follow:** existing `AIUR_TMUX_SOCKET` threading in the engine.
**Test scenarios:**
- REPL launch creates the pane on the agent socket; `has-session` on the
  daemon socket does not list it.
- `aiur stop` kills both servers; no pane pid survives.
- Watchdog path (BEAM killed with SIGKILL, no stop sentinel) kills the agent
  server.
- Instance record without the new field (older launcher) still stops cleanly.
**Verification:** engine and REPL suites green; manual REPL dispatch shows the
pane under `tmux -L <socket>-agents ls`.

### U2. Hook spool and replay

**Goal:** hook events survive a dashboard outage and are processed once.
**Requirements:** KA2-R2, R3.
**Dependencies:** none (parallel with U1).
**Files:** `src/lib/aiur/claude/hook_settings.ex`,
`src/lib/aiur/claude/hook_events.ex` (replay entry point, dedup),
`src/lib/aiur/session_handle.ex` (processed spool offset),
`src/test/aiur/claude/hook_settings_test.exs`,
`src/test/aiur/claude/hook_events_test.exs`.
**Approach:** `HookEvents.replay(identifier, from_offset)` reads spool lines
past the offset, normalizes them through the same path as POSTs, and
broadcasts. Live POSTs also advance the offset so replay after a normal run
is a no-op.
**Test scenarios:**
- Hook command with the dashboard down exits 0 and the line is in the spool.
- Replay from offset 0 delivers `UserPromptSubmit`, `PostToolUse`, `Stop` in
  order.
- An event delivered by POST and present in the spool is broadcast once.
- Corrupt spool line is skipped with a warning; later lines still replay.
**Verification:** a REPL turn whose `Stop` was only spooled completes after
replay in a test.

## Scope Boundaries

- Adoption of panes by a new daemon is KA3; this ticket only makes them
  survivable and the events recoverable.

## Risks

| Risk | Mitigation |
|---|---|
| Operators attach to the old socket by habit | `aiur agents` and the dashboard print the attach command with the agent socket. |
| Hook shell gets slower | One `>>` append; measured cost is negligible next to `curl`. |

## Verification Contract

Suites above green; manual: stop the dashboard listener in a test daemon,
let a REPL turn finish, restart the listener, replay delivers `Stop`.

## Definition of Done

U1-U2 merged; docs mention the agent socket in the operator guide.
