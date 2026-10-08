---
ticket_id: MP-R1-C3-T06
feature_id: MP-R1
chunk_id: MP-R1-C3
bucket: 1-refactor (Bucket-2 enabling work, RC-12)
title: packages/aiur-contracts - JSON Schema and TypeScript types for identity and capabilities, with a cross-language golden test
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C3-T03, MP-R1-C1-T04]
prior_units: []
prior_boundaries: ["SD #35 (sidecar is the first consumer)"]
prior_features: [MP-N1, MP-R6]
prior_findings: []
size_owner: n/a (new package)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C3-T06 — `packages/aiur-contracts`

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1 (RC-12 enabling), MP-R1, C3. Step S14. Rule
  R-client (component-map §2), decision KD4.
- **User value:** every client (Stream Deck sidecar, dashboard JS, phone, watch) gets the
  wire shape from one published package instead of copying it; a daemon change that
  breaks the shape fails CI on the daemon side.
- **Deliverable:**
  1. `packages/aiur-contracts/` (`@aiur/contracts`, `private: true` until a publish
     decision exists): `schemas/capabilities.v1.schema.json` (contract §2.2, draft
     2020-12, `additionalProperties: true` at the top level and inside entries so new
     fields are not breaking; `capabilities` keys free-form with an exported
     `KNOWN_CAPABILITY_IDS` enum for documentation and C10's check), `schemas/capability-error.v1.schema.json`
     (§2.5), `src/index.ts` exporting generated types and the ID/reason enums,
     `fixtures/capabilities.v1.json` (golden).
     The reason enum is identity contract §2.2 as amended in Phase D, including
     `spec_invalid` (listener spec fails its checksum, RC-36), `store_unavailable` and
     `writes_paused` (build queue, X-21). `KNOWN_CAPABILITY_IDS` carries template entries
     such as `harness.<id>.native_question` as patterns (`KNOWN_CAPABILITY_ID_PATTERNS`,
     `<id>` = one segment `[a-z0-9_]+`), so C10-T04 rule D5 and clients can match
     concrete IDs like `harness.codex.native_question` (X-46). It also lists
     `orchestration`, `listener_modes`, `build_queue`, `build_queue.build_order_source`
     and `events.export` (capability-matrix §2). A test in `npm test` asserts
     `harness.codex.native_question` matches and `harness.native_question` does not, and
     that every reason in the golden fixture is in the enum.
  2. Generator script `npm run generate` (types from schemas) and `npm run check`
     (generated file up to date, fixtures validate against schemas).
  3. Elixir golden test: renders a fixed report through `Aiur.Capabilities.to_wire/1`
     and compares it to `packages/aiur-contracts/fixtures/capabilities.v1.json`.
  4. Workflow `.github/workflows/aiur-contracts.yml` on `packages/aiur-contracts/**`
     paths, modelled on `.github/workflows/aiur-style.yml` (pinned actions, `npm ci`,
     `npm run check`, `npm test`).
- **Non-goals:** schemas for events, Commands, conversations or notifications (their
  owning features add them here later); npm publishing; changing the sidecar.

## Dependencies and blockers

- DESIGN-R1 §1; C3-T03 (`to_wire/1` and the endpoint exist); C1-T04 (R-client rule must
  accept the package). **Concurrent:** T04, T05, T07.
- **Dependents:** MP-R1-C10-T04 rule D5 (capability IDs in the enum), MP-R6 (sidecar
  adopts types), MP-N1 (mobile package dependency), MP-E2/E4/R2 schemas.

## Verified starting point (`45a290e3`)

- `packages/` has `aiur-style` (own `package.json`, `package-lock.json`, own workflow
  `aiur-style.yml` triggered on its paths) and `streamdeck`. No workspaces at the root.
- The CI docs-only classifier treats `packages/aiur-style/` as docs-only
  (`ci.yml:126-131`); `packages/aiur-contracts/` is not, so changes there also run the
  Elixir jobs, which is wanted (the golden test lives there).
- Elixir has no JSON-Schema validator dependency (`src/mix.exs` deps: `jason` only for
  JSON). Hence validation runs in Node and the Elixir side compares to the golden file.
- No `api/v1/capabilities` caller exists anywhere at base.

## Chosen design

- **Golden file is the bridge.** Elixir test: equal to golden (after canonical key sort).
  Node test: golden validates against the schema. Changing either side without the other
  fails one of the two jobs.
- **Regeneration:** `mix test` never writes the golden file; a developer updates it with
  `AIUR_UPDATE_GOLDEN=1` on that single test (documented in the package README).
- **Dependencies (devDependencies only, versions pinned in the lockfile at
  implementation):** a schema validator (`ajv`) and a schema-to-TS generator
  (`json-schema-to-typescript`). Record the exact versions and their licences in the PR
  body. No runtime dependencies.
- **Versioning:** schema file name carries the contract version (`v1`); a breaking change
  adds `v2` beside it.

## Implementation steps

1. Package skeleton (`package.json`, `tsconfig.json`, README ≤ 60 lines).
2. Schemas from the contract; enums from capability-matrix §2 plus `identity`,
   `api.http`.
3. Generator + check scripts; generated `src/generated.ts` committed.
4. Golden fixture produced from the Elixir test fixture report.
5. Elixir test `src/test/aiur/capabilities_wire_test.exs`.
6. Workflow file; add it to `scripts/test-workflow-security.sh` expectations if that
   script enumerates workflows.
7. `components.json`: component `aiur-contracts` (L5, required by clients).

## Non-happy paths

- Additive field in Elixir without schema update → still validates (additional
  properties allowed) but the Elixir golden test fails → developer updates golden and
  types together.
- Removing or renaming a field → Node validation of the golden fails (required list).
- Unknown capability ID in a report → valid (clients ignore unknown IDs, contract §3.2).

## Compatibility and rollout

New package, unpublished. Rollback: revert.

## Verification

| Test | Where | Expected |
|---|---|---|
| `to_wire output equals the golden fixture` | Elixir | equal |
| `golden validates against capabilities.v1` | Node (`npm test`) | valid |
| `error fixture validates against capability-error.v1` | Node | valid |
| `missing contract_version is invalid` | Node, mutated copy | invalid |
| `generated types are up to date` | `npm run check` | no diff |
| `package imports nothing outside itself` | C1-T04 R-client | exit 0 |

Commands: `npm ci && npm run check && npm test` in `packages/aiur-contracts`;
`env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test test/aiur/capabilities_wire_test.exs`.

Mutation check: rename `age_ms` in `to_wire/1` → Elixir golden test fails; delete
`age_ms` from the schema's `required` list and from the golden → Node test
`missing ... invalid` analogue for `age_ms` must be added and fail.

## Completion and handoff

- [ ] Package, schemas, generated types, golden, workflow merged.
- [ ] C10-T04 rule D5 enabled against `KNOWN_CAPABILITY_IDS` (that ticket's checklist).
- [ ] Docs: package README; the concepts page (C3-T03) links the schema path.
- **Dependents:** C10-T04, MP-R6, MP-N1, every later client schema.
