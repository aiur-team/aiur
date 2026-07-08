# U3 Docs-framework decision memo (2026-07-06)

**Decision: VitePress, as a separate docs package building into `website/dist/docs` (served at aiur.team/docs).**
Runner-up: Astro Starlight (better raw static output/zero-config authoring, but two 2026 yellow flags: open Bun dependency-resolution issue in Astro; llms.txt support removed from core → community plugin).

## Why VitePress
- Vite-native — same bundler family as the existing site; documented bun install path; minimal "second toolchain" overhead.
- Built-in offline search (no Algolia) → self-contained static output.
- Markdown-first, low config → agent-friendly authoring.
- Docusaurus = fallback only if versioned docs become a hard requirement; Fumadocs misaligned (React/Next-flavored).

## Integration shape (High-viability per site-constraints analysis)
- New separate package (e.g. `website/docs-app/` or top-level docs dir — NOT repo-root `docs/`, which is taken by engineering docs) with own package.json + tsconfig + lockfile.
- outDir → `website/dist/docs`, base `/docs/` (no collision with dist/assets/; no _redirects needed; static-only hosting preserved).
- Netlify command in website/netlify.toml extended: marketing build FIRST, then docs build — a docs failure fails the deploy loudly.
- Zero contact with guarded surfaces: website/src/dashboard.ts / simData.ts / terminal.ts / styles.css untouched; golden snapshot (npm run assert) unaffected; tsconfig include set unchanged.
- New deps install cleanly under bun; bun.lock in the docs package only.
- Theme: honor data-theme dark default / localStorage "aiur-theme" as a soft goal (VitePress theming can approximate; don't fight it).

## Hard constraints checklist (from site analysis — put in the docs tickets)
1. Golden snapshot byte-identical; regeneration deliberate-only (scripts/gen-golden.ts).
2. Netlify: base=website, bun install && bun run build, publish=dist, NODE 20, deploys from main.
3. All three manual guards keep passing unchanged: npm run typecheck, npm run assert, npm run build.
4. No runtime deps / client JS / global CSS leaking into the marketing bundle.
5. Docs output generated at build, never committed (dist gitignored).
6. Website CI job pre-ticket (decision 14) covers: typecheck + assert + build (+ docs build once added).
