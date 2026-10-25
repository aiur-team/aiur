---
title: Confirmed ticket cancellation API
date: 2026-10-24
type: feat
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: legacy-requirements
origin: https://github.com/aiur-team/aiur/issues/5696
---

# Confirmed ticket cancellation API

## Goal Capsule

Add a ticket-scoped Usage API cancellation operation that does not report success until Aiur has observed the exact running agent process exit. External TypeScript consumers receive a versioned JSON result with an opaque process handle, process status, exit status, and observation time. A bounded non-exit reports `still_running` or `kill_failed`, never success.

## Product Contract

- R1. `POST /api/v1/:issue_identifier/cancel` uses the existing authenticated, writable API boundary and only targets the named ticket.
- R2. A successful response proves the exact agent generation that was selected for cancellation exited; a tracker label transition by itself is insufficient.
- R3. Every attempt that reaches the process-stop stage returns a versioned `aiur.ticket_cancel` result whose process evidence includes a handle, status, nullable exit status, and observation time. Precondition and tracker failures use the API's standard error envelope and never claim process exit.
- R4. The exit wait is bounded. If the process remains alive, the result is `still_running`; if the stop action itself fails and the process remains alive, the result is `kill_failed`.
- R5. The JSON Schema, golden fixture, generated TypeScript type, and package validation ship together in `@aiur/contracts`.
- R6. The API does not add a bulk-cancel operation, event-stream delivery, a new CLI command, or a new cancellation state machine.

## Planning Contract

### Key technical decisions

1. Monitor before stop. Capture and monitor the running BEAM pid before invoking teardown, then wait for its `DOWN` message. `Process.alive?/1` alone is not sufficient evidence because it loses the exit reason and can race.
2. Match the exact generation. Carry the selected pid/reference through the tracker-write callback and refuse to stop a replacement process if the running entry changed meanwhile. Represent that race as the versioned `generation_changed` process status with HTTP 409.
3. Keep failure truthful. A successful tracker transition followed by a non-exit returns a non-success process result and keeps the running entry available for later reconciliation; only observed exit performs terminal teardown and removes the entry.
4. Reuse the current write boundary. The controller delegates to the orchestrator client, while tracker I/O and the bounded exit wait remain outside the GenServer through staged calls. The caller installs its monitor before the serialized callback fences and stops the selected generation; a final short callback reconciles observed exit. A non-exit leaves the entry marked `cancel_requested` so a later ordinary `DOWN` performs terminal cleanup without scheduling a retry.
5. Use a single discriminated contract. `process.status` is one of `exited`, `still_running`, `kill_failed`, or `generation_changed`. Every variant carries a non-null `observed_at`; `exit_status` and `exited_at` are non-null only for `exited`. `process.handle` is the running entry's opaque `telemetry_attempt_id` (with a bounded internal fallback for legacy entries), and `exit_status` is `Aiur.Signal.reason_class/1` rather than a raw BEAM term. Timestamps are RFC 3339 UTC. HTTP 200 is reserved for observed exit, while non-exit outcomes use a conflict response with the same versioned result body.
6. Fail closed on ambiguous identifiers. If more than one running entry shares the requested display identifier, return `ambiguous_identifier` before tracker or process mutation; never pick the first match.

## Implementation Units

### U1. Add the bounded process-exit barrier

Goal: terminate one selected running agent and prove whether that process exited.

Files:
- Create `src/lib/aiur/orchestrator/cancellation.ex`.
- Modify `src/lib/aiur/orchestrator/agent_teardown.ex`, `src/lib/aiur/orchestrator/calls.ex`, `src/lib/aiur/orchestrator/client.ex`, and the cancellation-aware branch of `src/lib/aiur/orchestrator/retry_engine/agent_down.ex`.
- Add focused tests under `src/test/aiur/orchestrator/`.

Approach:
- Resolve the named running entry, stage the tracker transition, and preserve its pid/ref as the generation fence.
- Reject ambiguous display identifiers before staging tracker I/O, with a collision test proving neither process is stopped.
- Add a non-removing `AgentTeardown.request_task_stop/1` returning `:ok | {:error, reason}`; install the caller monitor before invoking it and wait only up to the configured bound without blocking the orchestrator mailbox.
- On `DOWN`, run the existing terminal teardown and return serialized exit evidence.
- On timeout, demonitor without removing the running entry, mark it `cancel_requested`, and return `still_running`; distinguish an explicit stop failure as `kill_failed`. A later `DOWN` for that marked entry terminal-cleans without retry.

Test scenarios:
- A normal task exits and returns its opaque handle, exit status, and deterministic timestamp.
- A fake process that ignores the injected stop signal remains in state and returns `still_running` after the bound.
- A failed stop action with a live process returns `kill_failed`.
- A replacement generation is never stopped by a stale callback and returns `generation_changed`.
- A marked non-exit that dies later is removed without entering the ordinary retry path.

### U2. Expose the authenticated cancellation endpoint

Goal: make the confirmed result available to external API consumers.

Files:
- Create `src/lib/aiur_web/controllers/ticket_cancel_api_controller.ex`.
- Modify `src/lib/aiur_web/routes/api.ex`.
- Modify `src/test/aiur_web/router_table_test.exs`.
- Add a focused controller test in a new test file.

Approach:
- Route `POST /api/v1/:issue_identifier/cancel` through the existing dashboard auth, API-write CSRF, and writable-mode pipelines.
- Return the contract body with 200 only for `exited`; return the same body with 409 for `still_running`, `kill_failed`, or `generation_changed`; map ambiguous lookup, tracker, timeout, and orchestrator availability errors consistently without claiming exit.

Test scenarios:
- The route is discoverable only as POST and the exact ticket identifier is passed to the orchestrator.
- An observed exit returns 200 with contract evidence.
- A still-running process returns 409 and cannot be mistaken for success.

### U3. Publish and document the versioned contract

Goal: give TypeScript consumers a checked cancellation result type.

Files:
- Add `packages/aiur-contracts/schemas/ticket-cancel.v1.schema.json` and matching fixture.
- Modify the package generator, validator, fixture type-checker, README, and generated TypeScript outputs.
- Modify `src/test/aiur/status_contracts_golden_test.exs` and contract package tests.
- Modify `website/docs-app/guide/dashboard-and-telemetry.md`.

Approach:
- Add `TicketCancel` to `StatusContract` with a discriminated process-status union.
- Generate the checked-in TypeScript declaration and prove the Elixir encoder reproduces the golden fixture.
- Document authentication, request path, success/failure statuses, and the difference between tracker cancellation and observed process exit.

## Verification Contract

- Run format, warnings-as-errors compilation, the affected-test selector, and every reported focused test command with `--max-cases 4`.
- Run the `@aiur/contracts` generation, validation, and package tests used by its existing scripts.
- In a separate clean worktree, revert each production behavior hunk guarded by a new test and prove the corresponding test fails, then restore and prove it passes.
- Run `mise exec -- mix lint`, `python3 scripts/check-bare-assert-receive.py`, the structural gate against `origin/main`, `aiur pre-pr`, and pre-handoff guards.
- Post-deploy check: call `POST /api/v1/<running-ticket>/cancel` from an authenticated external client and confirm the response names that ticket's exited process handle, exit status, and exit time (operator: live Aiur instance).

## Risks and Dependencies

- The barrier must remain bounded even when a stop seam does nothing; the timeout test is the acceptance guard.
- Tracker state can change before process termination. The response therefore reports tracker state and process status separately and never promotes a process timeout to HTTP success.
- A running generation may be replaced between network I/O and finalization. The pid/ref fence converts that race to an explicit conflict.
- Issue #5695 may later emit these results, but this ticket has no dependency on event streaming because the synchronous response satisfies the consumer contract.

## Definition of Done

- An authenticated external caller can cancel exactly one running ticket and receive a versioned process result.
- HTTP success is impossible without an observed `DOWN` for the selected process.
- The non-exit fake-process test fails if cancellation is changed to report success after only a label transition.
- The schema, fixture, generated TypeScript type, package docs, API docs, and focused Elixir tests all pass.
- The PR includes truthful local-test evidence and the exact post-deploy check without claiming it ran in the agent workspace.
