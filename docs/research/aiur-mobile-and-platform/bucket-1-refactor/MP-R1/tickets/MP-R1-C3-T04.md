---
ticket_id: MP-R1-C3-T04
feature_id: MP-R1
chunk_id: MP-R1-C3
bucket: 1-refactor (Bucket-2 enabling work, RC-12)
title: aiur capabilities [--json] control verb, aiurdev routing, and CLI reference entry
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C3-T01]
prior_units: []
prior_boundaries: ["CLI #31", "#32 launcher"]
prior_features: []
prior_findings: []
size_owner: "packaging/npm/aiur-cli/libexec/aiur-engine.sh: U8 CLI (4,224 lines) and src/lib/aiur/agent_control_cli.ex: U8 CLI (3,362 lines) — add ≤ 25 and ≤ 5 lines; logic goes in a new file"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C3-T04 — `aiur capabilities` verb

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1 (RC-12 enabling), MP-R1, C3. DESIGN-R1 S1.
- **User value:** an operator or Executor sees the same report the API gives, including
  under `--no-dashboard`, e.g. `voice.stt  unavailable  not_configured`.
- **Deliverable:**
  1. Engine: `capabilities)` arm in `aiur_engine_main` dispatch and `cmd_capabilities`
     (`--json` only), modelled on `cmd_github_usage` (`aiur-engine.sh:3068-3085`);
     usage banner line beside `github-usage` (`:466`).
  2. `scripts/aiurdev`: add `capabilities` to the non-building list in
     `targets_release_deliberately` (`scripts/aiurdev:115`). **Without this the dev shim
     treats the token as a bare run and boots a release** (its fallthrough "an
     unrecognized token ... boot[s] a release", `:105-108`).
  3. `Aiur.AgentControlCLI.capabilities/1` (≤ 5 lines, `guarded/2` + `exit_marker/1`
     like `github_usage/1`, `agent_control_cli.ex:380-383`) delegating to PROPOSED
     `src/lib/aiur/capabilities_cli.ex` (`Aiur.CapabilitiesCLI.run/1`).
  4. `website/docs-app/reference/cli.md`: a row in the "Inspect and operate a running
     daemon" table (`cli.md:83`) with syntax, behaviour and runnable example.
- **Non-goals:** an offline mode (no daemon → standard RPC failure), filters, colours.

## Dependencies and blockers

- **DESIGN-R1 S1** (the verb exists; line format). C3-T01. **Concurrent:** T02, T03, T07.
- **Dependents:** Executor skills may adopt it later (not required here).

## Verified starting point (`45a290e3`)

- Control verbs RPC an expression into the node via `run_control_rpc`
  (`aiur-engine.sh:2419-2436`); `__AIUR_CONTROL_EXIT__:<code>` markers translate exit
  codes (`:2414-2416`).
- Existing `--json` verbs: `units`, `commands`, `github-usage`; engine tests use
  `run_sourced_engine` with a stubbed `run_control_rpc` (`src/test/aiur_engine_test.exs:1228-1260`).
- `website/docs-app/scripts/check-cli-reference.sh` derives every command from the
  engine's `case "$cmd"` arms and every flag from parse arms, and fails when the page
  lacks a complete row (`:14-23`, `:113-133`). It is an npm script
  (`website/docs-app/package.json:10`) and **not** run by any workflow at base (no hit
  for `check-cli-reference` in `.github/workflows/`). RQ answer: the script needs no
  change; `--json` is already a documented flag; the new command needs a table row.

## Chosen design

- Human format (pending DESIGN-R1 S1; plan default):

  ```text
  aiur capabilities — workstation / 3f9a1c0b2e  (revision 7, observed 0.8s ago, current)
  repository   github aiur-team/aiur
  executor     active  host-3f9a1c0b2e
  api.http                 available
  voice.stt                unavailable  not_configured
  orchestration            degraded     snapshot_stale
  ```

  Sorted by ID; `depends_on` appended as `(needs api.http)`. Age always rendered
  (AGENTS.md "if a surface computes an age, it renders the age"). `null` sections print
  `unknown`, never blank.
- `--json`: exactly the HTTP body (`Aiur.Capabilities.to_wire/1`, shared with T03).
- Exit codes: 0 always when the daemon answered (the report is information, not a health
  check); RPC failure keeps the engine's codes.

## Implementation steps

1. `capabilities_cli.ex` with `run(opts)` returning `{output, exit_code}` (pure render
   from a report map, report fetched through an injectable fun).
2. `AgentControlCLI.capabilities/1`.
3. Engine arm, `cmd_capabilities`, banner line.
4. `scripts/aiurdev` list.
5. cli.md row; run `bash website/docs-app/scripts/check-cli-reference.sh` locally (needs
   `rg`) and paste the result in the PR body.
6. Manifest: new file to `identity` (CLI module of the component) or `control-cli` per
   the manifest's verb ownership; record the choice.

## Non-happy paths

- Daemon not running → engine's standard RPC diagnostic and non-zero exit.
- Report stale → header says `stale`, age shown.
- Unknown flag → exit 64, `aiur: capabilities received an unknown option: <x>` (engine
  pattern).
- Positional argument → exit 64.

## Compatibility and rollout

New verb; no existing verb changes. Rollback: revert (engine, shim, CLI module, docs row
together).

## Verification

- `src/test/aiur_engine_test.exs`: `capabilities routes to the control rpc` →
  `RPC:Aiur.AgentControlCLI.capabilities([])`; `capabilities --json` →
  `...capabilities([json: true])`; `capabilities --bogus` → exit 64 with message.
- PROPOSED `src/test/aiur/capabilities_cli_test.exs`: `renders age and freshness`;
  `null executor renders unknown`; `json output equals to_wire`; `depends_on rendered`.
- `scripts/aiurdev` routing: a test in the existing shim test location (or a new
  `scripts/test-aiurdev-routing.sh` if none covers `targets_release_deliberately`)
  asserting `targets_release_deliberately capabilities` returns 1.
- Command: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test test/aiur_engine_test.exs test/aiur/capabilities_cli_test.exs`.
- Mutation check: remove `capabilities` from the aiurdev list → routing test fails; drop
  the age column → `renders age and freshness` fails.
- Manual (AGENTS.md): from the Executor repo root, `scripts/aiurdev --test` via the
  wrapper-tmux recipe; in a second shell run `scripts/aiurdev capabilities` and
  `--json`; confirm no rebuild was triggered and the output matches
  `curl …/api/v1/capabilities`. Then `scripts/aiurdev stop`, restart with
  `--bg --no-dashboard`, run the verb again: `api.http unavailable not_installed`.

## Completion and handoff

- [ ] DESIGN-R1 S1 approved (format).
- [ ] Engine, shim, CLI, docs row merged together; check-cli-reference passes locally.
- **Dependents:** none required.
