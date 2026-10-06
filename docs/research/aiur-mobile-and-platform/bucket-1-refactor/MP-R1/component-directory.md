# MP-REQ4: the public component directory page

Part of the [MP-R1 plan](plan.md), chunk MP-R1-C10. Decision D20: the page goes live
**after** the refactor and is generated from R1's final component map. Owner design
questions are in [DESIGN-R1](../../owner-design-tasks/DESIGN-R1.md).

## 1. Verified starting point (`45a290e3`)

- Docs site: VitePress, `website/docs-app/`, resolved `vitepress@1.6.4`
  (`website/docs-app/bun.lock:569`), base `/docs/`, published at `aiur.team/docs`.
- Sidebar: `website/docs-app/.vitepress/config.ts:105-171`. Aiur's sidebar (`'/'`,
  lines 126-170) has groups Introduction, Interfaces, Concepts, APIs, Reference.
  Archon and Khala have their own path sidebars (`/archon/`, `/khala/`), and the three
  products are defined once in `.vitepress/products.ts`.
- AGENTS.md: "A genuinely new page must also be added to the sidebar ... or nobody can
  reach it."
- Docs checks: `scripts/check-config-docs.py` runs in the **required** `lint` job of
  `.github/workflows/ci.yml` (line 262), deliberately, because "a drift gate nobody has
  to satisfy guards nothing". `website/docs-app/scripts/check-cli-reference.sh` checks
  the CLI page against the launcher and parser.
- `.github/workflows/website.yml` builds the docs, but triggers **only** on
  `website/**` and its own path. A manifest outside `website/` would not rebuild the
  docs when it changes unless that trigger list is extended.
- Research cannot be linked publicly: PR #2921 removed refactor research from `main`.
  The page must stand on its own.

## 2. Recommendation

| Question | Recommendation | Rejected alternatives |
|---|---|---|
| Data source | One machine-readable manifest at the repository root, `components.json`, validated by `components.schema.json`. The same file drives the dependency checker (MP-R1-C1), so the page cannot describe a component the checker does not enforce. | (a) Hand-written Markdown table: drifts. (b) Generate from Elixir module attributes: misses non-Elixir components (sidecar, mobile, launcher). (c) A file under `website/`: puts code ownership in the docs tree and the checker would read docs. |
| Page location | `website/docs-app/reference/components.md`, sidebar group **Reference**, item "Components", after "Optional Optimizations". | A new top-level group: more prominent but adds a group for one page; offered as DESIGN-R1 Q2. |
| Rendering | VitePress build-time data loader `website/docs-app/reference/components.data.ts` that reads `../../../components.json` in `load()` and returns only public fields. Data loaders run only at build time and are serialized into the bundle as JSON (vitepress.dev/guide/data-loading, accessed 2026-10-06, VitePress 1.x; repo pins 1.6.4). A Vue component in `.vitepress/theme/components/` renders the table. | Pre-generated Markdown committed to the repo: a second copy to keep in sync. |
| Planned features | A top-level `features` array in the manifest (MP-R1-C10-T1), because a planned feature often extends an existing component rather than adding one. Each entry has a one-line public summary, the feature ID (private), `extends`/`adds` component IDs and a `public` flag. Components that do not exist yet use `status: planned`. Rendered in a separate "Planned" section, never mixed into the installed-component table. No dates. | Linking research docs (not on `main`); a separate roadmap file (a second source). |
| Sync check | `scripts/check-components.py` in the required `lint` job (same pattern as `check-config-docs.py`), plus `components.json` added to `website.yml` `paths` so a manifest change rebuilds the docs. | Docs-workflow-only check: does not run on source PRs. |

Phase C result (MP-R1-C10-T2): resolved. In VitePress 1.6.4 a `watch` path that starts
with `.` is resolved against the loader file with no project-root check, and `load()` is
plain Node, so the loader reads `../../../components.json` directly. The byte-equal copy
fallback is not needed.

## 3. Manifest fields (public subset marked P)

| Field | P | Meaning |
|---|---|---|
| `id` | P | Component ID from [component-map.md](component-map.md) |
| `name` | P | Display name |
| `summary` | P | One sentence: what it does for an operator |
| `status` | P | `core` · `optional` · `experimental` · `planned` · `deprecated` |
| `layer` | – | L0–L5, used by the checker |
| `kind` | P | `in-app` · `package` · `repository` · `client` |
| `install` | P | How to get it: "included", npm package name, or setup page link |
| `requires` / `optional` | P | Component IDs (rendered as links) |
| `capabilities` | P | Capability IDs it provides (from the identity-and-capabilities contract) |
| `config` | P | Config sections and env var names it owns (names only), linking to `reference/configuration` |
| `docs` | P | Docs page path(s) |
| `paths` | – | Source globs, for the checker |
| `facades` | – | Public modules, for the checker |
| `feature_id` | P (planned only) | `MP-…` ID, shown only if DESIGN-R1 approves exposing IDs |
| `allowlist` | – | Ratcheting dependency violations |

## 4. What each rendered entry shows

Name, status badge, one-line summary, how to install or enable it, what it requires
(and which optional components unlock more), the capabilities it provides, the config
keys and environment variables it owns, and a docs link. Planned entries show name,
summary and "planned" only. Final layout, wording and badges are DESIGN-R1.

## 5. Checks (`scripts/check-components.py`)

1. The manifest validates against `components.schema.json`.
2. Every `paths` glob matches at least one tracked file, and every tracked file under
   `src/lib`, `packages/` and `packaging/` belongs to exactly one component (orphans
   fail; vendored and generated paths are listed explicitly with a reason, as
   `EXEMPT` does in `check-config-docs.py`).
3. Every `docs` path exists in `website/docs-app`.
4. Every `config` section name appears in `reference/configuration.md` (reuse
   `check-config-docs.py`'s resolver rather than re-parse).
5. Every capability ID exists in the capability table.
6. The sidebar in `config.ts` links `/reference/components`.
7. The `lint` step is skipped on docs-only PRs (`ci.yml:260`,
   `docs_only != 'true'`), so a website-only PR could delete a page the manifest
   links. Run the docs checks (`check-components.py --docs`) in the required `workflow security` job, which runs on every PR. `website.yml`'s `guards` job is not a required check (MP-R1-C10-T4).
8. A test script `scripts/test-check-components.sh` guards the checker (pattern:
   `scripts/test-check-config-docs.sh`), with a fixture that must fail for each rule
   (AGENTS.md "tests must fail without the production change").

## 6. Going live (D20)

- MP-R1-C10-T1 to T3 (manifest public fields, loader, page) can merge behind a
  `noindex` page that is **not** in the sidebar, so the docs build exercises it.
- MP-R1-C10-T4 (sidebar entry and publish) is blocked on: S16 merged, the final
  plan-refresh run (S17), and DESIGN-R1 approved.
- After go-live, AGENTS.md "Where each thing is documented" gains a row: "New or
  changed component → `components.json` (the page regenerates)". That is the docs
  rule change; it ships in the same PR.
