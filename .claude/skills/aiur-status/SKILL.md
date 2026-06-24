---
name: aiur-status
description: "Tail the logs of all active aiur agents and report each one's current status as a concise table. Use when aiur is running and you want a quick overview of in-flight agents — e.g. 'iarc status', 'aiur status', 'how are the agents doing', 'agent status', 'tail the agents', 'what are the agents working on'."
---

# Agent Status

Produce a one-glance status table for every **active** aiur agent by tailing its
per-agent log. One row per agent: what it is, what state it's in, and a concise
phrasing of what it's doing right now.

`iarc` is an operator alias for `aiur` in this repo. Treat `/iarc status` as this
same aiur agent-status playbook.

## Procedure

### 1. Gather recent log tails

Run the gather script (resolves `workspace.root` from `.aiur/config`, falling
back to a legacy `.aiurconfig`; finds workspaces whose `logs/agent.md` changed
recently, and prints a tail of each):

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

Output **only** a status table, **sized to the operator's terminal width** so every agent stays on **exactly one line** (never wrap). Wider terminal ⇒ more columns / more detail; narrower ⇒ fewer. Always one row per agent.

**Find the width.** `tput cols` (fallback `$COLUMNS`). If that returns a non-tty default (`80`/`0`) or is unavailable — common when the skill runs from an agent's piped shell — use the width the operator gave you for this session; if none, assume `120`. Then pick the widest column set that fits, and **truncate any overflowing cell with `…`** so no row wraps.

| Width | Columns |
|---|---|
| `< 90` | `\| Agent \| Doing \|` |
| `90–129` | `\| Agent \| Ticket \| Doing \|` |
| `≥ 130` | `\| Agent \| Ticket \| Cx \| Doing \|` (Doing can run longer — still one line) |

- **Agent** = `<emoji> #<id>` — the emoji *is* the status (🟢 working · 🧪 verifying · 🔀 landing · ⏳ awaiting · 🚧 blocked · ❌ failed · ✅ done · 💤 idle); no separate status word/column.
- **Ticket** = short slug (truncate with `…`). **Cx** = complexity 1–5. **Doing** = concrete clause, longer when there's width ("typecheck + lint", "editing Velodrome CL encoder", "opened PR #382"), never "the agent is working".
- Order most-advanced / newest activity first.
- Header line above the table: `**aiur <HH:MM> · <one-glance roll-up>**` (e.g. `9 running · 1 review`).
- Only if something needs the operator, ONE line below: `⚠️ Needs you: #<id> (<why>)`. Otherwise add nothing.
- Don't invent progress the log doesn't show; ambiguous tail ⇒ `unclear`. No active agents ⇒ say so in one line, don't print an empty table.

## Monitoring cadence (default)

Default to **live monitoring on a 2-minute interval** — emit a fresh per-agent
status table every 2 minutes while aiur is running, so the operator gets a steady
heartbeat without asking. Drive it with the loop skill:

    /loop 2m /aiur-status

Each tick runs steps 1–3 (gather → classify → emit). Keep looping until every
agent reaches a terminal state (✅/❌, or the script reports no active agents) or
the operator stops it. If this skill is **already** running inside a `/loop`, do
NOT start a nested loop — just emit the table and let the existing loop re-invoke.
For a single one-shot snapshot instead of the loop, say so explicitly when invoking.

## Notes

- Source of truth is each workspace's `logs/agent.md` (the same log the dashboard
  renders). The script never attaches to tmux or the running node, so it's safe
  to run anytime alongside a live aiur.
- Agent id == ticket id == workspace directory name.
