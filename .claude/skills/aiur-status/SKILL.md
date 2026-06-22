---
name: aiur-status
description: "Tail the logs of all active aiur agents and report each one's current status as a concise table. Use when aiur is running and you want a quick overview of in-flight agents — e.g. 'how are the agents doing', 'agent status', 'tail the agents', 'what are the agents working on'."
---

# Agent Status

Produce a one-glance status table for every **active** aiur agent by tailing its
per-agent log. One row per agent: what it is, what state it's in, and a concise
phrasing of what it's doing right now.

## Procedure

### 1. Gather recent log tails

Run the gather script (resolves `workspace.root` from `.aiurconfig`, finds
workspaces whose `logs/agent.md` changed recently, and prints a tail of each):

```bash
bash .claude/skills/aiur-status/scripts/tail-agents.sh
```

Knobs (env vars), only if asked:
- `AIUR_ACTIVE_WINDOW_MIN` (default 15) — how recent counts as "active".
- `AIUR_TAIL_LINES` (default 45) — log lines per agent.
- `AIUR_INCLUDE_STALE=1` — also include agents idle beyond the window.

Each block looks like:
```
===== AGENT 341 | last activity 2m ago | session yes =====
## 2026-06-21T14:22:31Z item/started
```text
{"method":"item/started","params":{"item":{"type":"commandExecution","command":"mix test test/aiur/orchestrator_test.exs"}}}
```
...
```

### 2. Read each agent's tail and classify

For each `AGENT` block, read the last events and infer state + a one-line focus.
Map the latest meaningful events to a status:

| Status | Signal in the tail |
|--------|--------------------|
| 🟢 Working | recent `item/agentMessage`, `reasoning`, or a `commandExecution` still running; `turn/started` with no completion yet |
| 🧪 Verifying | the running/last command is tests, build, lint, CI (`mix test`, `make`, `gh pr checks`, …) |
| 🔀 Landing | opening/working a PR (`gh pr create`, push, merge) near the tail |
| ⏳ Awaiting input | `paused` / `input_required` / a question posed with no follow-up |
| 🚧 Blocked | a declared blocker or an alert event (`alert`, `alert_emitted`) that hasn't cleared |
| ❌ Failed | an error/non-zero command at the tail with no recovery, or a failed turn |
| ✅ Done | `turn` completed, PR landed, or a closing summary with no later activity |
| 💤 Idle | recent file but no active turn (e.g. waiting between polls) |

Prefer the **most recent** strong signal. If the last line is a long-running
command with output deltas, it's 🟢/🧪 (still running), not ✅.

### 3. Emit the table

Output **only** a compact Markdown table, newest activity first. Keep each cell
short — the "Doing now" column is a single plain-language clause, not a log dump.

```
| Agent | Status | Last seen | Doing now |
|-------|--------|-----------|-----------|
| #<id> | <emoji status> | <Nm ago> | <one concise clause> |
```

Then, if anything needs the operator, add one line below the table:
`⚠️ Needs you: #<id> (<why>), …` — otherwise `All agents progressing; nothing blocked.`

Rules for the phrasing:
- Name the concrete thing: "running `mix test` (orchestrator suite)", "writing the epmd-reap fix", "opened PR #382, watching CI", not "the agent is working".
- ≤ ~10 words per "Doing now" cell.
- Don't invent progress the log doesn't show. If a tail is ambiguous, say "unclear — last event Nm ago".
- If the script reports no active agents, say so in one line; don't print an empty table.

## Live monitoring

This is a snapshot. For a live feed, pair it with the loop skill, e.g.
`/loop 60s /aiur-status` — re-runs every 60s so the table refreshes as agents work.

## Notes

- Source of truth is each workspace's `logs/agent.md` (the same log the dashboard
  renders). The script never attaches to tmux or the running node, so it's safe
  to run anytime alongside a live aiur.
- Agent id == ticket id == workspace directory name.
