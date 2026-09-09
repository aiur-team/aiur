# PSO-013 — `aiur init` offers Paseo backends when the sidecar is installed

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 2 — One detection step and one config write in the init wizard, plus a `--check` contract the sidecar implements.

**Risk:** low

**Phase hint:** 4

**Depends on:** PSO-002, PSO-004

**Serializes with:** none

**External gates:** none

**Requirements:** R13

**Decisions:** DEC-001, DEC-013, DEC-014

**Design evidence:** 00-design.md sections 5, 8; 01-spike-report.md sections 1, 10, 11

**Researched at:** 8199f5373

**Suggested labels:** `complexity:2`, `model:claude`, `phase:4`, `build-lane:paseo-integration`; never `agent:todo`

## Outcome

When `aiur-paseo` is on PATH, `aiur init` offers "Paseo (Claude)" and "Paseo (Codex)" as optional agents. Accepting one writes `agent.backend_configs.<backend>.enabled: true` and appends the backend to `agent.priority` after its family, then runs `aiur-paseo --check` and prints the daemon status or the pairing hint. A re-run detects the saved selection and does not re-ask. Without the binary, the wizard is unchanged.

## Context and evidence

The wizard's agent choices come from `Aiur.Init.Questions.agent_kind_choices/0` (`src/lib/aiur/init/questions.ex:172`), which returns `CodingAgent.configurable_backends/0` (`src/lib/aiur/coding_agent.ex:394-401`). That list is filtered by `dispatchable_backends/0`, so a backend that is `dispatch_enabled_by_default: false` (PSO-002) never appears, by design.

Presence checks already work from registry data: `Aiur.Init.AgentCli.check_agent_auth/1` (`src/lib/aiur/init/agent_cli.ex:86-98`) resolves the executable from `agent_executable/1` (line 205: `backend_configs.<kind>.command || registry default_command`) and formats `install_hint/2` (line 104) on a miss. `check_agent_clis/3` (line 25) runs it for each selected backend.

Resume semantics live in `Aiur.Init.Resume` (`src/lib/aiur/init/resume.ex`): `agents_from_config/1` (line 110) derives the backend set from `agent.priority` and routing, and the wizard filters saved kinds against `agent_kind_choices/0` (line 119). `saved_summary_lines/1` (line 19) prints what was saved.

Config writes go through the scaffold templates (`src/lib/aiur/init/templates.ex:94` `{{PRIORITY}}` from `priority_inline/1`, line 167) and `Aiur.Init.Resume.append_section/5` for later sections.

The Paseo daemon needs a password and either the relay pairing (`paseo daemon pair`) or a Tailscale address for the phone (01-spike-report.md section 1). aiur cannot do the pairing; it can only tell the operator.

## Scope

- `Aiur.Init.AgentCli`:
  - `detect_paseo/1` (deps-injected `find_executable`): returns `[]` or `["paseo-claude", "paseo-codex"]` filtered to the families the operator already selected (offer `paseo-codex` only if `codex` is selected, same for claude).
  - `check_paseo_daemon/1`: runs `aiur-paseo --check` (deps-injected command runner), parses stdout JSON `{"serverId": ..., "version": ...}`, returns `{:ok, map}` or `{:error, message}` where message is the sidecar's stderr first line.
- `Aiur.Init.Questions`: after the agent-kind question, if `detect_paseo/1` is non-empty, ask a multi-select "Also drive these through Paseo (mobile chat)?" with the detected entries. Skip the question on resume when `backend_configs.<b>.enabled` is already set.
- Config write: for each accepted backend, set `agent.backend_configs.<b>.enabled: true` and insert `<b>` into `agent.priority` immediately after its family entry (or at the end if the family is absent). Emit through the same template/append path the wizard uses for `agent.priority` today; do not hand-edit YAML text.
- After writing, run `check_paseo_daemon/1`: on `{:ok, %{version, serverId}}` print `paseo daemon <version> reachable (server <serverId>)`; on error print the message and the hint `start it with: paseo daemon start; pair your phone with: paseo daemon pair; export PASEO_PASSWORD for aiur` and continue (the choice is saved either way).
- `Aiur.Init.Resume.saved_summary_lines/1`: add `paseo: paseo-claude, paseo-codex` when any `backend_configs.<paseo-*>.enabled` is true.
- Labels: the existing label step seeds `model:paseo-*` because `agents_from_config/1` now sees the backend in `agent.priority`; verify and assert.
- Docs: `website/docs-app/guide/quick-start.md` init step list gains one line: "If `aiur-paseo` is installed, init offers to route agents through Paseo; see the Paseo guide." The guide page itself is PSO-008.
- `--check` contract for the sidecar (implemented by PSO-006, documented here): `aiur-paseo --check` connects to `PASEO_HOST` with `PASEO_PASSWORD`, prints `{"serverId":"srv_...","version":"0.7.2","listen":"127.0.0.1:6767"}` on stdout and exits 0; on failure prints one line to stderr (`paseo_unreachable: ...`, `paseo_unauthorized`, `paseo_unsupported_version: 0.9.0 (supported >= 0.7.2 < 0.9.0)`) and exits 1.

## Non-goals

- Installing `aiur-paseo` from the wizard (the operator runs `npm install -g aiur-paseo`; the `install_hint` names it).
- Starting or pairing the Paseo daemon.
- The guide page (PSO-008).
- Any change to `configurable_backends/0` or `dispatchable_backends/1`.

## Existing owner and reuse target

Extend `src/lib/aiur/init/agent_cli.ex`, `questions.ex`, `resume.ex`, `templates.ex` (priority rendering), `runtime.ex` (deps map: add `find_executable` and `run_check_command` if not already injectable), and `src/test/aiur/init_test.exs`.

## Contract and invariants

- Without `aiur-paseo` on PATH the wizard's prompts, output, and written config are byte-identical to today.
- Accepting a Paseo backend never removes or reorders existing `agent.priority` entries.
- A failing `--check` never aborts init and never unsets the saved choice.
- Re-running init with a Paseo backend enabled shows it in the saved summary and asks nothing about Paseo.

### Requirements

- PSO-013-R1. Detection is by executable presence only; no network call before the operator accepts.
- PSO-013-R2. Acceptance writes `agent.backend_configs.<b>.enabled: true` and appends `<b>` to `agent.priority` after its family.
- PSO-013-R3. The daemon check runs after the write and reports version and server id or a one-line failure with the start and pair hints.
- PSO-013-R4. Resume is idempotent.
- PSO-013-R5. The `--check` contract above is written into the sidecar README by PSO-006 and consumed here unchanged.

## Refreshable implementation notes

- `Aiur.Init.Runtime` (`src/lib/aiur/init/runtime.ex:47,103`) holds the deps map with `check_agent_auth`; add `find_executable: &System.find_executable/1` and `run_command: &System.cmd/3` (or reuse an existing runner) so tests stub both.
- The multi-select prompt helper: reuse whatever `Questions` uses for the agent-kind multi-select (line 72 area) so the UX matches.
- `priority_inline/1` (`templates.ex:167`) renders `agent.priority` for a fresh scaffold; on resume the section already exists, so use `Resume.append_section/5` semantics or a targeted YAML update helper if one exists (grep `put_in_config` or similar in `src/lib/aiur/init/`). State which path was used in the PR.

### Key technical decisions

- KTD-1. Offer only when the binary exists, so users without Paseo never see the option and the wizard grows no prompt for them.
- KTD-2. The daemon check is informational, after the write, because a fresh install often has no daemon running yet and the choice should still be saved.
- KTD-3. `--check` is the sidecar's responsibility; core learns nothing about Paseo's protocol.

## Acceptance and verification

### Agent gate

- `src/test/aiur/init_test.exs` with deps stubs:
  1. `find_executable` returns nil: no Paseo prompt, config identical to the existing fixture.
  2. Binary present, claude selected, operator accepts `paseo-claude`: config has `agent.backend_configs.paseo-claude.enabled: true` and `agent.priority` is `["claude", "paseo-claude", ...]`.
  3. Binary present, codex not selected: `paseo-codex` is not offered.
  4. `--check` stub returns exit 1 with `paseo_unreachable: connect ECONNREFUSED`: warning printed with the start and pair hints; config still written.
  5. `--check` stub returns the JSON: the version and server id line is printed.
  6. Resume with `enabled: true` already set: no prompt, summary line present.
  7. Label seeding step includes `model:paseo-claude` (stub the label creator and assert the set).
- `make all` green.

### At-merge gate

- CI green on the exact head; `scripts/check-config-docs.py` green (no new keys; PSO-002 documented them).

### Human/manual evidence

- On this machine with `aiur-paseo` installed and the daemon stopped: `scripts/aiurdev init` in a scratch repo offers Paseo, writes the config, prints the unreachable hint. Start the daemon, re-run: summary shows `paseo:`, no prompt.

## Failure, security, migration, and accessibility cases

- `--check` output is parsed defensively; non-JSON stdout is treated as failure with the raw first line shown.
- The wizard never echoes `PASEO_PASSWORD`.
- No migration; new keys only.

## Surfaces

- Reads: PATH, `aiur-paseo --check`.
- Writes: `.aiur/config` (`agent.backend_configs`, `agent.priority`), wizard output, quick-start docs line.
- Contracts: `aiur-paseo --check` stdout JSON and exit codes.

## Sibling boundaries and open gates

PSO-002 owns the registry entries and their docs. PSO-004 owns the package scaffold and PSO-006 implements `--check`; this ticket only calls it. PSO-008 owns the Paseo guide page that the quick-start line links to.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the approved planning commit linked in this issue's preamble):

- [Design and decisions](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/00-design.md)
- [Spike report](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/01-spike-report.md)
- [Pack index](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/README.md)
- [Requirements plan](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/plans/2026-09-09-001-feat-paseo-integration-plan.md)
- Your issue's native parent is the Build Order root; native `blockedBy` edges are the dependency graph — the root issue renders the full picture.
