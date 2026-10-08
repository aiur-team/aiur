# MP-E8: the Claude Design is the specification. Recreate it pixel-perfect.

> **READ THIS BEFORE WRITING ANY MP-E8 CODE.**
>
> The approved design for the new aiur home page lives in Claude Design:
>
> **https://claude.ai/design/p/5e62b9a9-39c1-4ca2-9a76-6dff123a088c?file=Aiur+Dashboard.html**
>
> Project "Aiur Dashboard", file `Aiur Dashboard.html`. A local copy is in [`design-source/`](design-source/) once it is imported (see "Getting the code" below).
>
> The page combines the **Build Order** page and the **Units** page into one home page. **The outcome must be EXACTLY the same as the design.** Not "inspired by", not "close to", not "our interpretation of". The same.

## The non-negotiable rule

**Pixel-perfect recreation of the Claude Design home page.** The operator (Kevin) designed this page deliberately, element by element. Every difference between the shipped dashboard and the design is a bug, unless Kevin approved the difference in writing. Do not "improve", simplify, reinterpret, restyle, re-space or "clean up" the visual result. If you think something in the design is wrong, raise it as a question for Kevin. Do not change it yourself.

This covers, without exception:

- **Every UI element.** Layout, spacing, sizes, radii, borders, shadows, colours, opacity, typography (family, weight, size, line height, letter spacing), icons, logos, chips, badges, pills, progress bars, the epic and lane columns, cards, connectors and arrows, empty and loading states, and both the light and the dark theme.
- **Every UX element.** Hover, focus, active, selected and disabled states. Click targets, keyboard behaviour, scroll behaviour, zoom and pan, sticky regions, tooltips, timings, easing curves and transition durations.
- **The new chat modal with its preview sidebar.** Its layout, its sidebar preview, how it opens, closes, resizes and scrolls, and every state it shows.
- **How the live pane moves from the top to the bottom.** The exact transition, timing and easing. Reproduce it frame for frame, not approximately.
- **All the new filtering and visualization modes and options.** Every filter, toggle, mode (including Gantt and feature focus), menu, option and the behaviour of each one.
- **The background noise in the live view.** The texture, grain and noise visible in the live view background are part of the design. Reproduce them exactly: same pattern, scale, opacity, blending and animation, if it animates.

If an element exists in the design, it exists in the product, and it looks and behaves the same.

## Reuse the design's code, organised for the dashboard

**Reuse as much of the design's own code as possible:** its CSS (`assets/build.css`), its JavaScript (`assets/build.js`), its markup and its assets. Reusing the exact CSS values, keyframes and DOM structure is the most reliable way to get a pixel-perfect result. Re-deriving them by eye is how drift starts.

Clean the code up and organise it so it fits the dashboard's structure:
- LiveView components and hooks;
- CSS split into the dashboard's stylesheet conventions and aiur-style tokens;
- assets in `src/priv/static`;
- no dead mock code;
- mock data replaced by real data.

Restructuring is welcome. **Changing the rendered result is not.** Organising must never change what the user sees or how it behaves.

## How "done" is verified

- **Visual comparison.** Render the design file and the dashboard at the same viewport (desktop and mobile widths, light and dark) with the same fixture data. Compare them with screenshots, using the existing Playwright harness under `src/browser/` and `website/tests/visual.spec.ts` as the pattern. Any visible difference is a failing check until Kevin approves it.
- **Motion.** Record the live-pane top-to-bottom transition, the chat modal open and close, the mode switches, and the background noise in both the design and the product, and compare them.
- **Interaction parity.** Exercise every filter, mode and option in both and confirm identical behaviour.
- **Kevin signs off on the side-by-side comparison** before MP-E8 counts as done. That sign-off is DESIGN-E8's acceptance gate.

## Getting the code into this branch

The design source files are:
- `Aiur Dashboard.html`, about 370 KB: the current design. `Aiur Dashboard (pre-build-merge).html` is the version from before the merge, kept for reference only.
- `assets/build.css`, about 110 KB, and `assets/build.js`, about 131 KB: the new home page's styles and behaviour.
- The assets the page imports: `assets/aiur-logo.png`, `assets/analytics.js`, `assets/claude-symbol.svg`, `assets/claude-token.svg`, `assets/codex-color.svg`, `assets/codex-token.svg`, `assets/deepseek-logo.png` and `assets/kimi-logo.png`.

Put them under [`design-source/`](design-source/), keeping the project's relative paths, so the HTML opens directly in a browser. **This copy is the reference implementation. Do not edit it.** If the design changes, re-import it from Claude Design and note the date and the source file's etag in `design-source/IMPORTED.md`.

## Priority (unchanged)

Kevin's decisions stand (see [decisions.md](decisions.md) E8-D14 and [../../context-and-decisions.md](../../context-and-decisions.md) D1–D2):
- **MP-E1 (build queue)** ships first, before the refactor, on a seam. It is CLI-only, and its dashboard view is folded into MP-E8.
- **MP-E8 (this page)** follows in **wave 0b**, also before the refactor and on a seam, so the refactor moves it rather than rewriting it.
- **The refactor (MP-R1–R7)** comes after those, then the other features.

**Work has not started.** Implementation waits for an explicit go from Kevin. DESIGN-E8's design input is now provided by the Claude Design project above. Its final acceptance remains Kevin's sign-off on the side-by-side comparison.
