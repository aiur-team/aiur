---
aside: false
---

# Ticket lifecycle timeline

This visual follows one representative ticket from the queue through deployment. It complements [How a ticket flows](/concepts/ticket-lifecycle), which explains the label lifecycle, and [Ticket flow: steps 0–8](/concepts/ticket-lifecycle-steps), which gives the step-by-step reference.

<LifecycleTimeline />

## Reading the chart

Icons and borders identify commands, emitted events, consumed events, and notes. Event sources are kept with the chart data for maintainers. Matching emits and consumers share a timeline point.

Progress percentages are illustrative positions, not elapsed time or guarantees. Agents report estimates for the agent-list display. A 100% update does not prove that a worker slot has been released; Build Order completion is a separate member-resolution measure.

The dashboard Build ticket detail has a live Timeline tab for recorded ticket events; open any ticket and select **Timeline** to see it live on a real ticket. The view uses the same actor/kind vocabulary as this lifecycle example and places recorded items at their observed times.

This is the happy path. GitHub events can arrive through polling or webhook reconciliation, and review feedback, failed CI, blockers, or retries can add turns. See the [label lifecycle](/concepts/ticket-lifecycle) and [step reference](/concepts/ticket-lifecycle-steps) for details.

## Dashboard timeline data

The live Build ticket Timeline uses the same actor and item-kind vocabulary as this chart. Each item carries its event ID, observed timestamp, actor, kind, display label and event topic; progress items also carry the reported percentage. Phase intervals are built from matching phase start/end events. The per-ticket event log stores emitted and consumed event markers, plus agent command markers containing command text only. It does not store command output. The timeline pages this durable log by event ID and keeps the last rendered page in the open ticket view.
