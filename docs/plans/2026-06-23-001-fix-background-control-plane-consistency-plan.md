---
title: "fix: Background control plane consistency"
type: fix
date: 2026-06-23
origin: docs/brainstorms/2026-06-23-background-control-plane-consistency-requirements.md
issues: [492, 494, 495]
---

# fix: Background control plane consistency

## Summary

Make `aiur --bg` prove that the expected control plane is reachable before it reports success, then keep cleanup scoped to that instance's node identity so stale sessions and sibling workflows cannot diverge.

---

## Problem Frame

The launcher currently validates background startup by checking that the tmux session survived a short grace window. That can leave an operator with a detached tmux session and stale-looking status surfaces even when the distributed node is gone or never became reachable.

The same validation pass found that `aiurdev stop` still killed every BEAM using the current release dir. That breaks the per-instance contract when two keyed runs share one dev release.

---

## Requirements

- R1. Background startup reports success only after the expected node can answer the control RPC.
- R2. Background startup exits non-zero with captured startup output when tmux survives but control readiness never arrives.
- R3. Background runs arm a BEAM-death watchdog after startup, just as foreground runs do.
- R4. The watchdog cleanup remains scoped to the instance socket and agent pidfile.
- R5. `aiurdev stop` and foreground cleanup reap BEAMs by node identity, not shared release directory.
- R6. Regression tests cover bg startup readiness, bg watchdog wiring, structured activity formatting, and cross-instance stop safety.

---

## Key Technical Decisions

- **Readiness source: release RPC to `Aiur.Orchestrator.status/2`.** EPMD registration is not enough; the operator needs the control plane to answer.
- **Background watchdog uses the existing reaper.** `start_beam_death_watchdog` already calls `reap_aiur_agents` with the instance socket and pidfile. Background mode should arm it only after readiness succeeds and seed it as already seen so a post-readiness crash is detected.
- **Foreground and stop cleanup target node identity.** Foreground teardown and `aiurdev stop` must not pgrep by release dir because sibling instances share dev releases.

---

## Implementation Units

### U1. Gate background success on control readiness

- **Goal:** Replace the tmux-only background grace check with a helper that waits for both tmux session liveness and a successful control RPC.
- **Requirements:** R1, R2.
- **Dependencies:** none.
- **Files:** `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, `src/test/aiur_engine_test.exs`.
- **Approach:** Add a shell helper that loops during startup, keeps the existing tmux-death failure path, and returns success only when release RPC proves `Aiur.Orchestrator.status/2` can answer.
- **Patterns to follow:** Existing startup-capture failure output and release RPC control commands.
- **Test scenarios:** tmux dies before readiness; control probe eventually succeeds; control probe stays down until timeout.
- **Verification:** Targeted engine tests prove the helper distinguishes tmux liveness from node readiness.

### U2. Arm a detached watchdog for background runs

- **Goal:** Make a bg run clean itself up when the BEAM exits after launch.
- **Requirements:** R3, R4.
- **Dependencies:** U1.
- **Files:** `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, `src/test/aiur_engine_test.exs`.
- **Approach:** In the background branch, start `start_beam_death_watchdog` after readiness succeeds and disown it. Seed initial-seen so a crash immediately after readiness is still observed.
- **Patterns to follow:** Foreground watchdog call and `reap_aiur_agents`.
- **Test scenarios:** bg branch starts the watchdog with instance socket and agent pidfile; successful startup disowns it; seeded watchdog reaps when the node disappears.
- **Verification:** Engine source tests and the existing process-reaping regression cover cleanup mechanics.

### U3. Scope stop and teardown to the instance node

- **Goal:** Prevent `aiurdev stop` and foreground teardown from killing sibling project instances that share a release.
- **Requirements:** R5.
- **Dependencies:** none.
- **Files:** `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, `src/test/aiur_engine_test.exs`, `src/test/aiur/regression/shutdown_cleanup_test.exs`.
- **Approach:** Remove release-dir-wide BEAM pgrep from stop and foreground cleanup. Use `kill_beams_matching "-name ${AIUR_RELEASE_NODE}"` or `_session_node`.
- **Patterns to follow:** Existing node-name orphan reaper.
- **Test scenarios:** A fake sibling BEAM with the same release path but different node survives `cmd_stop`.
- **Verification:** Targeted engine regression plus shutdown cleanup source regression.

### U4. Validate the launched behavior

- **Goal:** Prove the fix through focused tests and, if feasible, a short real bg start/stop smoke.
- **Requirements:** R1-R6.
- **Dependencies:** U1, U2, U3.
- **Files:** `src/test/aiur_engine_test.exs`.
- **Approach:** Run targeted Elixir tests for the launcher, then run the existing reaper regression if shell dependencies are available. Build the release before opening the PR.
- **Patterns to follow:** `src/test/regression/aiur-agent-reap.sh`, `src/test/aiur/regression/instance_identity_test.exs`.
- **Test scenarios:** unit-level readiness, watchdog wiring, stop cleanup, and real isolated `--bg` status/agents/stop.
- **Verification:** `mix test test/aiur_engine_test.exs`, `scripts/aiurdev build`, and `make all`.

---

## Scope Boundaries

- No changes to issue orchestration state.
- No new status cache or fallback display path.
- No changes to agent pause/resume semantics.

---

## Risks & Dependencies

- A node-readiness timeout that is too short can make slow starts fail. Use the existing startup grace shape and keep diagnostics from the captured startup output.
- Background watchdogs must not accumulate. They exit after seeing their watched BEAM disappear, and stop cleanup remains available for stale sessions.

---

## Sources / Research

- `packaging/npm/aiur-cli/libexec/aiur-engine.sh` contains `run_session`, `probe_control_liveness`, `start_beam_death_watchdog`, and `cmd_stop`.
- `src/test/aiur_engine_test.exs` already tests launcher identity and control RPC behavior.
- `src/test/regression/aiur-agent-reap.sh` already exercises the process-tree reaper and BEAM-death watchdog.
