---
feature_id: MP-E8
artifact: product questions and resolved engineering questions
base_main_sha: b62d6d05938f3e5a6c91f0901c9b06f3ae099384
date: 2026-10-06
---

# MP-E8 — questions

Split from [options.md](options.md) (500-line limit); section references (§n) point there. Facts: [baseline.md](baseline.md).

## 8. Questions only Kevin can answer

Each question gives the options and a research recommendation.

1. **PQ-1. What are the general epics?**
   - Options: (a) ticket type: Bugs, Improvements, Infra, Docs; (b) product area,
     seeded from the built-in lanes; (c) both, with type as a filter.
   - Recommended: (a), as in Kevin's example, with type labels as matchers and an
     "Unsorted" column. Configured per repo.
2. **PQ-2. How does history get its epic?**
   - Options: (a) the label rule only, leaving about 49 % Unsorted; (b) a one-time
     classifier that writes the local override registry, with no GitHub writes;
     (c) the same, but also writing labels to GitHub (at least 2 hours of paced
     writes).
   - Recommended: (b).
3. **PQ-3. Column hiding:**
   - Options: (a) all columns hide when empty; (b) general columns fixed but
     collapsible, feature columns dynamic.
   - Recommended: (b), so cards never jump sideways.
4. **PQ-4. The time axis (open):**
   - Options: T-A completion time, T-B start time, T-C calendar buckets,
     T-D topological waves. Also: past above or below, and whether the page opens
     at "now".
   - Research leaning: T-A, past above, opens at "now".
5. **PQ-5. Which past tickets appear:**
   - Options: (a) all 1,226 closed; (b) only agent-worked (847); (c) all, with
     `not_planned` collapsed by a default filter.
   - Recommended: (c).
6. **PQ-6. One feature per ticket, or several?**
   - Recommended: one. Shared tickets show as ghosts in other features.
7. **PQ-7. The completion figure in feature headers:**
   - Options: (a) the lifecycle ratio (the catalog's figure); (b) complexity-weighted
     (the grid's figure).
   - Recommended: (b) for features, labelled "weighted". The two figures exist today
     and disagree (B§2.5).
8. **PQ-8. The MP-R1-C10 public list:**
   - Options: (a) a separate store with an optional `tracking` link; (b) one shared
     registry.
   - Recommended: (a).
9. **PQ-9. DESIGN-E1's dashboard queue view:**
   - Options: (a) fold it into MP-E8, with E1 shipping CLI-only; (b) build E1's
     panel now and replace it later.
   - Recommended: (a), unless the queue must be visible before E8. Decide together
     with sequencing: E8 after E1 (wave 0), and either before the refactor on a
     seam or after R1.
10. **PQ-10. What happens to `/` and the Units nav item:**
    - Options: (a) the history page becomes `/` and Units is removed after parity;
      (b) Units stays, and only its columns move into the modal.
    - Recommended: (a), with the old `?scope=` URLs redirecting to filter presets.
11. **PQ-11. Original-scope baseline:**
    - Options: (a) set automatically when aiur-build publishes; (b) set by an
      explicit `aiur feature baseline`.
    - Recommended: (a), with (b) available.
12. **PQ-12. Feature suggestions:**
    - Options: (a) the Executor confirms; (b) a human confirms; (c) whoever answers
      first.
    - Recommended: (a). This matches "never silent auto-tagging".

## 9. Engineering questions resolved here

- **Epic membership must not use the `epic:` prefix.** It switches off strand
  recovery (§1.2).
- **History needs a new durable store.** All existing caches expire. A backfill
  costs about 30 GraphQL points (measured), and the steady state is event-sourced
  (§4.2).
- **Join times are recoverable** from the GitHub timeline at the same cost. aiur
  journals new joins at the write (§2.5).
- **Rendering:** LiveView streams with row windows, stub edges, and no
  GraphAnalysis 100-node cap (§4).
- **Filters and feature focus** are server-computed `data-dim` in URL state. Compact
  mode and "hide non-matching" share the gap-marker mechanism (§2.6, §6).
- **The modal** gets a URL (`?ticket=`). The Units fields come from a per-ticket
  `UnitsRow`. The controls become shared `dashboard-ui` components (§5).
- **"Not queued"** = open, not a queue item, and no active agent state.
  `agent:todo` outside a queue counts as planned (§3.3).

## 10. Questions from the 2026-10-07 planning pass (OQ-E8-n)

Kevin was away. Each question has the default that tickets follow until he
answers. The defaults are also listed in [plan.md §10](plan.md#10-decisions-made-without-the-owner).

1. **OQ-E8-1. Does the design's shell and token change apply to every page?** The
   design restyles the top bar, adds a cog menu, a draggable sidenav, new tokens
   and the Gruvbox palette as the default. That changes Commands, Analytics and
   Streamdeck too. Default: yes, app-wide, because the design file is the whole
   dashboard. Tickets: MP-E8-C2-T01, C2-T02.
2. **OQ-E8-2. Add the Khala nav item?** The design's sidenav has one; the product
   has no Khala page. Default: no item until a Khala page exists. Ticket: C2-T02.
3. **OQ-E8-3. Keep a hidden `/units` route for one release as a rollback?**
   Default: yes. Ticket: C12-T01.
4. **OQ-E8-4. Ticket-type filter.** DESIGN-E8 item 7 lists it; the design has no
   "type" group (`FKEYS`, J:300). Default: follow the design, no type filter.
   Ticket: C10-T02.
5. **OQ-E8-5. Units fields the modal header does not show.** Runtime, turns,
   tokens/context, priority, resume reason, CI state and the Remote Control link
   are on the Units table today and are not in the design. E8-D5/D8 say the Units
   columns move into the modal. Default: follow the newer design and add none.
   If yes, the conditional ticket C11-T10 adds them. Tickets: C11-T01, C11-T10.
6. **OQ-E8-6. How does a real feature get its hue?** The design assigns hues by
   hand (`addF`, J:118). Default: a stable hash of the slug into the design's
   unused hue range, overridable in `aiur feature create --hue`. Ticket: C6-T01.
7. **OQ-E8-7. Planned estimate source.** The design table `[1,2,4,7,11]` hours by
   complexity, or the historical median by complexity. Default: the design table.
   Ticket: C7-T03.
8. **OQ-E8-8. The models counter button** ("4 models") cycles demo sets in the
   design. Default: show the real count, not clickable, same look. Ticket:
   C10-T04.
9. **OQ-E8-9. Retire the Build Order Breakdown, Analytics and Usage panes?** The
   design does not have them. Default: keep `/build-orders` reachable without nav
   until you confirm. Ticket: C12-T02.
10. **OQ-E8-10. Should messaging a parked agent resume it?** On main, a plain
    message resumes any paused agent when a slot is free, including one parked on
    its account limit (#2742), which then hits the limit again. Default: keep
    main's behaviour; no orchestrator change. Ticket: C11-T06.
