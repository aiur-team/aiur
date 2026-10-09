---
title: KA4 restart --keep-agents CLI, report and verification - Plan
type: feat
date: 2026-10-09
topic: keep-agents-restart
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/keep-agents-restart/brainstorm.md
base_main_sha: 9940eed44
---

# KA4 restart --keep-agents CLI, report and verification - Plan

## Goal Capsule

- **Objective:** `aiur restart --keep-agents` and
  `aiurdev restart --keep-agents` drive the handoff end to end, report the
  outcome, and give the Executor one command to verify it.
- **Product authority:** [brainstorm.md](brainstorm.md) (R1, R7, R8, R14).
- **Open blockers:** KA3 merged.
- **Product Contract preservation:** unchanged.

---

## Problem Frame

`cmd_restart` calls `cmd_stop`, which kills the tmux session and server,
reaps the agent pidfile, and lets the BEAM-death watchdog reap anything left.
Each of these must step aside for listed agents, and only for them, when the
operator asks to keep agents.

## Requirements

- R1, R7, R8, R14 from the brainstorm.
- KA4-R1. `--keep-agents` preflight: daemon up, answers the handoff RPC, and
  reports at least one handoff-capable agent or zero agents. Any failure exits
  non-zero before the stop, with the reason.
- KA4-R2. The stop under `--keep-agents` kills only the BEAM session. It
  keeps the agent tmux server, the relays and the agent pidfile, and writes the
  stop sentinel with `handoff=<handoff_id>` so the watchdog does not reap.
- KA4-R3. After start, the command waits up to 120 s for the adoption result
  and prints one line per agent (`adopted` or `fallback <reason>`), the gap
  duration and the handoff id. Exit 0 when the daemon is up, even with
  fallbacks; exit non-zero when the daemon did not start.
- KA4-R4. `aiur status` shows the last handoff: id, time, adopted, fallback
  counts with reasons, gap.
- KA4-R5. Without the flag, `restart` is unchanged.

## Key Technical Decisions

- **Flag name `--keep-agents`** on `restart` only. No `stop --keep-agents`: a
  stop that leaves agents unsupervised has no adopter; relays would only
  orphan-timeout. `aiurdev` passes the flag through.
- **Build ordering unchanged** (rebuild after stop). The gap delays tool
  replies only; agents keep working. A failed rebuild leaves the record and
  relays; the next `aiur run` adopts within the orphan timeout (F2).
- **Executor verification is a command, not a procedure:**
  `aiur restart --keep-agents` output plus `aiur status --handoff --json`.
  The JSON carries `adopted[]` with issue, provider pid and session id
  before and after, so the check is a diff, not a judgment.
- **Alert.** Emit `system.restart.handoff.completed` (info) with counts, and
  `system.restart.handoff.fallback` (needs-attention) when any agent fell
  back, so the wake inbox carries it.

## Implementation Units

### U1. Engine restart and stop paths

**Goal:** preflight, handoff-aware stop, start, wait for the report.
**Requirements:** KA4-R1, KA4-R2, KA4-R3, KA4-R5, R7.
**Dependencies:** KA3.
**Files:** `packaging/npm/aiur-cli/libexec/aiur-engine.sh` (`cmd_restart`,
`cmd_stop`, `start_beam_death_watchdog`, `usage`), `scripts/aiurdev`
(passthrough), `src/test/aiur_engine_test.exs`,
`src/test/aiur_engine_stop_pidfile_test.exs`,
`src/test/aiur/regression/engine_control_test.exs`.
**Approach:** preflight calls the handoff RPC through `run_control_rpc`;
the stop sentinel content carries the handoff id; the watchdog consumes a
handoff sentinel without reaping; `kill-server` runs only on the daemon
socket; the agent pidfile is moved to the next instance record.
**Test scenarios:**
- Covers AE5. Daemon without the RPC: exit non-zero, daemon still up, no
  build ran.
- Flag absent: identical command sequence to today (stubbed stop/start
  assertions).
- Handoff stop: agent socket server and listed pids survive; BEAM gone;
  watchdog exits without reaping.
- Rebuild fails after handoff stop: exit with the builder status; record and
  relays remain; message names the orphan timeout.
- Start succeeds, adoption report arrives: one line per agent printed.
**Verification:** engine suites green.

### U2. Status and alerts

**Goal:** the handoff result is visible after the fact.
**Requirements:** KA4-R4, R14.
**Dependencies:** KA3.
**Files:** `src/lib/aiur/orchestrator/status_report.ex`,
`src/lib/aiur/agent_control_cli.ex` (`status --handoff [--json]`),
`src/lib/aiur_web/presenter.ex` (adopted badge on agent rows),
`src/test/aiur/orchestrator/status_report_test.exs`,
`src/test/aiur/agent_control_cli_test.exs`.
**Test scenarios:** status after an adoption lists counts and reasons; JSON
shape stable; no handoff yet prints `none`; alerts emitted once per handoff.
**Verification:** suites green.

### U3. End-to-end test with the fake backend

**Goal:** one test proves AE1 through the real engine.
**Requirements:** AE1, AE3.
**Dependencies:** U1, U2.
**Files:** `src/test/aiur/keep_agents_restart_e2e_test.exs` (new, tagged so
it runs in the integration partition).
**Execution note:** this is the acceptance proof; write it first and keep it
failing until U1 lands.
**Test scenarios:**
- Covers AE1. Boot a daemon with the fake app-server backend and 4 tickets;
  wait until all are mid-turn; run `restart --keep-agents --no-build`;
  assert the same provider pids, every turn completes, zero dispatch events
  and zero claim releases for those tickets, and a new ticket dispatches
  within one poll interval.
- Covers AE3. Same, with the new build declaring a higher `handoff_schema`
  requirement: all fall back, all redispatch.
**Verification:** test green locally and in CI.

### U4. Docs

**Goal:** operators and Executors know when and how to use it.
**Requirements:** R1, R14.
**Dependencies:** U1, U2.
**Files:** `website/docs-app/reference/cli.md`,
`.claude/skills/aiur-run/references/executor.md` (restart guidance: prefer
`--keep-agents`; verify with `status --handoff --json`),
`src/prompts/shared-agent-instructions.md` only if agent-visible behaviour
changes (it should not).
**Test expectation:** none -- documentation.
**Verification:** docs build passes.

## Executor verification recipe (for the docs in U4)

1. Before: `aiurdev agents --json` (save issue, provider pid, session id).
2. `aiurdev restart --keep-agents`.
3. After: `aiurdev status --handoff --json`; every saved issue is in
   `adopted[]` with the same provider pid and session id, or in `fallback[]`
   with a reason.
4. `aiurdev alerts` shows `system.restart.handoff.completed`; no
   `startup_claim` release for adopted tickets.
5. A ready ticket dispatches within one poll interval.

## Definition of Done

U1-U4 merged; e2e test green in CI; one live keep-agents restart on the
aiur fleet recorded in the PR with the before/after JSON.
