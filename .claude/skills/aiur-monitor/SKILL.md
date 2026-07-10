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

### 2. Post it

Post the `aiurdev watch` output to the operator as-is (a fenced block is fine).
The board already encodes status; do not re-derive it. Two things to surface on
top of the raw output:

- **`⚠️ Needs you`** — when the `ACTIONABLE` section is non-empty, add ONE line
  below the board, `⚠️ Needs you: #<id> (<why>)`, naming what the operator must
  actually DO (review/merge a PR, unblock or answer an agent, act on a stuck
  agent). **Never** emit it as reassurance — if `ACTIONABLE` is empty, OMIT the
  line entirely (no "all clear", no "nothing blocking").
- **Daemon down.** If `aiurdev watch` reports the orchestrator is not running
  (`aiur: orchestrator is not running`), the BEAM is gone — render a
  `🔴 daemon down` line instead of "no active agents", and tell the operator the
  node needs restarting.

## Progress-update format (required — two tables)

This is the required shape of **every periodic progress update** (each cadence tick — see
"Monitoring cadence" below). The `aiurdev watch` board tells you the live per-agent state; the
operator wants that state rolled up into **TWO markdown tables** so a glance shows the whole
refactor and the whole optimization backlog, not just the agents that happen to be active right
now. Post both tables, in this order, on every tick. This is a required format, not a suggestion —
do not substitute a prose summary or the raw board alone.

**Table 1 — Refactor tickets.** The full roadmap, **one row per ticket through the end of the
refactor** — recently-merged, currently-active, AND upcoming (not-yet-created) tickets, so the
operator sees the complete arc. Columns: `Ticket | Description | Phase | Status`. Status markers:

- **✅ Merged** — done and merged.
- **🔵 Active** — in-progress / rework / todo / human-review (anything an agent is or will soon be
  holding). Include the PR/issue number when there is one (e.g. `🔵 #879 in-progress`).
- **⬜ Upcoming** — not yet created / not yet started.

Contiguous runs of done tickets MAY be collapsed to a single row to keep the table scannable
(e.g. `T-001–T-021 … ✅ all merged`); keep active and upcoming tickets as individual rows so the
near-term work is legible.

**Table 2 — Optimization / bottleneck tickets.** The optimization/bottleneck backlog that runs
alongside the refactor. Columns: `# | Description | Status`. Show what's merged, what's active,
and what still needs work (held / blocked / staged). **Flag the current top blocker explicitly**
(e.g. `🔴 in-progress — BLOCKS ALL MERGES`) so the operator can see at a glance what is gating the
rest.

Concrete example (abbreviated — real updates carry every remaining ticket, not `…`):

```
## Table 1 — Refactor tickets
| Ticket | Description | Phase | Status |
|---|---|---|---|
| T-001–T-021 | Phase 1 safety-net + Phase 2 core seams | 1–2 | ✅ all merged |
| T-024 | orchestrator: comment/PR paths | 3 | 🔵 #851 todo |
| T-025 | orchestrator: sync subscriptions | 3 | ⬜ upcoming |
| T-036 | runner: streams slim | 3 | 🔵 #879 in-progress |
| … one row per remaining ticket through T-060 … | | | |

## Table 2 — Optimization / bottleneck tickets
| # | Description | Status |
|---|---|---|
| #856 | Daemon hardening (scheduler cap + crash-dump) | ✅ merged |
| #884 | Restore v2 coverage ≥85% | 🔴 in-progress — BLOCKS ALL MERGES |
| #877 | Close the CI feedback loop | 🔵 in-progress |
| #873 | Agents skip local credo (lint = #1 CPU) | 🟡 staged in prompt |
```

The `⚠️ Needs you` line and the daemon-down line above still apply on top of the two tables —
surface them alongside the tables, not instead of them.

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
  call, so there is no `gh`/`jq` or per-agent log classification to maintain here. The real-time
  alert watcher still reads each workspace's `logs/agent.ndjson` directly so it keeps working
  between ticks and across both workspace roots.
- Agent id == ticket id == workspace directory name.
