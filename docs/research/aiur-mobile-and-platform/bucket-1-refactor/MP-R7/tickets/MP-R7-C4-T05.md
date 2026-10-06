---
ticket_id: MP-R7-C4-T05
feature_id: MP-R7
chunk_id: MP-R7-C4
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Release packaging check — the OTP release still contains and boots every adapter
status: blocked
blocked_by: [DESIGN-R7, MP-R7-C4-T03, MP-R7-C4-T04, CR-R7-1]
prior_units: [U7, U9]
prior_boundaries: [#32 launcher and packaging, CA (20)]
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C4-T05 — Release packaging check

## Identity and outcome

- Bucket 1, MP-R7, chunk C4. **Conditional** on T03/T04 having run.
- **User value:** the npm `aiur-cli` install and `aiurdev build` keep producing
  a release that runs every backend (DESIGN-R7 §1 "Packaging").
- **Deliverable:** (a) the release definition includes the harness package;
  (b) a CI step that asserts every registry adapter module is present in the
  assembled release; (c) the foreground manual run.
- **Non-goals:** changing npm package layout or the launcher engine.

## Dependencies and blockers

- MP-R7-C4-T03, -T04; CR-R7-1 (the form determines whether `releases/0` needs
  an `applications:` entry for the new OTP app).

## Verified starting point (base `45a290e3`)

- Release: `src/mix.exs:195-203` — one release `aiur`,
  `applications: [aiur: :permanent]`, steps `[:assemble, &copy_cli_launcher/1]`.
- Dev build: `scripts/aiurdev:401` runs `mix compile --force && mix release --overwrite`.
- Platform package: `packaging/npm/platform/` (README + .gitignore at base);
  published by `.github/workflows/release-npm.yml`.
- CI: `.github/workflows/ci.yml`.

## Chosen design

- If the package is a separate OTP application, add it to `releases/0`
  `applications:` explicitly (a path dependency is included transitively when
  listed in `deps`, but being explicit makes the check below meaningful).
- New check (PROPOSED `scripts/check-release-adapters.sh`): after
  `mix release`, run
  `_build/prod/rel/aiur/bin/aiur eval 'Aiur.CodingAgent.backends() |> Enum.map(fn {_k, e} -> Code.ensure_loaded?(e.adapter) end) |> Enum.all?() |> IO.inspect()'`
  and fail unless it prints `true`. `eval` starts no application, only loads
  code, so it is safe in CI.

## Implementation steps

1. Update `releases/0` if needed.
2. Add the script and a `ci.yml` step after the existing release build (or a
   new job if none builds a release; check `ci.yml` at the implementation head).
3. Run the foreground manual test.

## Non-happy paths

- `eval` unavailable in the release (custom `bin/aiur` launcher copied by
  `copy_cli_launcher/1`): use `bin/aiur` from `_build/.../rel/aiur/bin/` that
  `mix release` generates before the copy step, or `erl -pa` against the
  release `lib/` directory; record which in the script header.
- An adapter's optional dependency (tmux) missing at runtime: today's install
  hints apply unchanged.

## Compatibility and rollout

No user-facing change; release contents identical in module set. Rollback:
revert.

## Verification

- `bash scripts/check-release-adapters.sh` prints `true` and exits 0.
- Mutation: remove the harness app from `releases/0` / deps in a scratch
  branch → the script exits non-zero.
- Manual (AGENTS.md "Manual testing", DESIGN-R7 decision 1): `scripts/aiurdev build`
  then the wrapper-tmux `scripts/aiurdev --test` recipe; one Codex and one
  Claude agent each receive a chat-pane message typed into pane `0.1`;
  `capture-pane` output attached to the PR. If DESIGN-R7 decision 1 answers
  "also require a full dogfood run", add it.

## Completion and handoff

- [ ] Script in CI, mutation recorded.
- [ ] Manual capture attached.
- Docs: none user-facing (no install step changes); C6-T01 mentions the check.
- Dependents: MP-R7-C6-T01 final update.
