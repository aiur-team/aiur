---
ticket_id: MP-R1-C1-T04
feature_id: MP-R1
chunk_id: MP-R1-C1
bucket: 1-refactor
title: TypeScript import walker for packages/* and the R-client rule
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T01]
prior_units: []
prior_boundaries: ["SD #35 (sidecar)", "#40 docs"]
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C1-T04 — TypeScript import walker and R-client

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C1. Step S0 (client half).
- **User value:** none at runtime. Guarantees that clients (Stream Deck sidecar now;
  `packages/aiur-contracts` and `packages/aiur-mobile` later) never import daemon
  internals, so they can be built, released and moved independently (brief R1, KD4).
- **Deliverable:**
  1. `scripts/components/ts-imports.mjs` — walks `packages/*/src/**/*.{ts,tsx,mts,cts,js,mjs}`
     with the TypeScript compiler API (pattern of Khala `scripts/check-boundaries.mjs`,
     Khala commit `d898e6b8`) and prints `path\tspecifier\tresolved` rows.
  2. `scripts/components/package.json` + `package-lock.json` pinning `typescript`
     (same major as `packages/streamdeck/package.json:19`, `^5.7.2`).
  3. Rule **R-client** in `check-components.py`: an L5 package may import only (a) files
     inside its own package directory, (b) npm dependencies it declares, (c) node
     builtins, (d) `packages/aiur-contracts` once it exists. It may never resolve into
     `src/`, `packaging/` or another package. A computed `import()`/`require()` fails as
     unanalyzable.
  4. Rule **R-reverse-resource**: an Elixir `@external_resource` path that points into
     `packages/` is reported (it is the daemon reading client source at compile time).
     Today's one case is allowlisted.
- **Non-goals:** `new URL("…", import.meta.url)` asset references (they stay inside the
  package by construction); type-checking; ESLint.

## Dependencies and blockers

- DESIGN-R1 §1; C1-T01. Independent of T02/T03 (may run in parallel).
- **Dependents:** C3-T06 (`aiur-contracts` must pass R-client), MP-R6 (breaks the
  allowlisted reverse edge), MP-N1 (mobile package).

## Verified starting point (`45a290e3`)

- TypeScript/JS sources: 162 files under `packages/streamdeck`, 9 under
  `packages/aiur-style`. Root `package.json` has no dependencies or workspaces; the
  sidecar pins `typescript` `^5.7.2` as a devDependency.
- A naive regex over `from "<x>"` finds false positives in comments:
  `packages/streamdeck/src/art/gradient.ts:71` (`from "to top"`) and
  `src/art/segments.ts:14` (`from "zero usage"`). This is why the walker uses the
  TypeScript AST, as Khala does.
- Reverse edge: `AiurWeb.StreamdeckKeyFaceContract` reads
  `packages/streamdeck/src/key-face-contract.json` through `@external_resource` and
  `File.read!` (`src/lib/aiur_web/streamdeck_key_face_contract.ex:11-13`). MP-R6 owns
  breaking it (component-map finding 10).
- Lint job has Node (it runs `node packaging/scripts/check-platform-drift.mjs`,
  `ci.yml` lint job last step) but no npm install.

## Chosen design

- The checker runs `npm ci --prefix scripts/components --ignore-scripts` once (cached by
  lockfile hash in CI via `actions/cache`, pinned by SHA like other actions), then
  `node scripts/components/ts-imports.mjs <root>`.
- Resolution: relative specifiers by path; bare specifiers → `node_modules` package name
  (`@scope/name` or `name`) checked against the importing package's `dependencies`,
  `devDependencies`, `peerDependencies`; `node:` and builtin names allowed.
- Test files (`*.test.*`, `test/`) are walked too: a test importing `src/` of the
  daemon is the same leak.
- Ownership of `packages/*` comes from C1-T01; each package is one L5 (or non-runtime)
  component. `aiur-style` is non-runtime and gets the same rule.

## Implementation steps

1. Add `scripts/components/package.json` (`private: true`, only `typescript`) and
   lockfile.
2. Write `ts-imports.mjs` (< 200 lines): `ts.createSourceFile`, visit
   `ImportDeclaration`, `ExportDeclaration`, `ImportEqualsDeclaration`, `ImportTypeNode`,
   `import()` and `require()` calls; emit `<computed>` for non-literal arguments.
3. Extend `check-components.py`: run it, apply R-client; grep `@external_resource`
   attribute values in `src/lib` and apply R-reverse-resource.
4. Allowlist the streamdeck reverse edge with reason `MP-R6 owns`.
5. CI: in the lint step's job add the `actions/cache` + `npm ci` lines before the
   checker step; update `scripts/test-workflow-security.sh` expectations if it pins the
   list of allowed actions.

## Non-happy paths

- `npm ci` fails (registry down) → step fails loudly; there is no skip. Retry is the CI
  rerun path.
- New package without `package.json` → exit 2 (cannot resolve its dependencies).
- Symlinked `node_modules` paths → resolution uses `realpath`.

## Compatibility and rollout

No runtime change. Adds ~15 s (estimate; record the measured value in the PR body)
for `npm ci` on a cold cache. Rollback: revert.

## Verification

| Test | Fixture | Expected |
|---|---|---|
| `relative_inside_package_passes` | `packages/a/src/x.ts` imports `./y.js` | exit 0 |
| `import_into_src_fails` | imports `../../../src/lib/foo.js` | exit 1 `R-client` |
| `sibling_package_fails` | `packages/a` imports `../../b/src/z.js` | exit 1 |
| `undeclared_npm_dep_fails` | bare `left-pad` not in package.json | exit 1 |
| `computed_import_fails` | `` import(`./${name}.js`) `` | exit 1 `unanalyzable` |
| `comment_mention_ignored` | `// from "to top"` | exit 0 |
| `contracts_import_allowed` | `packages/aiur-contracts` present and declared | exit 0 |
| `external_resource_into_packages_reported` | `.ex` with `@external_resource "../../packages/a/x.json"` | exit 1 unless allowlisted |

These run in `test-check-components.sh --with-node` inside the lint job (Node present,
fixtures need the pinned `typescript`).

Mutation check: treat every relative specifier as inside the package → `sibling_package_fails`
and `import_into_src_fails` fail; skip `CallExpression` handling → `computed_import_fails`
fails.

Real tree: exit 0 at the head with exactly one allowlisted reverse edge.

## Completion and handoff

- [ ] Walker and pinned toolchain committed; lint step green; measured runtime in PR body.
- [ ] Streamdeck reverse edge allowlisted with owner MP-R6.
- [ ] No docs-site change.
- **Dependents:** C3-T06, MP-R6 (key-face contract), MP-N1-C* (mobile package).
