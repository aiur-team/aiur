---
ticket_id: MP-N4-C2-T05
feature_id: MP-N4
chunk_id: MP-N4-C2
bucket: 3-mobile-watch
title: Relay packaging — container image, CI workflow, operator guide page
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C2-T02, MP-N4-C2-T03, MP-N4-C2-T04]
prior_units: []
prior_boundaries: [relay service (separate deployable)]
prior_features: [MP-R4 (provider boundary)]
prior_findings: [MP-Q2 resolution]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C2-T05 — Relay packaging and operator docs

## Identity and outcome

Bucket 3, MP-N4, chunk C2. Make the relay deployable by anyone (self-builders first):
a container image, a path-filtered CI workflow, a health endpoint check, and an operator
guide page. The **default** deployment for store apps is MP-N4-C2-T06 (blocked on
OQ-N4-1); this ticket does not deploy anything.

## Dependencies and blockers

- C2-T02, C2-T03, C2-T04. DESIGN-N4: no UI.
- Not blocked by OQ-N4-1: packaging and docs are the same whoever operates the default.

## Verified starting point

- Image precedent: `.github/workflows/publish-image.yml` builds with `docker/setup-buildx-action`
  and pushes to GHCR (`ghcr.io/${{ github.repository }}`) on `main`/release, actions pinned
  by SHA. Package-CI precedent: `.github/workflows/streamdeck-package.yml`,
  `.github/workflows/aiur-style.yml`.
- Toolchain install in CI: `jdx/mise-action` pinned by SHA (`release-npm.yml:193-199`).
- Docs rule: AGENTS.md "Docs ship with the change" — a new surface gets a
  `website/docs-app/guide/` page and a sidebar entry in
  `website/docs-app/.vitepress/config.ts` (guide entries at `config.ts:131-140`).
- The webhook tunnel (`website/docs-app/apis/github.md:744-760`) is inbound-only; the
  page must say the relay is unrelated to it.

## Chosen design

- `packages/aiur-push-relay/Dockerfile` (PROPOSED): multi-stage `mix release`, non-root,
  SQLite on a mounted volume (`/data`), `PORT` env, `HEALTHCHECK` on `/healthz`.
- `.github/workflows/push-relay.yml` (PROPOSED): path filter `packages/aiur-push-relay/**`;
  jobs `test` (mise + `mix test`) and `image` (build only on PRs; publish to
  `ghcr.io/<repo>/push-relay` on `main` only, reusing the publish-image steps).
- Refuse to start without a writable data volume (no silent in-memory registry).
- Operator page `website/docs-app/guide/push-relay.md` (PROPOSED): what the relay sees
  (contract §1 table, verbatim), env vars (C2-T02..T04), limits and retention, health,
  self-build instructions (own bundle id, own `.p8`, own Firebase project), and the
  statement that the machine stays outbound-only.

## Implementation steps

1. Dockerfile, `.dockerignore`, `rel/` config.
2. Workflow file.
3. Guide page + sidebar entry.
4. `test/release_smoke_test.exs`.

## Non-happy paths

- Missing provider credentials → provider disabled, `/healthz` reports which; service
  starts (one platform can work alone).
- No volume / read-only volume → exit non-zero with a clear message.

## Compatibility and rollout

Image tags by SHA plus `latest` on `main`. No effect on daemons until a device registers
against a deployed URL. Rollback: previous image; handles persist on the volume.

## Verification

| Test | Expected | Must fail without |
| --- | --- | --- |
| `release_smoke_test "boots with a temp volume and answers /healthz"` | `200` with provider states | — (guard against regression) |
| `release_smoke_test "refuses to start without a writable data dir"` | exit with `:data_dir_unwritable` | remove the volume check |
| CI `push-relay.yml` on a PR touching the package | tests + image build green | — |

Commands: `env -C packages/aiur-push-relay mise exec -- mix test`,
`docker build packages/aiur-push-relay` (local), and the docs site build used by
`.github/workflows/website.yml:50-53`: `env -C website/docs-app bun install --frozen-lockfile`
then `env -C website/docs-app bun run build`.

## Completion and handoff

- [ ] Image builds in CI; docs page reachable from the sidebar.
- Dependents: MP-N4-C2-T06 (default deployment), MP-N4-C7.
