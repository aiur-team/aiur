# Alert and Decision Relay

`aiurdev watch` is the periodic floor. `scripts/watch-alerts.sh` is an optional
real-time wake path for local-workspace alerts on hosts that can supervise a
persistent process. Remote-worker and workspace-less alerts live in Aiur's
central feed and remain cadence-bound to `aiurdev watch`; do not claim that this
script provides immediate delivery for them.

## Arm once

Start the script once per run through the host's persistent background/monitor
facility:

```bash
AIUR_ALERT_NEEDS_ATTENTION=1 \
  bash .claude/skills/aiur-monitor/scripts/watch-alerts.sh
```

Consume each JSON line once and relay `#<ticket> · <name> · <reason>` to the
operator. Do not restart the process on every cadence tick; its in-memory cursor
deduplicates ordinary events. Stop it when the Aiur run ends.

The watcher skips ordinary history at startup but replays the latest unresolved
operator decision so a monitor restart cannot hide it. A later matching
`attention.resolved` event closes that decision.

## Decisions ledger

Before notifying on a new `operator_decision:true` event, upsert a durable
Decisions entry containing ticket, topic, exact question/reason, timestamp, and
state. Record reversible operational decisions as `auto` and product, scope,
architecture, destructive, or unauthorized decisions as `escalated`.

Use this compact shape in the handoff or status artifact:

```text
Ticket | Decision | Rationale | Mode | State
```

Keep unresolved escalations visible until the matching resolution arrives.
Record failed notification surfaces and retry them on a later re-ask.

## Operator surfaces

Set `AIUR_OPERATOR_SURFACES` to the active comma-separated surfaces and provide
only trusted stdin-command adapters:

- `AIUR_ALERT_NOTIFY_CLAUDE_COMMAND` for Claude native push;
- `AIUR_ALERT_NOTIFY_CODEX_COMMAND` for Codex device notification;
- `AIUR_ALERT_NOTIFY_FALLBACK_COMMAND` when Codex needs the configured Aiur
  device-notification fallback;
- `AIUR_ALERT_NOTIFY_RC_COMMAND` when Remote Control is active.

The relay sends structured alert JSON on stdin and reports each surface as
sent, failed, or unconfigured. Never place secrets in adapter command strings
or log output.

The real-time stream does not replace the recurring status cadence. A streamed
local alert wakes the Executor immediately; central-feed alerts arrive on the
next board, and the next scheduled board still runs on time either way.
