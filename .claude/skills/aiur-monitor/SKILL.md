---
name: aiur-monitor
description: "Use when you want to view the status of a running aiur session's agents — runs `aiurdev watch` to compile a one-glance board and posts it. For checking in on aiur, whether a CLI-viewable session you're watching or a background run; to LAUNCH aiur itself use the aiur-run skill instead. Triggers: 'aiur status', 'aiur monitor', 'how are the agents doing', 'what are the agents working on', 'tail the agents', 'iarc status'."
---

# Agent Status

Post a one-glance status board for a running aiur session. The board is compiled
**server-side by aiur itself** — `aiurdev watch` reads the orchestrator's own
status snapshot + the structured alert feed in a single call, so this skill no
longer hand-rolls the table from `gh`/`jq` + log-tailing scripts.

`iarc` is an operator alias for `aiur` in this repo. Treat `/iarc status` as this
same aiur agent-status playbook.

## Procedure

### 1. Compile the board

```bash
aiurdev watch --changes    # deltas since last call + actionable items (low-token)
aiurdev watch --full       # the complete board, every active agent
```

Use `--changes` for the periodic cadence tick (only rows whose state changed +
anything actionable) and `--full` when the operator asks for the whole board or
on your first tick of a session. The output is one row per active agent
(`TICKET · STATE · CX · AGE · DOING`) followed by an `ACTIONABLE` section
(needs-attention alerts, stuck agents, PR-ready tickets). Stuck detection (no
agent activity for >10m), complexity, and tracker state are all computed
server-side — you do not classify the log tail yourself anymore.

### 2. Replace activity with log detail

The raw `DOING` cell is intentionally compact and often shows low-level stream
events (`item started`, token/rate-limit updates, command output dots). Do not
post that column verbatim. Before posting a status tick, replace the raw
`DOING`/`ACTIVITY` value with a concise operator-readable update for each active
ticket.

Use the current aiur log root first, then workspace logs if the central log does
not have enough context:

```bash
LOG_ROOT="$(ls -td ~/.aiur/logs/* | head -1)"
rg "info: \[(agent|alert)\] \(#<id>\)" "$LOG_ROOT/log/aiur.log" | tail -20
```

If needed, read the corresponding workspace `logs/agent.md` tail as a fallback.
Prefer, in this order:

- the latest completed agent prose about current work or validation state
- phase/progress/blocker alerts
- meaningful command results (test summaries, PR creation, commit/push status)

Ignore raw streaming deltas, token/rate-limit updates, repeated debug events,
and uninformative command-output dots. If `aiurdev watch --changes` prints
`(no changes)`, still include refreshed detail sentences from the logs; a steady
board with stale prose is not a useful operator update.

Render a normalized table. The final column is `UPDATE`, not `DOING` or
`ACTIVITY`, and each update must be **10 words or fewer**:

```text
ISSUE  STATE    RUNTIME  UPDATE
#123   working  12m      Full gate rerunning after auth cleanup.
#124   paused   9m       Paused: fixture cleanup blocks full gate.
```

Each update should be specific enough that the operator can tell whether the
agent is implementing, validating, blocked, committing, pushing, or waiting for
review without opening the logs themselves. If an issue is paused or blocked,
lead with `Paused:` or `Blocked:`.

### 3. Post it

Post the normalized table to the operator (a fenced block is fine). The aiur
board is the status source, but the visible `UPDATE` column is log-derived and
replaces raw activity text. Two things to surface on top of the table:

- **`⚠️ Needs you`** — when the `ACTIONABLE` section is non-empty, add ONE line
  below the board, `⚠️ Needs you: #<id> (<why>)`, naming what the operator must
  actually DO (review/merge a PR, unblock or answer an agent, act on a stuck
  agent). **Never** emit it as reassurance — if `ACTIONABLE` is empty, OMIT the
  line entirely (no "all clear", no "nothing blocking").
- **Daemon down.** If `aiurdev watch` reports the orchestrator is not running
  (`aiur: orchestrator is not running`), the BEAM is gone — render a
  `🔴 daemon down` line instead of "no active agents", and tell the operator the
  node needs restarting.

## Monitoring cadence (REQUIRED DEFAULT)

This is a required behavior, not soft guidance. **WHILE an aiur run is live** (you launched it
via `aiur-run`, or one is running in this repo) you **MUST** post the operator a fresh board
(run `aiurdev watch` → post it) **every `<the operator's chosen interval>`** (established once by
asking — via `aiur-run`'s launch ask / `aiur-loop`'s Step 0 — and **default 5 minutes** if unset;
the `/loop <chosen>m` interval; "approximately" is not license to stretch it past the chosen
interval), **automatically**, until the run reaches a terminal state or the operator says stop —
you do not get to opt out of "watching"; a live run obligates the cadence. 5 minutes is the
recommended default; the operator picks the value once and you never re-ask it.

Drive it with the loop skill (substitute the chosen interval; defaults to 5m):

    /loop <chosen>m /aiur-monitor    # e.g. /loop 5m /aiur-monitor for the default

**How to enforce the cadence — with an ARMED recurring timer, never with passive
event-waiting.** Drive it via `/loop <chosen>m /aiur-monitor`. If you are NOT inside a `/loop`
(e.g. you launched aiur via `aiur-run` and are orchestrating subagents directly), you **MUST** arm
an explicit recurring wake yourself: a background ~`<chosen>`-minute timer that re-invokes you and
that you **RE-ARM every tick** (or an equivalent scheduled wakeup). **Do NOT rely on
subagent-completion, PR, CI, or watcher notifications to drive the cadence** — those have no time
floor, so a long compile, a slow review, or a quiet stretch will silently skip updates. The
interval clock runs independently of whatever else is in flight; a tick fires even mid-task (post
the board, then continue).

Rules — close every "wait to be asked" loophole (these apply to the chosen interval):
- The operator should **NEVER** have to ask for the next update. The cadence is automatic;
  re-asking is the failure this rule exists to prevent.
- **Don't skip a tick because "nothing changed."** Post the board anyway and note steady-state
  (e.g. "steady, no change since HH:MM"). A missing tick reads as "the agent stopped watching."
  `aiurdev watch --changes` will print `(no changes)` — relay that; it is still a tick.
- **Don't wait for a PR, an event, or a state change** to post. The chosen-interval clock is the
  only trigger.
- **Don't defer the tick because you're mid-task.** Reviewing a PR, curating tickets, or fixing a
  bug does NOT pause the clock. The board is posted on every interval tick regardless of what else
  you're doing — interleave it, don't postpone it.
- **Terminal / stop only.** Keep looping until the operator explicitly stops it OR the run has
  truly ended (daemon down AND no active agents on two consecutive ticks). A single "no active
  agents" read early in a run is warm-up/dispatch lag, NOT a terminal state — keep ticking.
- If this skill is **already** running inside a `/loop`, do NOT start a nested loop — just post the
  board and let the existing loop re-invoke on the next interval tick.
- A single one-shot snapshot (no cadence) is allowed only when the operator explicitly asks for
  one; otherwise the live-run default is the chosen-interval auto-cadence above (default 5 min).

## Real-time alert relay (additive immediacy)

`aiurdev watch`'s `ACTIONABLE` section is the **pull** path — actionable alerts reach the operator
on every cadence tick. For **push** immediacy (the instant an alert fires, between ticks), arm the
streaming watcher **once per session** — at launch (the `aiur-run` Alerts step does this), or on
your first monitor invocation — with the **Monitor tool**, `persistent: true`:

```bash
bash .claude/skills/aiur-monitor/scripts/watch-alerts.sh
```

It prints **one JSON line per NEW alert** as it lands (history at startup is skipped). Each emitted
line is one Monitor event — post it in chat so the operator gets the "why" the instant they hear
the chime:

```
#<ticket> · <name> · <reason>
```

For any **NEW** `needs_attention:true` alert, also relay it via **PushNotification**, formatted
`#<ticket> · <agent> · <reason> — needs you`, so it reaches their phone. Rules:
- **Arm it once.** It is a persistent, long-lived stream — do NOT re-arm it on every monitor tick
  (that would stack duplicate watchers). It tracks emitted alerts in memory, so it never replays
  one across its lifetime. `AIUR_ALERT_NEEDS_ATTENTION=1` makes it emit only `needs_attention:true`
  lines.
- **De-dup** — never push the same alert twice. Informational alerts (`needs_attention:false`) are
  posted in chat if streamed but **not** pushed to the phone.
- This is **additive immediacy, not the status cadence.** The board still fires on the armed
  `/loop` timer above; the watcher only adds real-time alert posts on top.

## Notes

- Source of truth is aiur's own running state: `aiurdev watch` calls the orchestrator's status
  snapshot + the structured alert feed (the same data the dashboard renders) in one server-side
  call, so there is no `gh`/`jq` status reconstruction to maintain here. The concise `UPDATE`
  cells are intentionally log-derived summaries replacing only the raw activity column, not the
  aiur board's state/routing fields. The real-time alert watcher still reads each workspace's
  `logs/agent.ndjson` directly so it keeps working between ticks and across both workspace roots.
- Agent id == ticket id == workspace directory name.
