---
date: 2026-06-23
topic: background-control-plane-consistency
---

# Background Control Plane Consistency

## Summary

Background Aiur runs must keep the operator control plane consistent: if `status` can report a live wave, `agents`, `pause`, `resume`, `message`, and `set` must target the same running node. If the node is gone, every control command must fail consistently or cleanup must remove the stale session that made the run look alive.

---

## Problem Frame

During the Actions Phase 1 wave, `aiurdev status` showed active tickets while `aiurdev agents` and `aiurdev resume --all` reported no running node. The operator could not resume paused agents, and the five-minute monitoring loop missed the control-plane break because one command still looked healthy.

The launcher was validating background startup through tmux liveness, which is weaker than proving the distributed node is ready to answer control RPCs. A background run could leave a detached tmux session and bookkeeping alive after the BEAM exited, so launch and status surfaces could disagree about whether the session was usable.

Validation also exposed a second safety gap: `aiurdev stop` reaped every BEAM launched from the same release directory. Multiple keyed project instances can share one dev release, so stopping a temporary smoke run could terminate a sibling workflow.

---

## Requirements

**Control-plane truth**

- R1. All operator control commands for one project root must derive the same node, tmux session, and socket identity.
- R2. `status` and `agents` must not present stale wave state as usable when the BEAM node is not reachable.
- R3. `resume`, `pause`, `message`, and `set` must fail with the same node-state classification as `status` and `agents`.

**Background cleanup**

- R4. Background mode must reap its private tmux server and recorded agent process trees when the BEAM exits after startup.
- R5. Background startup must not report success until the expected node can answer the control RPC.

**Safety**

- R6. Cleanup must stay scoped to the current instance identity and must not kill another project root's Aiur session.
- R7. `aiur stop` remains an operator escape hatch for stale background sessions while staying scoped to the current instance.

---

## Key Decisions

- **Extend the existing watchdog to background mode.** Foreground already has a crash reaper that watches the BEAM and cleans up tmux plus agent pidfiles. Background should use the same primitive instead of adding a second status-specific fallback.
- **Probe control readiness before declaring bg startup success.** The launcher currently checks that tmux survived briefly; that is weaker than proving the distributed node can answer control commands. Background startup should wait for `Aiur.Orchestrator.status/2` through release RPC or surface captured startup output.
- **Scope all BEAM reaping to the node identity.** Release-directory pgrep can terminate sibling instances. Cleanup should target `AIUR_RELEASE_NODE` instead.
- **Keep identity derivation unchanged.** The per-instance identity work already keys node, session, and socket by project root. This fix preserves that contract and focuses on cleanup/readiness.

---

## Acceptance Examples

- AE1. Given a background run whose BEAM crashes after registering, when the watchdog observes the exit, then Aiur kills only that instance's tmux server and recorded agent process trees.
- AE2. Given a background launch whose tmux session starts but the control plane never answers, when the grace window expires, then `aiur --bg` exits non-zero and prints startup capture instead of claiming success.
- AE3. Given a healthy background run, when the operator runs `status`, `agents`, and `resume --all` from the same project root, then all commands target the same node identity.
- AE4. Given two keyed Aiur instances launched from the same release, when one runs `aiurdev stop`, then only that instance's node is reaped.

---

## Scope Boundaries

- Do not redesign per-instance identity.
- Do not add persistent status storage.
- Do not change the meaning of `--bg --interactive`.
- Do not attempt to make the default user tmux socket authoritative.

---

## Sources / Research

- Issue #492: `aiurdev status` sees bg agents while RPC commands report no running node.
- Issue #494: `status` sees paused agents but `resume` cannot contact the running node.
- Issue #495: `aiurdev stop` can terminate sibling release instances.
- Existing identity requirements: `docs/brainstorms/2026-06-22-per-instance-aiur-identity-requirements.md`.
- Existing implementation plan: `docs/plans/2026-06-22-002-fix-per-instance-aiur-identity-plan.md`.
- Launcher implementation: `packaging/npm/aiur-cli/libexec/aiur-engine.sh`.
