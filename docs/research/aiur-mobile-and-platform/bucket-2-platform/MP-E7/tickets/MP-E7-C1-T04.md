---
ticket_id: MP-E7-C1-T04
feature_id: MP-E7
chunk_id: MP-E7-C1
bucket: 2-platform
title: "aiur: vendor the published listener spec into src/priv/listener_spec with a checksum gate"
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
     `src/priv/listener_spec/v1/`, and writes `src/priv/listener_spec/CHECKSUM`:
     two header lines `# package <name>@<version>` and `# npm_integrity <sri>`,
     then one `sha256sum`-format line (`<sha256>  v1/<path>`) per vendored file.
  2. `scripts/check-listener-spec.py` (PROPOSED): offline; recomputes sha256
     of every vendored file against `CHECKSUM` and against the package's own
     `MANIFEST.json`; fails on any extra, missing or changed file.
  3. `scripts/test-check-listener-spec.sh` (PROPOSED): guards the checker
     (clean tree passes; one edited byte fails; one extra file fails).
  4. `Aiur.Listener.Spec` (PROPOSED, `src/lib/aiur/listener/spec.ex`):
     reads the vendored JSON from `Application.app_dir(:aiur, "priv/listener_spec/v1/…")`
     and exposes `scheduler_rows/0`, `support_statuses/0`, `modes/0` and
     `status/0 :: :ok | {:error, :not_installed} | {:error, :spec_invalid}`.
     `status/0` is computed once per boot (sha256 of every vendored file against
     `CHECKSUM`, plus a structural decode) and cached in `:persistent_term`.
- **Non-goals:** no runtime behaviour change while the flag is `:legacy`; no
  Node at daemon runtime.
- **RC-36 (Phase D).** The spec package is a **build-time input**, never a
  runtime dependency. The send router (`Aiur.Listener.*`, component
  `listener-modes`) is required core code and works without it:
  `Aiur.Listener.Scheduler.routing/0` (MP-E7-C3-T02) answers `:legacy` unless
  `status/0 == :ok`, and the capability provider (MP-E7-C3-T06) reports
  `listener_modes` as `unavailable/not_installed` (no vendored files) or
  `unavailable/spec_invalid` (checksum or decode failure).

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
  `CHECKSUM`.
- **Two checksums:** `CHECKSUM` (what aiur committed) and the package's own
  `MANIFEST.json` (what Khala generated). The checker requires both to agree,
  so a hand edit of either side fails.
- **Major version directory:** `v1/`. A future v2 vendors beside it; code
  selects one explicitly.

## Implementation steps

1. Add the vendor script; run it for `<name>@1.0.0`; commit `src/priv/listener_spec/**`.
2. Add `check-listener-spec.py` and its test script; add a step to the `lint` job after `check-test-shard-parity.py` (`ci.yml:279`) and a step to the `workflow-security` job beside `test-check-config-docs.sh` (`ci.yml:177`).
3. Add `Aiur.Listener.Spec` with `@spec` on every public function (CONTRIBUTING: `specs.check`).
4. Confirm the release contains the files: `scripts/aiurdev build`, then list `src/_build/dev/rel/aiur/lib/aiur-*/priv/listener_spec/`.

## Non-happy paths

- Registry unavailable during vendoring → script exits non-zero, tree unchanged
  (extract into a temp dir, move into place last).
- Missing priv files at runtime (bad release) → `status/0` is
  `{:error, :not_installed}`; the router stays on `:legacy` routing and
  `listener_modes` reports `unavailable/not_installed`. Sends keep working.
- A vendored file edited after build (checksum mismatch) or undecodable →
  `{:error, :spec_invalid}`; same fallback, reason `spec_invalid`; one log
  line per boot.

## Compatibility and rollout

- Additive files; no config, CLI or flag. Rollback: delete the directory and
  the two CI steps.
- Packaging: the npm platform tarballs ship the OTP release, which includes
  `priv/`; verify one built tarball lists `priv/listener_spec/CHECKSUM`.

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
- `Aiur.Listener.SpecTest` "status is not_installed when the priv dir is absent"
  and "status is spec_invalid after one vendored byte changes" (fixture dirs
  under a temp path; each fails if `status/0` returns `:ok` unconditionally);
  "modes are steer, sync, async with default sync";
  "scheduler rows decode with required keys"; "support statuses include proven and unsupported".

Mutation check: make the checker skip the sha256 comparison; the byte-flip
case in the test script must fail.

## Completion and handoff

- [ ] Vendored spec committed with `CHECKSUM`.
- [ ] Gate in the required `lint` job and its guard in `workflow-security`.
- [ ] Release contains `priv/listener_spec/`.
- Dependents: MP-E7-C3-T05, MP-E7-C6-T04 (Elixir hook renderer tested against `goldens/hook/*`).
- Docs: none user-facing. Add one line to `CONTRIBUTING.md` (or the `scripts/` README if present) naming the vendor command.
