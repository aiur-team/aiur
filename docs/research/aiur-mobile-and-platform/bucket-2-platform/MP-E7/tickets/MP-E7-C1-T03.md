---
ticket_id: MP-E7-C1-T03
feature_id: MP-E7
chunk_id: MP-E7-C1
bucket: 2-platform
title: "Khala: publish the listener package by listener-v* tag through the existing release-npm.yml"
status: blocked
repo: khala (cross-repo)
khala_ref: origin/main 99e72a43
wave: 3
blocked_by: [DESIGN-E7, E7-D1, MP-E7-C1-T05, OWNER-NPM-FIRST-PUBLISH]
prior_units: []
prior_boundaries: []
prior_features: [integrations-43]
prior_findings: []
size_owner: n/a (Khala repository)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C1-T03 — Publish the listener package

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E7 / C1. **Cross-repo: Khala.**
- **User value:** aiur pins an immutable, versioned spec instead of copying
  files from another repository's `main`.
- **Deliverable:** `packages/listener` becomes publishable (`private` removed,
  build to plain ESM, `files` list, version `1.0.0`), and
  `.github/workflows/release-npm.yml` publishes it on a `listener-v<semver>` tag
  (and by `workflow_dispatch` dry run). `packages/agent/docs/releasing.md` gains
  a "Releasing the listener spec" section.
- **Non-goals:** no change to the `khala-cli` or `khala-opencode` release
  channels.

## Dependencies and blockers

- DESIGN-E7, **E7-D1** (also fixes the npm package name), MP-E7-C1-T05.
- **OWNER-NPM-FIRST-PUBLISH** (owner action, Kevin or the Khala owner): npm
  trusted publishing can only be configured on an existing package, so the
  first version is published by hand from an npm account, exactly as
  `packages/agent/docs/releasing.md` ("One-time npm setup") documents for
  `khala-cli`. Until then the workflow's dry run is the only automated proof.
- Successor: aiur MP-E7-C1-T04.

## Verified starting point (Khala `origin/main` 99e72a43)

- `release-npm.yml` triggers on `push: tags: ["v*"]` and `workflow_dispatch`
  (:20-33). Header comment (:5-10): npm OIDC trusted publishing matches the
  **workflow filename**, so a separate publishing workflow or reusable-workflow
  indirection "is rejected (npm/documentation#1755)". The listener job must
  therefore live in this same file.
- The `v*` channel resolves the version from
  `packages/agent/npm/package.json` and refuses a tag that disagrees (:55-67);
  a `listener-v*` tag must take a separate resolution step or it would fail
  this check.
- The workflow already publishes a second package (`khala-opencode`) with its
  own "skip when no placeholder exists" guard (`publish-opencode`, :264-311); the listener job
  follows that model.
- Publishing requires npm ≥ 11.5.1 for OIDC (:204).
- Node in CI is `.node-version` = `22.23.2`.

## Chosen design

- Tag pattern `listener-v*`; the workflow resolves channel `listener-stable`
  when `GITHUB_REF` matches `refs/tags/listener-v*`, reads the version from
  `packages/listener/package.json`, and requires tag == version.
- Separate jobs `listener-build` (build, `generate-spec --check`, test, `npm pack`)
  and `listener-publish` (dry-run OIDC assertion, publish, poll registry), gated
  so a `v*` tag never runs them and a `listener-v*` tag never runs the CLI jobs.
- Build: esbuild to ESM targeting `node18`; ship `dist/`, `spec/v1/**`,
  `README.md`, `LICENSE`. `engines.node: ">=18"` (RQ-E7-5, see C1-T01).
- Semver policy (contract §11): a new mode or support status is a **major**;
  a new optional field is a major too while Khala's decoders stay strict
  (C1-T05 finding); goldens-only fixes are patch.

## Implementation steps

1. `packages/listener/package.json`: remove `private`, set `name` per E7-D1, `version: "1.0.0"`, `files`, `exports` for `dist` and `./spec/*`, `publishConfig.access: public`, `scripts.build`.
2. `packages/listener/scripts/build.mjs` (esbuild, already a Khala devDependency via `@khala/agent`).
3. Extend `release-npm.yml`: add `"listener-v*"` under `on.push.tags`; extend the `setup` resolve step; add the two jobs modelled on the `khala-opencode` steps (`publish-opencode`, :264-311).
4. Document the procedure, including the one-time hand publish, in `packages/agent/docs/releasing.md`.

## Non-happy paths

- Tag/version mismatch → setup fails before any publish (same rule as :62-67).
- Version already on the registry → fail early (same as :81-90).
- OIDC exchange not attempted → dry-run step fails (same assertions as :219-232).
- A `listener-v*` tag must not trigger `khala-cli` publication; a test run of
  `workflow_dispatch` with `channel=dry-run` on a branch proves the gating.

## Compatibility and rollout

- New package only. Rollback: `npm deprecate <name>@1.0.0` (npm forbids
  unpublish after 72 h); aiur pins by version and sha256, so a deprecated
  version does not change aiur behaviour.

## Verification

```sh
pnpm --filter @khala/listener build && (cd packages/listener && npm pack --dry-run)
gh workflow run release-npm.yml --repo aiur-team/khala -f channel=dry-run   # owner-run; shows OIDC assertion
```

- Manual: after the owner's first hand publish and trusted-publisher setup,
  push `listener-v1.0.0`; expect `listener-publish` green, `khala-cli` jobs
  skipped, and `npm view <name>@1.0.0` to list `spec/v1/MANIFEST.json`.
- Workflow security: Khala's workflow lint (if any) passes; no new secrets.

## Completion and handoff

- [ ] Package publishable; tarball contains `dist/` and `spec/v1/`.
- [ ] `release-npm.yml` publishes on `listener-v*` only.
- [ ] `releasing.md` documents it.
- [ ] `listener-v1.0.0` published (owner-run step recorded in the PR).
- Dependents: MP-E7-C1-T04 (aiur vendoring). aiur ships no Node hook (MP-E7-C6 renders in Elixir), so `aiur-cli` does not depend on the package.
