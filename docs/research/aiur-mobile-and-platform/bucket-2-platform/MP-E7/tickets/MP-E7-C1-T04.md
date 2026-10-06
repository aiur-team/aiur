---
ticket_id: MP-E7-C1-T04
feature_id: MP-E7
chunk_id: MP-E7-C1
bucket: 2-platform
title: "aiur: vendor the published listener spec into src/priv/listener/v1 with a checksum gate"
status: blocked
repo: aiur-team/aiur
wave: 3
blocked_by: [DESIGN-E7, E7-D1, MP-E7-C1-T03]
prior_units: [U3]
prior_boundaries: [MSG (16)]
prior_features: [integrations-43]
prior_findings: []
size_owner: n/a (new files only, each < 200 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C1-T04 — Vendor the listener spec into aiur

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E7 / C1. **Repo: aiur.** It
  consumes the Khala release (cross-repo dependency) but changes only aiur.
- **User value:** aiur's scheduler is tested against the exact spec Khala
  ships, and a silent hand edit of the vendored copy fails CI.
- **Deliverable:**
  1. `scripts/vendor-listener-spec` (PROPOSED, bash): `vendor-listener-spec <npm-name>@<version>`
     runs `npm pack` into a temp dir, extracts `package/spec/v1/**` into
     `src/priv/listener/v1/`, and writes `src/priv/listener/v1/VENDOR.json`
     `{package, version, npm_integrity, files: [{path, sha256}]}`.
  2. `scripts/check-listener-spec.py` (PROPOSED): offline; recomputes sha256
     of every vendored file against `VENDOR.json` and against the package's own
     `MANIFEST.json`; fails on any extra, missing or changed file.
  3. `scripts/test-check-listener-spec.sh` (PROPOSED): guards the checker
     (clean tree passes; one edited byte fails; one extra file fails).
  4. `Aiur.Listener.Spec` (PROPOSED, `src/lib/aiur/listener/spec.ex`):
     reads the vendored JSON from `Application.app_dir(:aiur, "priv/listener/v1/…")`
     and exposes `scheduler_rows/0`, `support_statuses/0`, `modes/0`.
- **Non-goals:** no runtime behaviour change; no Node at daemon runtime.

## Dependencies and blockers

- DESIGN-E7, E7-D1, MP-E7-C1-T03 (a published version must exist).
- Successor: MP-E7-C3-T05 (conformance test). MP-E7-C2-T02 does **not** wait
  for this ticket: it ships aiur's support table in Elixir and C3-T05 later
  proves it agrees with the vendored table.
- Concurrency: independent of MP-E7-C2/C3 implementation tickets.

## Verified starting point (aiur `45a290e3`)

- Precedent for a versioned JSON contract read by two languages:
  `analytics/schema/run-summary.v1.json` (MP-E7 plan E7-F5).
- Precedent for drift gates: `scripts/check-config-docs.py`,
  `scripts/check-env-example.py`, `scripts/check-test-shard-parity.py` run in
  the required `lint` job (`.github/workflows/ci.yml:258-279`, comment at
  :258-260 explains why gates live in that job), each guarded by a
  `scripts/test-check-*.sh` in the `workflow-security` job
  (`ci.yml:144-189`, e.g. :177-183).
- Reading priv files at runtime: `Application.app_dir(:aiur, "priv/opencode_plugins/input-identity.mjs")`
  (`src/lib/aiur/opencode/workspace_setup.ex:78`).
- JSON decoding: `{:jason, "~> 1.4"}` (`src/mix.exs` deps). No JSON-Schema
  library is a dependency; none is added (structural checks suffice because
  the schema is validated on the Khala side, C1-T02).
- `src/priv/` already ships non-Elixir assets in the release
  (`src/priv/build_orders/*.json`, `src/priv/opencode_plugins/`).

## Chosen design

- **Vendored files are committed.** Builds and CI stay offline; the vendor
  script is the only writer. Updating the spec is a reviewed PR that changes
  `VENDOR.json`.
- **Two checksums:** `VENDOR.json` (what aiur committed) and the package's own
  `MANIFEST.json` (what Khala generated). The checker requires both to agree,
  so a hand edit of either side fails.
- **Major version directory:** `v1/`. A future v2 vendors beside it; code
  selects one explicitly.

## Implementation steps

1. Add the vendor script; run it for `<name>@1.0.0`; commit `src/priv/listener/v1/**`.
2. Add `check-listener-spec.py` and its test script; add a step to the `lint` job after `check-test-shard-parity.py` (`ci.yml:279`) and a step to the `workflow-security` job beside `test-check-config-docs.sh` (`ci.yml:177`).
3. Add `Aiur.Listener.Spec` with `@spec` on every public function (CONTRIBUTING: `specs.check`).
4. Confirm the release contains the files: `scripts/aiurdev build`, then list `src/_build/dev/rel/aiur/lib/aiur-*/priv/listener/v1/`.

## Non-happy paths

- Registry unavailable during vendoring → script exits non-zero, tree unchanged
  (extract into a temp dir, move into place last).
- Missing priv file at runtime (bad release) → `Aiur.Listener.Spec` returns
  `{:error, :spec_unavailable}`; callers (tests only in wave 3) fail loudly.
  Nothing in the daemon's send path reads the spec at runtime in wave 3.

## Compatibility and rollout

- Additive files; no config, CLI or flag. Rollback: delete the directory and
  the two CI steps.
- Packaging: the npm platform tarballs ship the OTP release, which includes
  `priv/`; verify one built tarball lists `priv/listener/v1/VENDOR.json`.

## Verification

```sh
python3 scripts/check-listener-spec.py
bash scripts/test-check-listener-spec.sh
# Elixir (isolated HOME per AGENTS.md "Reading real state"; never the live ~/.aiur):
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/listener/spec_test.exs
env -C src mise exec -- make lint
```

Tests:

- `test-check-listener-spec.sh`: clean → exit 0; flip one byte in
  `scheduler.v1.json` → exit 1; add `extra.json` → exit 1; delete a file → exit 1.
- `Aiur.Listener.SpecTest` "modes are steer, sync, async with default sync";
  "scheduler rows decode with required keys"; "support statuses include proven and unsupported".

Mutation check: make the checker skip the sha256 comparison; the byte-flip
case in the test script must fail.

## Completion and handoff

- [ ] Vendored spec committed with `VENDOR.json`.
- [ ] Gate in the required `lint` job and its guard in `workflow-security`.
- [ ] Release contains `priv/listener/v1/`.
- Dependents: MP-E7-C3-T05, MP-E7-C6-T04 (Elixir hook renderer tested against `goldens/hook/*`).
- Docs: none user-facing. Add one line to `CONTRIBUTING.md` (or the `scripts/` README if present) naming the vendor command.
