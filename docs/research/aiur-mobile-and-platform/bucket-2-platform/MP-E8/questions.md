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
