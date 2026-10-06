---
ticket_id: MP-N3-C5-T01
feature_id: MP-N3
chunk_id: MP-N3-C5
bucket: 3-mobile-watch
title: "Synthetic multi-machine gateway fixture server for UI work and design review"
status: blocked
blocked_by: [DESIGN-N3, MP-N3-C3-T02]
prior_units: []
prior_boundaries: [DEV]
prior_features: [MP-N2]
prior_findings: []
size_owner: n/a (dev tooling)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C5-T01 — Fixture gateway

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C5.
- **User value:** the meta-dashboard can be built, reviewed against DESIGN-N3 and tested on
  devices without live agents or a real fleet.
- **Deliverable:** `packages/aiur-mobile/scripts/fixture-gateway.mjs` (PROPOSED), a Node HTTP(S)
  server that serves `aiur.machine/v1` endpoints (`/v1/machine`, `/v1/instances?include=summary`,
  `/v1/token*` accepting a fixed test device) from the C3-T02 scenario files, with a
  `--scenario` flag and a `/__scenario/<name>` switch for live state changes; `--machines 2`
  serves two machines on two ports, one of which can be toggled unreachable.
- **Non-goals:** pairing crypto (uses a fixed test key pair, never valid against a real gateway);
  instance dashboards (MP-N1 uses the existing browser fixture for WebView tests).

## Dependencies and blockers

DESIGN-N3; MP-N3-C3-T02. Concurrent with C4 development.

## Verified starting point (base `45a290e3`)

No Node fixture server for the machine API exists. `node --test` is already used by
`packages/streamdeck` (`package.json` `test:package`), so Node is an accepted dev dependency.

## Chosen design

- Plain `node:http`/`node:https` (no framework). HTTPS mode uses a throwaway cert generated at
  start and prints its SPKI pin, so the T-B client path can also be exercised in the simulator.
- Signatures (`sig`) are produced with a fixture Ed25519 key in `fixtures/keys/fixture-machine.*`,
  clearly named; the app's debug build trusts it only when built with `AIUR_FIXTURE=1`.

## Implementation steps

1. Script, scenario loader, scenario switch endpoint, unreachable toggle. About 180 lines (dev only).
2. `npm --prefix packages/aiur-mobile run fixture-gateway -- --scenario live_basic`.

## Non-happy paths

Unknown scenario → exit 2 listing available names. The fixture key is refused by release builds
(test in MP-N1-C2 key handling).

## Compatibility and rollout

Dev-only; not shipped in the app bundle (assert in a packaging test).

## Verification

`packages/aiur-mobile/scripts/__tests__/fixture-gateway.test.mjs` (`node --test`):

| # | Test | Must fail without |
|---|---|---|
| 1 | `"serves each scenario's input.json byte-identical"` (loops over every directory under the C3-T02 scenario root) | the scenario loader (serving a hard-coded body, or re-serialising JSON so bytes change) |
| 2 | `"POST /__scenario/<name> changes the next /v1/instances response"` | the scenario switch endpoint (the second read returns the first scenario) |
| 3 | `"the unreachable toggle closes the port for machine B only"` (connect to B fails with `ECONNREFUSED`; A still answers) | the per-machine unreachable toggle |
| 4 | `"unknown --scenario exits 2 and lists the available names"` | the argument check (process starts with an empty scenario) |
| 5 | `"HTTPS mode prints an SPKI pin that matches the served certificate"` (recompute sha256 of the peer certificate's SPKI) | pin printing derived from the served certificate |

Mutation check: revert each production hunk named in the right-hand column in a worktree and
confirm its test fails (pack rule, AGENTS.md "Tests must fail without the production change
they guard"); report the command in the PR.

```bash
node --test packages/aiur-mobile/scripts/__tests__/fixture-gateway.test.mjs
```

## Completion and handoff

- [ ] Tests pass. Docs: a "Run the meta-dashboard against fixtures" line in the mobile dev guide
      (MP-N1-C1 docs page).
- [ ] Dependents: MP-N3-C4-T01..T05, DESIGN-N3 review sessions.
