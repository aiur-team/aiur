---
gate: DESIGN-E8
feature: MP-E8 Continuous build history
owner: Kevin
tool: Claude Design (prototype)
status: design delivered in Claude Design; awaiting Kevin's go to plan and implement, plus his side-by-side sign-off
blocks: all 76 MP-E8 tickets (bucket-2-platform/MP-E8/tickets/README.md), and MP-E1-C8 (superseded by MP-E8, CR-E8-1)
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

## Sign-off items added by the planning pass (2026-10-07)

The plan ([../bucket-2-platform/MP-E8/plan.md](../bucket-2-platform/MP-E8/plan.md)) found states and
choices the design does not show. Each has a default the tickets follow. Kevin
approves or replaces each one in the side-by-side sign-off (MP-E8-C12-T08).

| ID | Item | Default until answered | Tickets |
| --- | --- | --- | --- |
| S-1 | The shell, tokens and Gruvbox palette apply to every page, including hiding `#decisions-banner` and the page header on every page (Commands attention moves to the nav count) (OQ-E8-1) | Yes, app-wide | C2-T01, C2-T02 |
| S-2 | Khala nav item (OQ-E8-2) | Not shown | C2-T02 |
| S-3 | Dependency-chain hover is on only with `?trees=1`; no visible control | As designed | C9-T11 |
| S-4 | Agent-state glyph on the logo is empty in the design | Screen-reader label only; no visible glyph | C9-T06 |
| S-5 | Gantt card for a past ticket whose start is unknown | End-anchored minimum-height card, "start unknown" tooltip | C4-T04, C9-T09 |
| S-6 | Conversation of a past ticket whose transcript was not retained | Issue view plus a one-line "Conversation not retained" note in `.bm-cue` style | C11-T03 |
| S-7 | Composer states for a failed send and an unknown outcome | Draft kept; a one-line state under the input in the design's muted/bad tones | C11-T06 |
| S-8 | Where an epic or feature change shows with its source (agent, human, backfill), how an unconfirmed classification looks, and where it is confirmed (item 10) | Not on the board or modal; visible through `aiur epic` / `aiur feature show --json`. C13-T03 waits | C13-T03, C11-T04 |
| S-9 | "Queue unavailable" / "history unavailable" copy (distinct from empty) | Same `.bd-mk.empty` marker with "unavailable" copy and the age | C9-T13 |
| S-10 | Modal for a `?ticket=` id that does not exist | Modal frame with "Ticket not found" in the header area | C11-T01 |
| S-11 | Microphone button when voice is not configured | Disabled, with a reason in its title | C11-T09 |
| S-12 | Keyboard focus rings and the forced-colours fallback (not in the design) | `:focus-visible` ring in the accent token, keyboard only; dashed outline for dimmed cards under forced colours | C12-T05 |
| S-13 | Logo for a model the design does not include (muse, openrouter, unknown) | The `.ax-mono` letter circle, sized to each logo slot | C8-T01, C9-T06, C9-T12, C10-T02, C11-T01 |
| S-14 | "Add to queue": disabled, pending, failed and success states | Design button look; disabled with a reason in its title; pending disables it; on success the diff moves the row | C11-T02 |
| S-15 | Loading older conversation entries at the top of the log | A one-line `.cv-end`-style "Loading earlier…" row | C11-T03 |
| S-16 | "Reconnect" in progress or failed | Button disabled with "Reconnecting…"; on failure the banner stays | C8-T03 |
| S-17 | Look of a `not_planned` closure (E8-R1), collapsed by default | `failed` swatch family in the muted tone, label "Not planned" | C10-T02, C9-T05 |

Also for confirmation: every planner decision in plan §10 (items 1–28), in
particular the Units fields and CI state the modal omits (OQ-E8-5, conditional
ticket C11-T10), no type filter (OQ-E8-4), the Build Order panes retiring
(OQ-E8-9), the demo-only controls dropped (item 5), and sending to a parked agent
(OQ-E8-10).
