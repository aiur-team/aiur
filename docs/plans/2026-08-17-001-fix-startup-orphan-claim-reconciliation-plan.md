---
title: Reconcile orphaned agent claims after restart
date: 2026-08-17
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Reconcile orphaned agent claims after restart

## Goal Capsule

- Restore every `agent:in-progress` ticket whose owning runtime disappeared across a daemon restart to `agent:todo` automatically.
- Preserve `agent:in-progress` for tickets with positive evidence of a live runtime in the current orchestrator registry.
- Make the orphan state and its recovery visible in logs, status output, and existing fleet-starvation diagnostics.
- Keep the change inside tracker/orchestrator lifecycle state; do not introduce persistence for agent processes or use `rework` as a recovery state.

---

## Product Contract

### Problem Frame

Agent ownership is durable in tracker labels while the owning process is not. After a restart, stale `agent:in-progress` labels can make work appear active even though no runtime owns it, leaving operators with an idle fleet and misleading `awaiting-dispatch [waiting=active]` output.

### Requirements

- R1. On the first successful post-boot candidate poll, compare `in-progress` tickets with the orchestrator's current live runtime registry.
- R2. Transition each `in-progress` ticket without a matching live runtime to `todo` with an expected-state guard.
- R3. Never transition an `in-progress` ticket whose matching runtime is live.
- R4. Log and alert successful releases, and surface unreconciled orphan claims distinctly in status.
- R5. Reuse the existing fleet-capacity-starved episode for `0/N` plus dispatchable work, including the no-binding diagnosis.
- R6. No startup reconciliation path may write `rework`.

### Scope Boundaries

- In scope: one-shot startup reconciliation, state projection, CLI-visible reason text, and focused regression tests.
- Out of scope: changing normal agent teardown/retry semantics, persisting runtime registries across restarts, or redefining review rework.

### Acceptance Examples

- AE1. Given a first post-boot poll containing an `in-progress` ticket and an empty runtime registry, reconciliation compare-and-sets the ticket to `todo` and records visible release evidence.
- AE2. Given the same ticket with a matching live runtime entry, reconciliation performs no tracker write.
- AE3. Given an orphan before reconciliation completes, status classifies it as an orphaned claim rather than healthy active waiting.
- AE4. Given zero live agents, free capacity, and ready work for one poll interval, the existing fleet-starvation alert names the contradiction and reports no binding constraint.

---

## Planning Contract

- KTD1. Run reconciliation at the first successful candidate poll, immediately after candidate/running-state refresh and before normal dispatch. This is the first point where tracker evidence and the current-generation runtime registry are both available.
- KTD2. Use `Tracker.update_issue_state(identifier, "todo", expected_state: "in-progress")` so concurrent operator or agent transitions win instead of being overwritten.
- KTD3. Track the one-shot boot attempt explicitly in orchestrator state. A tracker write failure remains diagnosable and is retried on a later poll; completion occurs only after every candidate is either protected by a live runtime or successfully released.
- KTD4. Represent pre-reconciliation orphan status as a dedicated waiting reason. Keep the existing released-claim machinery reserved for runtime retry releases, since startup recovery changes the tracker state immediately and has different semantics.
- KTD5. Extend the existing `system.fleet.capacity.starved` proof for the zero-agent/no-binding case instead of adding a competing alert episode.

Sequence: add the pure reconciliation boundary and tests, wire it into the poll before dispatch, then extend status rendering and zero-agent diagnostics coverage.

---

## Implementation Units

### U1. One-shot startup claim reconciliation

- **Goal:** Detect tracker-owned `in-progress` tickets without a live current-generation runtime and safely release them to `todo` before dispatch.
- **Files:** `src/lib/aiur/orchestrator/state.ex`, `src/lib/aiur/orchestrator/dispatcher.ex`, and a focused module under `src/lib/aiur/orchestrator/` if separation keeps the poll readable.
- **Patterns:** `Aiur.Orchestrator.MergedTicketReconciler` for injected compare-and-set writes and result threading; `Aiur.Orchestrator.Reconciler` for current registry checks.
- **Test file:** `src/test/aiur/orchestrator/dispatcher_test.exs` or a sibling focused reconciler test.
- **Test scenarios:** orphan writes exactly `todo` with expected `in-progress`; live runtime performs no write; non-`in-progress` tickets perform no write; failed writes remain eligible for retry and are surfaced; successful recovery logs and alerts.

### U2. Status and fleet diagnostics

- **Goal:** Distinguish a durable orphan claim before reconciliation and prove the idle-fleet contradiction remains operator-visible.
- **Files:** `src/lib/aiur/orchestrator/waiting_reason.ex`, `src/lib/aiur/orchestrator/status_report.ex`, `src/lib/aiur/orchestrator/status_reason.ex`, and `src/lib/aiur/agent_control_cli.ex` only where presentation requires it.
- **Test files:** `src/test/aiur/orchestrator/waiting_reason_test.exs`, `src/test/aiur/orchestrator/status_report_test.exs`, `src/test/aiur/agent_control_cli_test.exs`, and `src/test/aiur/orchestrator/issue_sync_test.exs` as affected.
- **Test scenarios:** idle `in-progress` maps to `orphaned_claim`; a live running `in-progress` row remains active; CLI text names the orphan; a `0/N` ready fleet emits `system.fleet.capacity.starved` with `binding constraint=no binding constraint identified`.

---

## Verification Contract

- `cd src && mise exec -- mix compile --warnings-as-errors`
- `cd src && mise exec -- mix format --check-formatted`
- `cd src && mise exec -- mix aiur.affected_tests`, followed by every printed `mix test --max-cases 4` invocation.
- Inspect the final diff for any `rework` write introduced by startup reconciliation.
- Manual `aiurdev --test` is intentionally not run from this issue workspace because the repository guard forbids agent-workspace sandbox resets; focused lifecycle tests provide the permitted local proof.

---

## Definition of Done

- Every orphaned startup claim transitions to `todo` without manual intervention.
- A live runtime protects its `in-progress` tracker state.
- Recovery is compare-and-set safe, logged, and alerted.
- Status names orphaned claims before reconciliation.
- Zero-live-agent starvation is diagnosed through the existing fleet alert.
- Scoped compile, format, and affected tests pass; the draft PR is self-reviewed against all requirements.
