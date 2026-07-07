# T-055: Install VitePress docs package

**Phase:** 5
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:5` `complexity:2`

## Problem / context

Success criterion 5 of the refactor (`docs/refactor/00-overview.md:25-26`)
requires a docs site live at `/docs` (VitePress) with quick-start,
configuration, concept, and skills pages. The binding framework decision is
recorded in `docs/refactor/research-docs-framework.md`: **VitePress, as a
SEPARATE docs package that builds into `website/dist/docs` and is served at
aiur.team/docs** (memo lines 1-3, 12-19). This ticket lays that foundation —
it installs the docs package and scaffolds a minimal landing page plus nav
only. The content pages are filled by the dependent tickets T-056
(quick-start + configuration), T-057 (concept pages), and T-058 (skills
page), all of which `Depends-on: T-055`.

The hard requirement is isolation: the docs package must not touch the
marketing site's guarded surfaces (`website/src/dashboard.ts`,
`website/src/simData.ts`, `website/src/terminal.ts`, `website/src/styles.css`),
must not change `website/tsconfig.json`'s `include` set (currently
`["src", "vite.config.ts"]`), and must leave the golden snapshot
(`website/scripts/dashboard-golden.json`, verified by `npm run assert`)
byte-identical. The only marketing-side edit is extending the Netlify build
command in `website/netlify.toml` to build the docs after the marketing site
(a docs build failure must fail the whole deploy).

## Scope (exact)

The docs package lives at `website/docs-app/` (research memo line 13). It is
built and deployed with **bun** (Netlify's package manager; FI-SITE-032), so
its only committed lockfile is `website/docs-app/bun.lock` — do NOT create a
`package-lock.json` inside `website/docs-app/`.

1. Create `website/docs-app/package.json` with EXACTLY this content:

   ```json
   {
     "name": "aiur-docs",
     "private": true,
     "version": "0.0.0",
     "type": "module",
     "scripts": {
       "dev": "vitepress dev .",
       "build": "vitepress build .",
       "preview": "vitepress preview ."
     },
     "devDependencies": {
       "vitepress": "^1.6.3"
     }
   }
   ```

2. Create `website/docs-app/tsconfig.json` with EXACTLY this content (this is
   the docs package's OWN tsconfig; it is separate from and does not extend
   `website/tsconfig.json`):

   ```json
   {
     "compilerOptions": {
       "target": "ESNext",
       "module": "ESNext",
       "moduleResolution": "bundler",
       "lib": ["ESNext", "DOM"],
       "strict": true,
       "noEmit": true,
       "skipLibCheck": true,
       "types": ["vitepress"]
     },
     "include": [".vitepress/**/*.ts"]
   }
   ```

3. Create `website/docs-app/.vitepress/config.ts` with EXACTLY this content.
   `base: '/docs/'` and `outDir: '../dist/docs'` are the two load-bearing
   values (memo line 15); `outDir` is resolved relative to the docs root
   (`website/docs-app/`), so `../dist/docs` writes into `website/dist/docs`,
   which never collides with the marketing site's `website/dist/assets/` or
   `website/dist/index.html`:

   ```ts
   import { defineConfig } from 'vitepress'

   export default defineConfig({
     title: 'Aiur',
     description: 'Documentation for Aiur',
     base: '/docs/',
     outDir: '../dist/docs',
     cleanUrls: true,
     themeConfig: {
       nav: [{ text: 'Home', link: '/' }],
       sidebar: [
         {
           text: 'Introduction',
           items: [{ text: 'Overview', link: '/' }]
         }
       ],
       socialLinks: [
         { icon: 'github', link: 'https://github.com/its-everdred/aiur' }
       ]
     }
   })
   ```

4. Create `website/docs-app/index.md` with EXACTLY this content (a minimal
   landing page only; do NOT author quick-start, configuration, concept, or
   skills content — those are T-056/T-057/T-058):

   ```md
   ---
   layout: home
   hero:
     name: Aiur
     text: Documentation
     tagline: Coordinate coding agents via events.
   ---

   Documentation is under construction. Content pages arrive in follow-up
   tickets.
   ```

5. Create `website/docs-app/.gitignore` with EXACTLY this content (keeps
   VitePress build/cache artifacts out of git; the docs output at
   `website/dist/docs` is already covered by `website/.gitignore`'s `dist`
   entry):

   ```
   node_modules
   .vitepress/cache
   .vitepress/dist
   ```

6. Generate the lockfile: from `website/docs-app/`, run `bun install`. This
   resolves VitePress and writes `website/docs-app/bun.lock`. Commit
   `website/docs-app/bun.lock`. If a `website/docs-app/package-lock.json`
   appears, delete it before committing — bun is the only package manager for
   this package.

7. Modify `website/netlify.toml` to extend the build command so the marketing
   site builds FIRST and the docs build SECOND, chained with `&&` so a docs
   failure fails the deploy loudly (memo line 15). Change ONLY the `command`
   line; leave `base`, `publish`, and `[build.environment]` unchanged. The
   file becomes EXACTLY:

   ```toml
   [build]
     base = "website"
     command = "bun install && bun run build && cd docs-app && bun install && bun run build"
     publish = "dist"

   [build.environment]
     NODE_VERSION = "20"
   ```

   (`base = "website"` means the command runs from `website/`; the first
   `bun install && bun run build` builds the marketing site into
   `website/dist`, then `cd docs-app && bun install && bun run build` builds
   the docs into `website/dist/docs`. `publish = "dist"` still publishes the
   combined `website/dist` tree.)

8. Verify the docs build locally from `website/docs-app/`:
   `bun run build` must exit 0 and produce `website/dist/docs/index.html`.
   Then confirm the marketing guards are untouched (Verification section).

## Files

- Create: `website/docs-app/package.json`
- Create: `website/docs-app/tsconfig.json`
- Create: `website/docs-app/.vitepress/config.ts`
- Create: `website/docs-app/index.md`
- Create: `website/docs-app/.gitignore`
- Create: `website/docs-app/bun.lock` (generated by `bun install`, then committed)
- Modify: `website/netlify.toml`
- Test: None (no Elixir modules; the marketing site's existing
  `website/scripts/assert-sim.ts` golden guard must stay byte-identical — see
  Characterization-tests)

## Out of scope

- `website/src/dashboard.ts`, `website/src/simData.ts`, `website/src/terminal.ts`,
  `website/src/styles.css`, and every other file under `website/src/` — do
  not read-for-edit, reformat, or touch.
- `website/tsconfig.json` — its `include` set stays `["src", "vite.config.ts"]`;
  the docs package has its OWN tsconfig and must not be added here.
- `website/package.json`, `website/package-lock.json`, `website/bun.lock`,
  `website/vite.config.ts` — no marketing dependency, script, or config changes.
- `website/scripts/*` — especially no golden regeneration
  (`website/scripts/gen-golden.ts` is deliberate-only).
- `.github/workflows/website.yml` — the CI docs-build wiring is a separate
  concern (the docs package is bun-only and the existing website CI is
  npm/`npm ci`-based); do not edit it in this ticket. Netlify (via
  `netlify.toml`) is the docs deploy gate this ticket establishes.
- Any docs content beyond the single scaffold landing page — no quick-start,
  configuration, concept, or skills pages (T-056/T-057/T-058).
- Any custom VitePress theme, plugin, search backend (VitePress ships offline
  search built-in — memo line 7; do not add Algolia), or i18n.

## Inventory-IDs

- FI-SITE-032 — Netlify deploy of aiur.team (this ticket modifies
  `website/netlify.toml`'s build command; `website/dist` stays gitignored and
  built fresh with bun).
- FI-SITE-028 — golden snapshot byte-identity (guard that MUST stay green /
  byte-identical; the docs package must not disturb it).
- FI-SITE-029 — `npm run assert` invariant suite (guard that must still pass
  all 6 checks after this change).
- FI-SITE-031 — typecheck + build guards (the marketing
  `npm run typecheck` / `npm run build` must still pass unchanged).

## Characterization-tests

None under `src/test/aiur/regression/` — that tree is Elixir-only and this
ticket is website-only. The website's anti-regression guard is
`website/scripts/assert-sim.ts` (run via `npm run assert`), including the
byte-identical 88-col golden snapshot `website/scripts/dashboard-golden.json`
(FI-SITE-028); it must keep passing all 6 checks and the golden must stay
byte-identical.

## Acceptance criteria

- `website/docs-app/package.json` exists; `grep -F '"name": "aiur-docs"'` and
  `grep -F '"vitepress"' website/docs-app/package.json` both match.
- `website/docs-app/tsconfig.json` exists and is a distinct file from
  `website/tsconfig.json`.
- `website/docs-app/.vitepress/config.ts` exists;
  `grep -F "base: '/docs/'" website/docs-app/.vitepress/config.ts` and
  `grep -F "outDir: '../dist/docs'" website/docs-app/.vitepress/config.ts`
  both match.
- `website/docs-app/index.md` and `website/docs-app/.gitignore` exist.
- `website/docs-app/bun.lock` exists and is committed;
  `website/docs-app/package-lock.json` does NOT exist
  (`test ! -e website/docs-app/package-lock.json`).
- `website/netlify.toml` build command builds marketing then docs:
  `grep -F 'bun run build && cd docs-app && bun install && bun run build' website/netlify.toml`
  matches; `grep -F 'base = "website"'`, `grep -F 'publish = "dist"'`, and
  `grep -F 'NODE_VERSION = "20"'` all still match.
- `cd website/docs-app && bun install && bun run build` exits 0 and
  `website/dist/docs/index.html` exists afterward.
- The marketing golden is byte-identical:
  `git diff --quiet v2...HEAD -- website/scripts/dashboard-golden.json` (empty
  diff), and `git diff --name-only v2...HEAD -- website/src website/tsconfig.json`
  is empty (guarded surfaces untouched).
- `git diff --name-only v2...HEAD` lists ONLY: the six
  `website/docs-app/*` paths above and `website/netlify.toml`.
- Each new file is under 200 lines (the config is declarative — no functions
  exceed 20 logic lines; there are no extracted Elixir modules requiring new
  tests).

## Verification
### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```
Website gate (this ticket touches `website/`; run from repo root):
```
cd website && npm run typecheck && npm run build && npm run assert
```
Docs package gate (its own build command; run from repo root):
```
cd website/docs-app && bun install && bun run build
```
`npm run assert` must print all-OK for all 6 checks (golden byte-identical).
The docs build must exit 0 and write `website/dist/docs/index.html`.

### At-merge (reviewer)

- Check: `cd website && npm run assert` prints all-OK and exits 0 — the
  golden snapshot (FI-SITE-028/029) is unchanged.
- Check: `cd website/docs-app && bun install && bun run build` exits 0 and
  `ls website/dist/docs/index.html` succeeds.
- Confirm guarded surfaces untouched:
  `git diff v2...<branch> -- website/src website/tsconfig.json website/scripts` is
  empty.
- Confirm the marketing build still works: `cd website && npm run build`
  exits 0.
- Confirm `website/netlify.toml` builds marketing before docs and chains with
  `&&` (a docs failure fails the deploy).
- Confirm no `package-lock.json` was committed under `website/docs-app/`.
- Spot-check the rendered landing page (open `website/dist/docs/index.html`
  or `cd website/docs-app && bun run preview`): the VitePress home hero renders
  with title "Aiur" and the "Home" nav item is present. No content pages are
  expected yet (T-056/T-057/T-058 fill them).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
