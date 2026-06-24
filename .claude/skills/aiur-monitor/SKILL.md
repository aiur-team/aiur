---
name: aiur-monitor
description: "Use when you want to view the status of a running aiur session's agents — tails each active agent's log and emits a one-glance status table. For checking in on aiur, whether a CLI-viewable session you're watching or a background run; to LAUNCH aiur itself use the aiur-run skill instead. Triggers: 'aiur status', 'aiur monitor', 'how are the agents doing', 'what are the agents working on', 'tail the agents', 'iarc status'."
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
bash .claude/skills/aiur-monitor/scripts/tail-agents.sh
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

## Monitoring cadence (REQUIRED DEFAULT)

This is a required behavior, not soft guidance. **WHILE an aiur run is live** (you launched it
via `aiur-run`, or one is running in this repo) you **MUST** post the operator a fresh formatted
status table (steps 1–3: gather → classify → emit) **every `<the operator's chosen interval>`**
(established once by asking — via `aiur-run`'s launch ask / `aiur-loop`'s Step 0 — and **default
5 minutes** if unset; the `/loop <chosen>m` interval; "approximately" is not license to stretch it
past the chosen interval), **automatically**, until the run reaches a terminal state or the
operator says stop — you do not get to opt out of "watching"; a live run obligates the cadence.
5 minutes is the recommended default; the operator picks the value once and you never re-ask it.

Drive it with the loop skill (substitute the chosen interval; defaults to 5m):

    /loop <chosen>m /aiur-monitor    # e.g. /loop 5m /aiur-monitor for the default

Rules — close every "wait to be asked" loophole (these apply to the chosen interval):
- The operator should **NEVER** have to ask for the next update. The cadence is automatic;
  re-asking is the failure this rule exists to prevent.
- **Don't skip a tick because "nothing changed."** Post the table anyway and note
  steady-state (e.g. roll-up "9 running · steady, no change since HH:MM"). A missing tick
  reads as "the agent stopped watching."
- **Don't wait for a PR, an event, or a state change** to post. The chosen-interval clock is the
  only trigger.
- **Don't defer the tick because you're mid-task.** Reviewing a PR, curating tickets,
  or fixing a bug does NOT pause the clock. The status table is posted on every interval tick
  regardless of what else you're doing — interleave it, don't postpone it.
- **Terminal / stop only.** Keep looping until the operator explicitly stops it OR the run
  has truly ended (daemon down AND no active agents on two consecutive ticks). A single
  "no active agents" read early in a run is warm-up/dispatch lag, NOT a terminal state —
  keep ticking.
- If this skill is **already** running inside a `/loop`, do NOT start a nested loop — just
  emit the table and let the existing loop re-invoke on the next interval tick.
- A single one-shot snapshot (no cadence) is allowed only when the operator explicitly asks
  for one; otherwise the live-run default is the chosen-interval auto-cadence above (default 5 min).

## Alert relay

aiur emits ALERTs (and plays a sound) as it runs, but the operator just hears a
random chime with no context. On **each monitor tick**, after the status table,
also run the alert tailer and relay anything operator-actionable so they get the
"why" the instant they hear it:

```bash
bash .claude/skills/aiur-monitor/scripts/tail-alerts.sh
```

It scans the same roots as `tail-agents.sh` (config `workspace.root` +
`~/.aiur/workspaces`, deduped, recency-windowed) but reads each active agent's
`logs/agent.ndjson`, pulls `.event == "alert"` lines, and emits one structured
line per alert (newest last) after a `DAEMON` header:

```
{"ticket":"43","agent":"43","reason":"Agent paused","name":"ticket.43.agent.paused","needs_attention":true}
```

`needs_attention` is computed in shell (no model) — true when the topic `name`
contains, on a segment boundary, any of: `human-review`, `input_required`,
`paused`, `thrash`, `retry_exhausted`, `tokens_exhausted`. (`unpaused` is the
all-clear and is deliberately **not** flagged.)

For any **NEW** `needs_attention:true` alert, relay it to the operator via
**PushNotification**, formatted:

```
#<ticket> · <agent> · <reason> — needs you
```

so they get the context the instant the sound plays. Rules:
- **De-dup** — track relayed alerts (e.g. by `name` + `reason` per agent) and
  never push the same one twice across ticks.
- Informational alerts (`needs_attention:false`) are **not** pushed — they're
  available if the operator asks ("what was that sound?"), but don't notify.
- Same knobs as `tail-agents.sh`: `AIUR_ACTIVE_WINDOW_MIN`, plus
  `AIUR_INCLUDE_STALE=1` to sweep a finished run and `AIUR_ALERT_TAIL=N` to cap
  alerts per agent.

## Notes

- Source of truth is each workspace's `logs/agent.md` (the same log the dashboard
  renders) and `logs/agent.ndjson` (the structured stream the alert relay reads).
  The scripts never attach to tmux or the running node, so they're safe
  to run anytime alongside a live aiur.
- The script scans the config `workspace.root` **and** `~/.aiur/workspaces`
  (deduped), because a live `--bg` instance writes to the latter while the
  source repo's config still points at its own default. Daemon liveness is a
  `pgrep` for the `rel/aiur` BEAM plus tmux sessions; both are read-only probes.
- Agent id == ticket id == workspace directory name.
