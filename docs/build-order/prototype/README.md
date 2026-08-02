# Build Order — design prototype (reference, not gospel)

This folder is a **visual/interaction prototype** of the "Build Order" view for the
Aiur Operator Control Center, exported from the Claude Design project so it can live
in-repo. It exists because the design tool isn't reachable from the Codex agent's
environment — this is the offline stand-in.

**Treat it as a point of reference and a prototype, not a spec to reproduce line for
line.** It shows the intended look, layout, and interactions. Where it and the written
constraints disagree, or where it does something awkward, use judgement — the goal is
the *idea* of the view, not a pixel-perfect port of a single-file mock.

## Files
- `Aiur Operator Control Center.html` — self-contained prototype. Open it directly in a
  browser (`open "Aiur Operator Control Center.html"`). No build step, no server, no
  network beyond Google Fonts. All logic/styles are inline; the only external
  dependencies are the icons in `assets/`.
- `assets/` — the 5 image assets the HTML references (Aiur logo, Claude/Codex tokens
  and symbols). Keep them beside the HTML; paths are relative (`assets/…`).
- `feature-constraints.md` — the design's own "grain of salt" companion. This is the
  closest thing to intent: what the mock commits to, the data model it assumes, and
  what it **deliberately defers**. Read this first.

## How to use it (for the implementing agent)
1. Read `feature-constraints.md` for the data model and layout rules, then open the
   HTML to see them realized.
2. Mine it for the concrete decisions the prose can't convey: the epic-lane × phase-layer
   grid, node card anatomy, the cleared-vs-blocking edge treatment, hover chain
   highlighting, and the pan/zoom canvas controls.
3. Lift design tokens (colors, type, spacing) from the `<style>` block rather than
   inventing new ones — they're ported from the aiur.team brand language.
4. **Do not** treat the mock's implementation choices as requirements. The single-file
   deterministic grid+SVG layout is a reliability hack for a build-less file; a real
   build should swap in a maintained layout/routing engine while preserving the
   lane/layer constraints and the node/edge visuals. Likewise the sample 20-ticket DAG
   is illustrative data, not fixture truth.
5. Honor the non-goals in `feature-constraints.md` (no dependency editing from the graph,
   no minimap/filter bar, etc.) unless the ticket explicitly expands scope.

Source: Claude Design project "Aiur Operator Control Center"
(`p/5e62b9a9-39c1-4ca2-9a76-6dff123a088c`), file `Aiur Operator Control Center.html`.
