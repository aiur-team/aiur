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

Run the gather script. It scans **both** the `workspace.root` from `.aiur/config`
(legacy `.aiurconfig` fallback) **and** the canonical live-instance tree at
`~/.aiur/workspaces/<owner>/<repo>/<id>/logs/agent.md`, dedupes across them,
probes daemon health, and prints a tail of each recently-active agent:

```bash
bash .claude/skills/aiur-status/scripts/tail-agents.sh
```

Scanning both roots is the fix for #489: a `--bg` run materializes workspaces
under `~/.aiur/workspaces`, **not** the source repo's configured
`workspace.root`, so a single-root scan reported a false "no active agents"
while a run was live. Never trust the static config root alone.

Knobs (env vars), only if asked:
- `AIUR_ACTIVE_WINDOW_MIN` (default 15) — how recent counts as "active".
- `AIUR_TAIL_LINES` (default 45) — log lines per agent.
- `AIUR_INCLUDE_STALE=1` — also include agents idle beyond the window.

The first block is always the **daemon-health header**, then one block per agent:
```
===== DAEMON node yes | last activity 2m ago | roots /Users/me/.aiur/workspaces =====

===== AGENT 341 | last activity 2m ago | session yes | root /Users/me/.aiur/workspaces =====
## 2026-06-21T14:22:31Z item/started
```text
{"method":"item/started","params":{"item":{"type":"commandExecution","command":"mix test test/aiur/orchestrator_test.exs"}}}
```
...
```

Read the `DAEMON` header first:
- `node no` with a recent `last activity` (or an explicit `daemon down:` line) ⇒
  the BEAM is gone but agents were just running. Render a **red** daemon row
  (`🔴 daemon down · last activity Nm ago`) — this is exactly the case #489
  required us to stop silently swallowing. Do **not** report "no active agents"
  when the daemon-down line is present.
- A `warning: … mismatch …` line ⇒ the `.aiur/config` `workspace.root` is stale
  and unused; surface it as the `⚠️ Needs you` line so the operator fixes config.

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

Output **only** a status table — one row per agent, never wrapped. Use this layout:

```
**aiur <HH:MM> · <one-glance roll-up>**

| Agent | Ticket | Cx | Doing |
|---|---|---|---|
| <emoji> #<id> | <slug> | <1–5> | <concrete clause> |
```

- **Agent** = `<emoji> #<id>` — the emoji *is* the status (🟢 working · 🧪 verifying · 🔀 landing · ⏳ awaiting · 🚧 blocked · ❌ failed · ✅ done · 💤 idle); no separate status word/column.
- **Ticket** = slug · **Cx** = complexity 1–5 · **Doing** = a concrete clause ("typecheck + lint", "editing Velodrome CL encoder", "opened PR #382"), never "the agent is working". Truncate any long cell with `…` so each row stays a single line.
- Order most-advanced / newest activity first.
- Header line above the table: `**aiur <HH:MM> · <one-glance roll-up>**` (e.g. `9 running · 1 review`).
- Only if something needs the operator, ONE line below: `⚠️ Needs you: #<id> (<why>)`. Otherwise add nothing.
- Don't invent progress the log doesn't show; ambiguous tail ⇒ `unclear`. No active agents ⇒ say so in one line, don't print an empty table.
- **Daemon row.** When the `DAEMON` header reports `node no` with recent activity (or a `daemon down:` line), prepend a `🔴 daemon down · last activity Nm ago` row to the table — never collapse a downed-but-recently-active node to "no active agents".

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
- The script scans the config `workspace.root` **and** `~/.aiur/workspaces`
  (deduped), because a live `--bg` instance writes to the latter while the
  source repo's config still points at its own default. Daemon liveness is a
  `pgrep` for the `rel/aiur` BEAM plus tmux sessions; both are read-only probes.
- Agent id == ticket id == workspace directory name.
