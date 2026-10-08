---
gate: DESIGN-E8
feature: MP-E8 Continuous build history
owner: Kevin
tool: Claude Design (prototype)
status: design delivered in Claude Design; awaiting Kevin's go to plan and implement, plus his side-by-side sign-off
blocks: all MP-E8 implementation tickets (not yet written), and MP-E1-C8 (its dashboard view is folded into MP-E8)
decisions: ../bucket-2-platform/MP-E8/decisions.md (E8-D1..D14, E8-R1)
research: ../bucket-2-platform/MP-E8/baseline.md, options.md, questions.md
---

# DESIGN-E8: Kevin designs and approves the continuous build history page

> **Design delivered (2026-10-08):** https://claude.ai/design/p/5e62b9a9-39c1-4ca2-9a76-6dff123a088c?file=Aiur+Dashboard.html
> It is the specification for MP-E8 and must be recreated **pixel-perfect**: every UI and UX element, the chat modal with its preview sidebar, the live pane's top-to-bottom transition, every filter and visualization mode, and the background noise in the live view.
> Read [../bucket-2-platform/MP-E8/claude-design-source-of-truth.md](../bucket-2-platform/MP-E8/claude-design-source-of-truth.md) first.


**Implementation is blocked until Kevin approves this design.** The prototype is built in Claude Design. MP-E8 planning and ticket research start from the approved prototype, so the plan follows the design and not the other way round.

## What to design

1. **The page at `/`.** It replaces both Build Order and Units. From top to bottom:
   - **history**, ordered by real time (E8-D3);
   - a **sticky "now" band** holding every ticket that has an active agent (E8-D8);
   - **planned** tickets, in MP-E1 queue order;
   - a separate final section of tickets that are **not queued**.
   - Also design where the page opens (at "now") and how you scroll in each direction.
2. **Epic columns** (E8-D1, D9, D13):
   - default general epics (Bugs, Design, Infra, Docs; projects can override them) plus short-lived feature epics;
   - columns follow the tickets on screen, and zooming changes them;
   - focusing on a feature locks its columns;
   - the motion when a column appears or disappears, and a stable relative order.
3. **The DAG.** Dependency edges keep their current shape. Design how an edge crosses the "now" band and section boundaries, and how an edge to a ticket off screen is drawn.
4. **The ticket card**, in its normal, compact and Gantt sizes:
   - ticket id, title, epic, complexity points, state;
   - **agent indicator** (E8-D12): a circular model logo in the corner; a gentle rotating glow while active; a red glow or shadow when stuck; a grey, static treatment when paused or parked;
   - a reduced-motion version;
   - a marker that does not rely on colour.
5. **Gantt mode** (E8-D4, D7):
   - a time axis with day and hour marks;
   - card height equals real duration for past tickets;
   - planned cards use the expected height from complexity points, or a recorded override, drawn so they never look like history;
   - how idle spans (nights, idle days) are compressed;
   - the toggle between the normal and Gantt layouts.
   - Reference: `../bucket-2-platform/MP-E8/gantt-reference.webp`.
6. **Feature focus and compact mode** (E8-D2, D11):
   - **Focus:** the feature's tickets are highlighted and everything else is greyed, using the existing grey-out/focus language.
   - **Compact:** unrelated tickets are removed and replaced by "+N unrelated · date range" gap markers.
   - Dependencies outside the feature appear as ghost nodes.
   - "Also affects" tickets are outlined, not filled.
   - The feature header shows done/total, original scope versus added scope over time, its epics, and the weighted completion figure (E8-R1).
7. **Filters** (E8-D5): ticket type, agent type or model, feature, epic, state, and more, using grey-out/focus. Design the filter bar, the active-filter chips, how filters combine, and how they show in the URL.
8. **The ticket/agent modal** (E8-D8): it holds every column from today's Units page:
   - model, runtime, turns, tokens/usage, pause state, chat entry, PR and CI;
   - links to the conversation (MP-E4) and its event jump points;
   - Command answers;
   - a shareable `?ticket=` URL.
9. **Queue controls** (folded in from DESIGN-E1): reading the queue order, holds, waiting on a dependency, a failed prerequisite (alert), and an un-promoted ticket. Controls on the page stay read-only, and changes are made through the CLI, unless you decide otherwise.
10. **Categorisation UX:** where an agent's or a human's category change shows, and how "Unsorted" and backfill-classified tickets look until they are confirmed.

## States the prototype must show

- loading
- empty history (a new repository)
- an empty planned section
- the not-queued section empty or long
- a long history (about 1,300 tickets) with zoomed-out density
- a stale or offline daemon
- a ticket with no epic (Unsorted)
- a feature with added scope
- an agent in each state: active, stuck, paused, parked
- a failed prerequisite holding its dependents
- reduced motion
- narrow, mobile-width screens (link with MP-N3; the phone opens instance dashboards in a WebView)

## Decisions only Kevin can make in the design

- Visual treatment of the "now" band, and whether it stays pinned.
- Gantt time-scale rules: hours or days, and how idle time is compressed.
- Which Units columns are always visible on the card, and which appear only in the modal.
- The palette for epics and features within aiur-style, and the colours for the glow states.
- The default filters on first load. Recommended: hide `not_planned` closures (E8-R1).
- Mobile-width behaviour.

## Acceptance

- The approved Claude Design prototype covers items 1–10 and every state listed above.
- Kevin explicitly approves it.
- The coordinator then writes the MP-E8 plan and tickets from the prototype, updates MP-E1 (C8 folded in, wave 0b) and the sequencing, and adds the tickets to the dependency graph. Each ticket cites the prototype screens it implements.
- No MP-E8 implementation ticket is marked ready before this approval.
