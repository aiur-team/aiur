# Build Order — feature constraints (v1 mock)

A grain-of-salt companion to the mock built into the dashboard. This narrows the
649-line spec down to what actually fits Aiur's existing UI and what this mock
commits to. Treat the built HTML as the source of truth for look/behavior.

## What this is
"Build Order" is a **third view of the same tickets** (alongside Units + Commands),
not a new entity. Every node is a `fleet` ticket; the graph is derived entirely from
per-ticket fields — no separate ticket type, no duplicated data.

## Data model added to each ticket
- `epic` — one of `docs | frontend | backend | infra` (also shown as a tag on Unit rows)
- `phase` — 1–5 build wave (vertical layer)
- `complexity` — 1–5 (shown as a ❶–❺ pill in the Model column and on the node)
- `icon` — line-art icon id from a controlled set (`BO_ICONS`), stored as metadata so
  rendering never needs a model call; falls back to a generic glyph
- `blockedBy` — array of upstream ticket ids (the only source of blocking truth)

Example set is **20 tickets** across the 4 epics and 5 phases with a coherent DAG,
including cross-epic edges (e.g. frontend `State management` ← backend `Auth token
service`; docs `API documentation` ← backend `Structured error responses`).

## Layout constraints
- **Vertical = build order / phase.** Merged/foundation work sits at the top (Phase 1);
  later waves descend. Phase is a *preferred layer*, NOT a global gate — a Phase 2
  ticket is blocked only by an explicit `blockedBy` edge, never by "all of Phase 1".
- **Horizontal = epic lanes** (Docs · Frontend · Backend · Infra). Tickets in the same
  phase but different lanes are parallelizable unless an edge connects them.
- Fixed lane columns + phase rows via CSS grid; cells stack multiple tickets vertically.
- ≥20 nodes readable on one desktop screen; canvas pans/zooms for any number more.

## Edges
- Direction is always **blocker → blocked**.
- **Cleared** (upstream done/merged): solid green.
- **Blocking** (upstream incomplete): dashed red.
- Routed as vertical bezier connectors behind the cards, with an arrowhead at the target.
- Hovering a node highlights its full upstream+downstream chain and dims the rest.

## Node card
Icon square · title · id · status · completion % · ❶–❺ complexity · progress bar.
100%/Merged → muted + desaturated. Blocked → red border. Click → existing ticket modal
(same data/behavior as the Unit table, not a Build-Order-specific editor).

## Canvas controls
Drag to pan · scroll to zoom · zoom −/+ · Fit-to-view. Zoom clamped 40–160%.

## Deliberately deferred (non-goals for this mock)
- Editing dependencies (add/remove blocker) from the graph
- Search / filter bar, minimap, hidden-dependency stubs
- Circular-dependency error surfacing (data here is acyclic)
- Automatic incremental relayout animations on data change
- A real graph library (Cytoscape/React-Flow/elk). This mock uses a deterministic
  grid+SVG layout for reliability in a build-less single file; a production build
  should swap in a maintained layout/routing engine while keeping the epic-lane +
  phase-layer constraints and these node/edge visuals.

## Theme + a11y
All colors derive from existing tokens; works in light + dark. Complexity and progress
don't rely on color alone (glyph + numeric %). Nodes are clickable; production should
add keyboard focus/enter-to-open and per-node accessible summaries (title, status,
progress, complexity, #blockers, #blocks).
