---
ticket_id: MP-E3-C7-T01
feature_id: MP-E3
chunk_id: MP-E3-C7
bucket: 2-platform
title: "aiur executor-attach --check: distinct diagnosis of every opt-in failure"
status: blocked
blocked_by: [DESIGN-E3, MP-E3-C1-T03, MP-E3-C1-T04, MP-E3-C2-T02]
prior_units: [U3]
prior_boundaries: [EXE, CLI]
prior_features: []
prior_findings: [MP-E3 chunks C7 test: "each failure distinctly"]
size_owner: "U8 CLI owner"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C7-T01 — Executor attach check

## Identity and outcome

- Bucket 2 · MP-E3 · C7 · T01.
- **User value:** when the Executor view stays empty, one command says why.
- **Deliverable:** `aiur executor-attach --check [--json]` printing one line per
  check with `ok | fail | unknown` and a next step.
- **Non-goals:** fixing anything automatically.

## Dependencies and blockers

- DESIGN-E3 (copy). MP-E3-C1-T03/T04, MP-E3-C2-T02.

## Verified starting point

- Engine command pattern and control RPC: `aiur-engine.sh:3208-3220`;
  `AgentControlCLI` (`src/lib/aiur/agent_control_cli.ex:682-700`).
- Inputs: binding (C1-T01), token/headers/URL files (C1-T02/T04), installed
  hook entries (C1-T04 marker), last hook age (C4-T01), transcript readability
  and drift counters (C2-T01/T02), HTTP listener (`Aiur.HttpServer.bound_port/1`).

## Chosen design

| Check | `fail` text (copy per DESIGN-E3) |
| --- | --- |
| HTTP listener bound | "dashboard listener is off (started with --no-dashboard)" |
| binding exists | "not attached: run aiur executor-attach --harness …" |
| token + headers + URL files present, 0600 | "hook credentials missing or readable by others" |
| Claude: marked entries in `.claude/settings.local.json` | "hooks not installed" |
| Codex: any hook received | "no hook yet: review and trust the hooks in Codex" |
| last hook age within TTL | "no hook for N min" (`unknown` if never) |
| `transcript_path` readable | "transcript unreadable: <reason>" |
| drift latch | "transcript format changed (version X)" |

- `--json` emits `[%{check, status, detail, observed_at}]`.
- Exit code 0 when all `ok`, 1 otherwise.

## Implementation steps

1. `AgentControlCLI.executor_check/1`; 2. engine flag; 3. `reference/cli.md`.

## Non-happy paths

- Daemon down → the engine's standard error (checks need the daemon).

## Compatibility and rollout

- New flag. Rollback: revert.

## Verification

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/agent_control_cli_executor_check_test.exs
env -C packaging/npm/aiur-cli bun test test/launcher.test.mjs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| one test per row, each producing its own distinct text | distinct strings | each check |
| "never-received hook is unknown, not ok" | `unknown` | branch (mutation: `ok` fails) |
| "all ok → exit 0; any fail → exit 1" | codes | exit mapping |

## Completion and handoff

- [ ] `reference/cli.md` documents `--check`.
