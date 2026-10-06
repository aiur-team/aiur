---
ticket_id: MP-E1-C6-T02
feature_id: MP-E1
chunk_id: MP-E1-C6
bucket: 2-platform
title: aiur queue add/remove/reorder/hold/release with the agent-workspace guard
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C6-T01, MP-E1-C4-T01, MP-E1-C4-T02, MP-E1-C3-T06]
prior_units: [U6]
prior_boundaries: [CLI #31]
prior_features: []
prior_findings: [MP-E1 F1, RQ-6]
size_owner: "CLI (aiur-engine.sh, agent_control_cli.ex); provisional, RC-23"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C6-T02 — Queue mutation verbs

> **Plan refresh (wave 0).** Cites `45a290e3`. Mutations are operator-surface
> only (plan §6 Agent-originated mutations).

## Identity and outcome

- Bucket 2, MP-E1, C6, T02. D7.
- **User value:** the operator or Executor builds and steers a queue from the
  terminal; an agent working a ticket cannot.
- **Deliverable:** verbs (names per DESIGN-E1 §3):
  `add <ids…> [--after N] [--queue NAME] [--at POS]`,
  `add --build-order <root> [--queue NAME]`, `remove <ids…>`,
  `reorder <id> --to POS`, `hold <id|--queue NAME>`,
  `release <id|--queue NAME>`; refusal messages; docs.

## Dependencies and blockers

- DESIGN-E1 §3 (verbs, copy), C6-T01, C4-T01, C4-T02, C3-T06 (`release`).

## Verified starting point (`45a290e3`)

- The `--test` agent guard lives only in `scripts/aiurdev`
  (`:538-560` `in_agent_workspace_tree`, `:727-739` refusal); it is not in the
  shared engine.
- The daemon sets `AIUR_AGENT_WORKSPACE` in every agent environment
  (`agent_environment.ex:339, 446`); Elixir-side precedent:
  `test_reset.ex:79-95`.
- `run_todo` timeout sizing (`aiur-engine.sh:603-618`); `--todo --only`
  removes `agent:todo` from other pending tickets
  (`agent_control_cli.ex:1082-1158`).

## Chosen design

- **Guard (two layers):**
  1. Engine `cmd_queue`: for every mutation verb, if `AIUR_AGENT_WORKSPACE` is
     non-empty or `$PWD`/repo root matches `*/aiur-workspaces/*`, print
     "aiur queue changes are blocked inside agent workspaces" and exit 64.
  2. The RPC carries `caller_agent_workspace: "<value or empty>"`; the daemon
     refuses again if non-empty. The env of the CLI process is not the
     daemon's, so the value must be passed explicitly.
  This is a guard, not a security boundary; authorization still rests on
  `DispatchAuthorization` (plan §6).
- Results: per-id outcome lines; partial success exit 1 listing refused ids;
  refusals: `already in queue <name>`, `closed`, `unsupported tracker`,
  `store unavailable`, `blocked in agent workspace`.
- Timeout: `AIUR_CONTROL_RPC_TIMEOUT_SECONDS` sized like `todo_rpc_seconds`
  for `add` with many ids.
- `hold`/`release` operate on items or a whole queue; `release` also clears
  `overridden` and external holds (C3-T06).

## Implementation steps

1. `aiur-engine.sh`: verb parsing in `cmd_queue` with `case` arms for every
   flag (so `check-cli-reference.sh` sees them); guard function.
2. `AgentControlCLI.queue/1` dispatch; `BuildQueueCLI` formatting.
3. Server calls (C4-T01/T02/C3-T06 functions).
4. Docs: `reference/cli.md` verb table; note under `--todo --only` that it
   holds queue items (external hold) and that `aiur resume` on a held item
   reports `build_queue_hold`.

## Non-happy paths

Daemon down → engine diagnostics; timeout → 124 "outcome unknown" (re-run
`queue show`). Unknown verb or flag → exit 64.

## Compatibility and rollout

New verbs only.

## Verification

| Test | Expected | Fails without |
| --- | --- | --- |
| `src/test/scripts_aiurdev_test.exs` (or a new engine test next to it) "queue add is refused with AIUR_AGENT_WORKSPACE set" | exit 64 + message; no RPC attempted | engine guard |
| same, "queue show is allowed in an agent workspace" | RPC attempted | guard scoping |
| `src/test/aiur/build_queue_cli_test.exs` "daemon refuses a mutation carrying caller_agent_workspace" | `{:error, :agent_workspace}` | daemon layer |
| "add to a second queue prints the owning queue" | text names it, exit 1 | refusal mapping |
| `bash website/docs-app/scripts/check-cli-reference.sh` | pass | docs |

Mutation check: remove the engine guard → test 1 fails; remove the daemon
check → test 3 fails.

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/scripts_aiurdev_test.exs test/aiur/build_queue_cli_test.exs
bash website/docs-app/scripts/check-cli-reference.sh
```

## Completion and handoff

- [ ] Verbs, two-layer guard, docs.
- Dependents: C9-T01, C9-T03.
