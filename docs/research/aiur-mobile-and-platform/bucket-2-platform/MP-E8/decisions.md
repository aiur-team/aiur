# MP-E8 Continuous build history: operator decisions

The operator, Kevin, settled these during the MP-E8 brainstorm on 2026-10-06.

| ID | Decision |
|---|---|
| E8-D1 | **Epic model:** a fixed list of general epics plus short-lived epics for each feature. Every ticket belongs to exactly one epic. While the operator scrolls, epic columns appear and hide based on the tickets in view. |
| E8-D2 | **Feature tagging:** tickets can be tagged with a feature name. A feature is a package of tickets plus the part of the DAG that built it, and it can grow over time (for example, 50 tickets becomes 60 within a build of 100). The feature filter highlights the feature's tickets with the existing grey-out/focus UI. A compact mode pulls them into a shorter vertical span without the unrelated tickets. |
| E8-D3 | **Time axis:** past tickets are ordered by real time, and planned tickets are ordered by the MP-E1 queue order. Below them is a separate section of open tickets that are not queued. |
| E8-D4 | **Gantt mode:** an extra view where tickets expand and map to time on the Y axis, like [gantt-reference.webp](gantt-reference.webp): <ul><li>columns are epic lanes, and a day/time axis runs on the left;</li><li>each card's height is its duration from start to end;</li><li>each card shows its start and end time, an estimate badge (hours) and points;</li><li>dependency arrows run between cards.</li></ul> |
| E8-D5 | **Units merge:** the build view shows which tickets have active agents. The Units page's columns move into the ticket/agent modal. Filters for ticket type, agent type and other fields use the existing grey-out/focus UI. |
| E8-D6 | **Gate:** implementation is blocked on a Claude Design owner task (DESIGN-E8). |

## Questions the Gantt mode raises (for research and for the owner)

- **What "start" and "end" mean for a past ticket.** Options are first dispatch or the first `agent:in-progress` label for start, and PR merge or issue close for end. Paused time and rework rounds either show as gaps inside the bar or are folded into it.
- **How planned tickets get times.** The proposal: project them from a duration estimate (the historical median by complexity or model, or an explicit estimate) and simulate the queue against agent capacity, so the future part of the chart becomes a forecast. The open question is whether a forecast is wanted at all, or whether planned tickets stay unscaled in queue order.
- **Where points and estimates come from.** Today there are only `complexity:N` labels, so points would map from complexity unless a new estimate field is added.
- **How the time scale handles idle spans.** Nights and idle days can collapse into compressed gap markers, as in compact mode.
