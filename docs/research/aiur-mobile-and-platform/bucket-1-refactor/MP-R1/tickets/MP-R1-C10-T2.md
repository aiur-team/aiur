---
ticket_id: MP-R1-C10-T2
feature_id: MP-R1
chunk_id: MP-R1-C10
bucket: 1-refactor
title: Build-time VitePress data loader for the component directory, and an unlisted placeholder page
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C10-T1]
prior_units: [U8]
prior_boundaries: ["#40 docs-site"]
prior_features: []
prior_findings: []
size_owner: n/a   # ledger pinned at 465aca643; re-resolve at ticket start against the current U8 ledger (RC-23, MP-R1-C11-T2)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C10-T2 — Data loader and unlisted placeholder page

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C10 (MP-REQ4).
- **User value:** none visible yet. The docs build starts exercising the manifest →
  page path on every docs build, so the publish step (C10-T5) is a sidebar change, not
  a first-time integration.
- **Deliverable:**
  1. `website/docs-app/reference/components.data.ts` (PROPOSED): a VitePress build-time
     data loader that reads the root manifest and returns only public fields, in a
     typed, pre-grouped shape.
  2. `website/docs-app/reference/components.md` (PROPOSED): an **unlisted** page
     (`search: false`, `robots: noindex`, not in the sidebar) that imports the loader and
     renders a plain, unstyled list through a minimal Vue component. Final layout is
     C10-T3.
- **Non-goals:** the approved visual design (C10-T3), CI checks (C10-T4), sidebar entry
  (C10-T5), any change to `components.json` content (C10-T1).

## Dependencies and blockers

- **DESIGN-R1** (feature gate). This ticket depends only on DESIGN-R1 §1 (no runtime
  change) and §3 acceptance "the page goes live after the refactor" (D20); it renders
  nothing public in the sidebar, so it does not wait for the §3 layout answers.
- **MP-R1-C10-T1** (public fields and `features` array). For development the loader may
  be written against a fixture, but it merges after T1.
- **Concurrent:** C10-T4 (checks) and any C6–C9 move.

## Verified starting point (base `45a290e3`)

- Docs app: `website/docs-app/`, `"build": "vitepress build ."`
  (`website/docs-app/package.json` scripts), `vitepress@1.6.4` resolved
  (`website/docs-app/bun.lock:569`), `vue@3.5.39` (`bun.lock:573`).
- Config: `website/docs-app/.vitepress/config.ts` — `base: '/docs/'` (`:11`),
  `outDir: '../dist/docs'` (`:12`), `cleanUrls: true` (`:13`), dead-link ignore list
  (`:14`), local search (`:177`). No `srcDir`/`srcExclude`, so every `.md` under
  `website/docs-app/` is built.
- Theme: `website/docs-app/.vitepress/theme/index.ts` extends the default theme and
  registers `VPButton` globally; one custom component exists,
  `.vitepress/theme/components/ProductSwitcher.vue`.
- No `*.data.ts` loader exists in the docs app today
  (`git ls-tree -r --name-only 45a290e3 -- website/docs-app | grep data.` is empty).
- **RQ2 (can a loader read a file outside the docs source dir?) — resolved: yes.**
  Evidence from the installed VitePress 1.6.4 (`website/docs-app/node_modules/vitepress`
  in the live checkout, `package.json` `"version": "1.6.4"`), file
  `dist/node/chunk-D3CUZ4fa.js`:
  - `:44747` loaders match `/\.data\.m?(j|t)s($|\?)/`;
  - `:44782` the loader module is bundled by Vite's `loadConfigFromFile`, and in dev its
    imports are tracked as dependencies (`:44783-44786`);
  - `:44791-44793` each `watch` entry starting with `.` is resolved with
    `path.resolve(dirname(loader), p)` — no check against the project root;
  - `:44800-44803` the resolved patterns are globbed (ignoring only `node_modules` and
    `dist`), and `load(watchedFiles)` is called with absolute paths (`:44805`);
  - `:44809-44811` the result is serialized as `export const data = JSON.parse(...)`, so
    only what `load()` returns reaches the client bundle.
  Docs: https://vitepress.dev/guide/data-loading (accessed 2026-10-06, VitePress 1.x):
  loaders "run only in Node.js", `watch` globs are "relative to the loader file", and
  data is "serialized as JSON in the final bundle".
  **Conclusion:** `watch: ['../../../components.json']` (or `../../../components/*.json`
  if C1-T1 splits the manifest) plus `fs.readFileSync` in `load()` works in both
  `vitepress dev` and `vitepress build`, and only the returned public subset ships.
  The byte-equal-copy fallback in component-directory.md §2 is not needed.
- **Build environments that must see the repo root:**
  - CI: `.github/workflows/website.yml` `guards` job checks out the whole repository
    (`:31-32`) and builds the docs in `website/docs-app` (`:49-54`). The root file is
    present.
  - Netlify: `website/netlify.toml` sets `base = "website"` and runs
    `cd docs-app && bun install && bun run build`. The base directory is the working
    directory of the build; the repository checkout is complete
    (https://docs.netlify.com/configure-builds/overview/#definitions, accessed
    2026-10-06). Production deploys are manual from a local full checkout
    (`netlify.toml` comment: "build locally, then run `netlify deploy --prod --dir
    website/dist`"). Deploy previews: the `ignore` rule diffs only `.` relative to the
    base (`website/`), so a PR that changes only `components.json` builds **no** deploy
    preview. That is acceptable (CI still builds it, C10-T4), and recorded here so
    nobody reads a missing preview as a failure.

## Chosen design

### Loader contract

```ts
// website/docs-app/reference/components.data.ts  (PROPOSED)
import { readFileSync } from 'node:fs'
import { defineLoader } from 'vitepress'

export interface PublicComponent {
  id: string; name: string; summary: string
  status: 'core' | 'optional' | 'experimental' | 'planned' | 'deprecated'
  kind: 'in-app' | 'package' | 'repository' | 'client'
  install: { type: 'included' } | { type: 'npm'; package: string } | { type: 'setup'; docs: string }
  requires: string[]; optional: string[]; capabilities: string[]
  config: string[]; env: string[]; docs: string[]
}
export interface PlannedFeature { name: string; summary: string; extends: string[]; adds: string[] }
export interface DirectoryData { components: PublicComponent[]; planned: PlannedFeature[]; generatedFrom: string }

declare const data: DirectoryData
export { data }

export default defineLoader({
  watch: ['../../../components.json'],          // follow C1-T1's final layout
  load(files): DirectoryData { /* parse, project, sort, validate */ }
})
```

- **Projection (allow-list, not deny-list):** copy only the fields named in
  `PublicComponent`/`PlannedFeature`. `paths`, `facades`, `layer`, `allowlist`,
  `features[].id`, `public` and `shipped_in` are never returned. Feature IDs are
  dropped unless DESIGN-R1 Q4 approves showing them; if approved, C10-T3 adds the field
  to the projection deliberately.
- **Planned list:** `features.filter(f => f.public === true && f.shipped_in == null)`.
  Components with `status: planned` are excluded from `components` and appear only
  through the features that `adds` them.
- **Order:** by `name` (case-insensitive) inside each status; grouping for display is
  C10-T3.
- **Fail loudly:** if the manifest is missing, unparsable, or a required public field is
  absent, `load()` throws with the component ID. A failed loader fails
  `vitepress build`, which fails the `website / guards` job. Never return an empty list
  on error (AGENTS.md: unknown must not render as a plausible default).
- `generatedFrom`: the manifest's content hash (sha256, first 12 hex), shown in a page
  footnote so a reviewer can match the page to a commit.

### Placeholder page

```md
---
title: Components
search: false
head: [['meta', { name: 'robots', content: 'noindex' }]]
---
<script setup>
import { data } from './components.data'
import ComponentList from '../.vitepress/theme/components/ComponentList.vue'
</script>
<ComponentList :data="data" />
```

`search: false` excludes the page from local search: installed VitePress
`dist/node/chunk-D3CUZ4fa.js:40459` returns `""` for the page when
`env.frontmatter?.search === false`. The page is reachable by URL
(`/docs/reference/components`) but not linked, searched or indexed.

`ComponentList.vue` (PROPOSED, `.vitepress/theme/components/`) renders a `<ul>` of
name, status, summary and docs link, and a "Planned" `<ul>` with the empty-section
placeholder text "No planned features are listed yet." (final copy is DESIGN-R1 §3).

## Implementation steps

1. Add `components.data.ts` with the contract above; resolve the manifest path(s) from
   `files` (the `watch` result), not from a hard-coded absolute path.
2. Add `ComponentList.vue` with props `{ data: DirectoryData }`; no global registration
   (keep `theme/index.ts` unchanged).
3. Add `reference/components.md` with the frontmatter above.
4. Add a small Node test `website/docs-app/scripts/test-components-loader.mjs`
   (PROPOSED) that imports the loader's `load` via `vite-node`-free plain ESM: put the
   projection in a pure function `projectDirectory(manifestJson)` exported from
   `website/docs-app/reference/components-projection.mjs`, imported by both the loader
   and the test, so the test runs with `node --test` and no VitePress runtime.
5. Add a `package.json` script `"test:components": "node --test scripts/test-components-loader.mjs"`
   in `website/docs-app/`.

Estimated production change: ~150 lines (loader 40, projection 70, Vue 40).

## Non-happy paths

- **Manifest missing/corrupt:** build fails with the component ID (never an empty page).
- **Private field leak:** prevented by the allow-list projection; tested.
- **Unknown status value** (schema drift): loader throws; the checker (C10-T4) should
  have caught it first.
- **Dev server:** editing `components.json` hot-reloads the page via the `watch`
  handling (`chunk-D3CUZ4fa.js:44835-44847`).
- **Deploy preview missing for a manifest-only PR:** expected (see Verified starting
  point); CI build is the gate.
- **Privacy:** only public fields are serialized into the bundle; `env` contains names
  only (enforced by C10-T1's schema).

## Compatibility and rollout

- No runtime, config or CLI change. The page exists at an unlinked URL; robots
  `noindex` and `search: false` keep it out of discovery until C10-T5.
- Rollback: revert the three files.
- If C1-T1 splits the manifest into `components/*.json`, change `watch` to that glob;
  the projection merges the files in path order.

## Verification

`node --test` cases in `scripts/test-components-loader.mjs`:

| Test | Input | Expected | Fails without |
|---|---|---|---|
| `projects_only_public_fields` | component with `paths`, `facades`, `allowlist` | output keys equal the `PublicComponent` key set exactly | the allow-list projection (replace it with a spread) |
| `drops_feature_ids_and_flags` | feature with `id`, `public: true` | output has no `id`, `public`, `shipped_in` | same |
| `planned_lists_only_public_unshipped` | three features: public+unshipped, private, public+shipped | exactly one planned entry | the filter |
| `planned_component_hidden_from_components` | component `status: planned` | absent from `components` | the status filter |
| `missing_summary_throws` | component without `summary` | throws, message contains the ID | the validation (replace with a default `""`) |
| `empty_manifest_throws` | `{}` | throws | the guard (replace with `[]`) |

Commands:

```bash
cd website/docs-app            # in a terminal; agents use: env -C website/docs-app ...
bun install --frozen-lockfile
bun run test:components
bun run build                  # must succeed; then:
grep -c 'paths\|facades\|allowlist' ../dist/docs/reference/components.html   # expect 0
grep -rl 'reference/components' ../dist/docs/*.html ../dist/docs/**/*.html | grep -v 'reference/components.html'   # expect no sidebar links
```

Manual: `bun run dev`, open `http://localhost:5173/docs/reference/components`, confirm
the list renders, the page is absent from the sidebar, and a search for a component
name in the local search box does not return this page.

Mutation check: for each row, apply the "fails without" mutation in a worktree and
confirm the named test fails; restore and confirm green.

## Completion and handoff

- [ ] Loader, projection module, Vue list and unlisted page merged; `bun run build`
      green in `website / guards`.
- [ ] Built HTML contains no private manifest field (grep above).
- [ ] Page not in sidebar, not in local search, `noindex` present.
- [ ] Docs: no AGENTS.md row yet (C10-T5 adds it with the publish).
- **Dependents:** C10-T3 (styled rendering), C10-T5 (publish).
- **Sources:** https://vitepress.dev/guide/data-loading (2026-10-06);
  VitePress 1.6.4 installed source lines cited above;
  https://docs.netlify.com/configure-builds/overview/ (2026-10-06).
