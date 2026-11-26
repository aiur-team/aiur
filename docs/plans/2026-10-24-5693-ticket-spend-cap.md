---
title: Per-ticket spend cap
type: feat
date: 2026-10-24
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Per-ticket spend cap

## Goal Capsule

Give an operator a durable USD spend cap for one repository-qualified ticket. When the ticket's recorded, known API-equivalent cost reaches or exceeds that cap, Aiur must persist a distinct `budget_exhausted` outcome, stop the matching agent, prevent redispatch, transition the tracker to `budget-exhausted`, and expose the result through a versioned read contract and a versioned reached-event contract.

Success means all of those effects are ticket-scoped, restart-safe, visible through the dashboard API, and testable without relying on a live provider. The cap is an enforcement control, not a promise of zero overshoot: usage observations arrive after provider work, so the final recorded amount may exceed the threshold by one observation interval.

## Product Contract

### Requirements

#### Cap lifecycle and enforcement

- **R1.** An authenticated operator can set, read, replace, and clear a positive USD cap for exactly one repository-qualified ticket. Money enters and leaves the API as exact decimal strings; binary floating-point values are rejected.
- **R2.** Enforcement compares the cap with the ticket projection's known `api_equivalent_estimate` total. Coverage and authority accompany the amount so partial or unknown pricing is never presented as complete spend.
- **R3.** Setting a cap at or below already-recorded spend exhausts it immediately. A later aggregate update exhausts an active cap when known spend becomes greater than or equal to the cap. Usage belonging to another ticket or repository cannot contribute.
- **R4.** Exhaustion is persisted before any external side effect. Aiur then stops only the matching running agent, blocks its redispatch locally, and writes the terminal tracker state `budget-exhausted`. Failures in stopping, event publication, or tracker transition remain pending and retry after restart.
- **R5.** The end state carried by the read model, stop instruction, and reached event is exactly `budget_exhausted`; it is never collapsed into generic failure, cancellation, or `done`.
- **R6.** Clearing an exhausted cap is allowed only after its terminal tracker transition is confirmed. It then removes the dispatch gate and retained cap record but does not silently reopen the tracker ticket; a deliberate tracker-state change remains the operator's responsibility.

#### Consumer contracts and visibility

- **R7.** The cap read has a versioned JSON Schema in `@aiur/contracts`, carries `contract` and `contract_version`, and scopes itself with both a job/ticket identifier and a repository-qualified ticket identity.
- **R8.** Reaching the cap emits a durable, versioned event whose payload has its own JSON Schema in `@aiur/contracts`, the same ticket/job scope, exact cap and observed-spend strings, coverage/authority, reached time, and `end_state: "budget_exhausted"`.
- **R9.** TypeScript consumers can import generated types for both contracts, and repository fixtures validate against the schemas and the generated declarations.
- **R10.** The dashboard API renders active and exhausted caps without caching stale results, distinguishes not-found, invalid, conflict, and unavailable outcomes, and does not imply that unknown-priced usage counts toward the threshold.

### User flow

1. An authenticated operator sends a positive USD decimal cap to the ticket spend-cap endpoint.
2. Aiur resolves the identifier through the configured tracker to a repository-qualified identity, stores the cap, and evaluates the current usage snapshot.
3. The operator or a TypeScript consumer reads the versioned cap document and sees the threshold, known spend, remaining amount, coverage, authority, and lifecycle state.
4. Each accepted usage projection change re-evaluates active caps. At the boundary, Aiur durably records `budget_exhausted`, gates redispatch, stops the matching agent, publishes the reached event, and writes the terminal tracker state.
5. Retried notifications or daemon restarts preserve the same logical event identity and terminal outcome. Clearing the cap removes the local record but does not mutate the tracker back to an active state.

### Scope boundaries

In scope: USD caps for tickets in the configured GitHub repository; the existing API-equivalent pricing projection; durable local state; agent teardown and dispatch fencing; tracker transition through the shared facade; authenticated HTTP read/write/delete; contracts, generated TypeScript types, fixtures, lifecycle vocabulary, docs, and focused tests.

Out of scope: provider-side preauthorization, per-model or per-request proxy limits, forecasting, multi-currency conversion, organization-wide budgets, automatic ticket reopening, exporting every event-bus topic to remote consumers, and broader tenant/auth redesign. Those remain owned by #5702, #5695, and #5937 where applicable.

## Planning Contract

### Assumptions

- The enforcement basis is the existing ticket projection's known API-equivalent USD amount because provider-reported cost is absent for some supported providers. Unknown-priced usage remains visible through coverage but does not become invented spend.
- The trusted dashboard write boundary is the current Basic Auth plus write-origin and writable-mode pipeline. This ticket does not add a second authorization model.
- Delivery may repeat after a crash, but each exhaustion record owns one durable event id so consumers can deduplicate without losing the event.
- A cap applies to the tracker identity resolved when it is written, not to every repository that happens to reuse the same numeric issue identifier.
- The public API uses `GET`, `PUT`, and `DELETE /api/v1/:issue_identifier/spend-cap`; no CLI surface is added.

### Key technical decisions

- **Known API-equivalent spend is authoritative for enforcement.** The calculation reuses `Aiur.Usage.GroupedScopes` instead of introducing a competing accounting path.
- **Persistence precedes action.** A supervised spend-cap store owns an atomic JSON checkpoint and a small ETS read-through fence. It records terminal state and pending effects before notifying the orchestrator or tracker.
- **Stopping and event publication are independent recoverable effects.** The store synchronously asks the orchestrator to terminate the matching running entry, while a persisted event id drives `publish_persisted/4`. Either can retry without changing the logical outcome.
- **Repository-qualified identity is the isolation boundary.** Bare ticket identifiers are accepted only as lookup input; every stored or emitted record carries the resolved `Aiur.TrackerIdentity`.
- **Exhaustion is a first-class terminal lifecycle.** The wire value is `budget_exhausted`; the tracker slug follows existing label conventions as `budget-exhausted`.

### Failure and recovery model

- Missing aggregate data yields a visible unavailable/unknown read and cannot falsely exhaust a cap.
- A corrupt checkpoint is quarantined, while a future-version checkpoint is retained unchanged. Both fail closed for writes and enforcement and remain visible through store/API health. While the store is unhealthy, dispatch eligibility also fails closed because the daemon cannot prove that a ticket is uncapped or unexhausted.
- If the agent is already absent, stop succeeds idempotently while terminal state, event publication, and tracker transition continue.
- Tracker or event publication failures retain a pending effect with a retry delay. Restart reloads pending effects before normal aggregate handling.
- Repeated aggregate notifications and replayed event delivery cannot create a second exhaustion record or a new logical event id.
- A cap update racing with an aggregate notification is serialized by the store. Once exhausted, replacement is rejected until the operator explicitly clears the record.

## Implementation Units

### U1. Define the independent TypeScript contracts

**Requirements:** R5, R7, R8, R9

**Files:** `packages/aiur-contracts/schemas/`, `packages/aiur-contracts/fixtures/`, `packages/aiur-contracts/src/status.generated.ts`, `packages/aiur-contracts/scripts/generate.mjs`, `packages/aiur-contracts/scripts/validate.mjs`, `packages/aiur-contracts/scripts/check-fixture-types.mjs`, `packages/aiur-contracts/test/`, `packages/aiur-contracts/README.md`.

Add `ticket-spend-cap.v1.schema.json` and `ticket-spend-cap-reached.v1.schema.json`. Both schemas require `contract`, `contract_version: 1`, repository-qualified `ticket`, `job_id`, exact decimal strings, USD currency, coverage, and authority. The reached schema requires `state` and `end_state` to be exactly `budget_exhausted`. Generate and export `TicketSpendCap` and `TicketSpendCapReached`, add conforming fixtures, and prove fixtures are schema-valid and TypeScript-assignable.

### U2. Build the durable cap store and evaluator

**Requirements:** R1, R2, R3, R4, R6, R10

**Files:** new modules under `src/lib/aiur/orchestrator/spend_cap/`, `src/lib/aiur/orchestrator/spend_cap.ex`, `src/lib/aiur/application/children.ex`, `src/lib/aiur/config/paths.ex` if a shared path helper is warranted, `components/orchestration.json`, and focused tests under `src/test/aiur/orchestrator/spend_cap/`.

Create a supervised GenServer after `Aiur.UsageAggregate.Store`. It subscribes to `Aiur.UsageAggregate`, evaluates only active records with `Aiur.Usage.GroupedScopes` and the stored tracker identity, and serializes put/get/delete/evaluate operations. Persist a versioned checkpoint through the shared atomic filesystem writer; reject corrupt or future versions rather than defaulting to empty. Maintain an ETS dispatch view only after checkpoint writes land, providing a nonblocking fence. Run blocking tracker effects under `Aiur.TaskSupervisor`, and serialize their completion messages and checkpoint updates back through the store so GitHub latency cannot stall cap reads or aggregate handling.

Model each side effect explicitly (`stop`, `event`, `tracker_transition`) with pending/completed state. Evaluation writes the exhausted record before running effects. Reads are derived from the same stored cap plus a fresh bounded aggregate snapshot, and report unknown/unavailable pricing without coercing it to zero authority. Reject deletion of an exhausted record until its tracker-transition effect is complete, so clearing a cap cannot reopen a still-active tracker ticket through a transient write failure.

### U3. Stop the agent, fence dispatch, and finish pending effects

**Requirements:** R3, R4, R5, R6, R8

**Files:** `src/lib/aiur/orchestrator.ex` without increasing its current line count, new focused modules under `src/lib/aiur/orchestrator/spend_cap/`, `src/lib/aiur/orchestrator/dispatch_policy.ex`, `src/lib/aiur/orchestrator/lifecycle.ex` only if routing requires it, and direct tests under `src/test/aiur/orchestrator/`.

Add a narrow orchestrator request that uses a key-returning exact-identity lookup in `State.RunningEntries` to match the full stored tracker identity to one running entry and delegates teardown to `AgentTeardown.terminate_running_issue/4`. The key-returning lookup preserves isolation when two repositories use the same numeric issue identifier. The request and its test carry `end_state: :budget_exhausted`; duplicate exact identities fail closed. Consult the store's ETS fence before dispatch so a delayed tracker write cannot restart the ticket, and skip dispatch globally while the spend-cap store is unhealthy because its per-ticket fence cannot be trusted.

For the event effect, reserve one durable event id, persist it into the exhausted record, then call `Aiur.Events.publish_persisted/4` on `ticket.<identifier>.usage.spend_cap_reached`. Reuse the same id after restart until marked delivered. For the tracker effect, use `TicketTransition.write_state/3` with writer attribution `:spend_cap`; treat an already-terminal matching state as success and retry transport failures without reopening the ticket.

### U4. Expose authenticated HTTP operations

**Requirements:** R1, R3, R6, R7, R10

**Files:** `src/lib/aiur_web/router.ex`, new controller/encoder modules under `src/lib/aiur_web/api/usage/`, endpoint configuration seams used by tests, and focused controller/router tests under `src/test/aiur_web/`.

Route `GET`, `PUT`, and `DELETE /api/v1/:issue_identifier/spend-cap`. Keep reads behind dashboard authentication and `Cache-Control: no-store`; keep writes behind the existing `api_write` and writable-mode checks. Resolve identifiers through `Tracker.fetch_issue_states_by_ids/1`, reject ambiguous or unjoinable identities, and pass only resolved identities to the store. Validate a bounded positive decimal string and `currency: "USD"`; return stable 404, 409, 422, and 503 envelopes for absent, already-exhausted replacement, invalid, and unavailable cases.

### U5. Add the terminal tracker lifecycle

**Requirements:** R4, R5, R6

**Files:** `src/lib/aiur/github/labels.ex`, `src/lib/aiur/github/state_policy.ex`, `src/lib/aiur/github/state_labels.ex`, `src/lib/aiur/orchestrator/dispatch_policy/issue_states.ex`, lifecycle schedulers, and their focused tests.

Add `budget-exhausted` to the canonical state-label vocabulary, built-in terminal-state policy, contradictory-label precedence, and lifecycle schedulers. Preserve the underscore form only in the independent API/event/end-state contract. Test label enumeration, terminal recognition, terminal dispatch exclusion, and refusal to restack or propagate blocker pushes after exhaustion. Keeping this safety terminal built in makes enforcement independent of operator terminal-state configuration.

### U6. Document behavior and verify the whole seam

**Requirements:** R1-R10

**Files:** `website/docs-app/guide/dashboard-and-telemetry.md`, `website/docs-app/concepts/ticket-lifecycle.md`, `website/docs-app/concepts/ticket-lifecycle-steps.md`, `website/docs-app/concepts/message-bus.md`, `website/docs-app/index.md`, and cross-seam tests.

Document the endpoint, write authorization, USD/API-equivalent basis, partial-coverage semantics, one-observation overshoot, durable reached event, exact end state, tracker slug, and explicit-clear/no-auto-reopen behavior. Add an integration-style test using injected aggregate, persistence, event, tracker, and teardown seams to prove one ticket reaches the cap while another ticket with the same numeric identifier in another repository remains running.

## Verification Contract

### Automated scenarios

- Boundary: below-cap remains active; exact equality and above-cap become `budget_exhausted`; a cap below existing spend exhausts during `PUT`.
- Isolation: another ticket, another repository with the same issue number, and an unrelated run cannot contribute to or be stopped by the cap.
- Ordering: the durable exhausted checkpoint and ETS fence exist before stop/event/tracker effects run.
- Exact outcome: a mutation from `budget_exhausted` to `failed`, `cancelled`, or `done` fails the stop, read-contract, and reached-event tests.
- Replay/restart: duplicate usage notifications and daemon restart reuse one exhaustion record/event id and do not repeat completed stop effects; pending failures retry.
- Failure paths: unavailable aggregate, corrupt/future checkpoint, event-id failure, publish failure, tracker transport failure, absent runner, invalid money, unknown currency, unjoinable identity, auth/origin failure, and read-only mode all retain truthful outcomes.
- Contract packaging: schemas reject cross-ticket or missing-scope fixtures, generated TypeScript exports compile, and fixture validation includes both new contracts.
- Lifecycle: `budget-exhausted` is a built-in terminal, canonical, and cannot dispatch, restack, or consume blocker pushes.

Run the scoped compile/format/affected-test gate, `mise exec -- mix lint`, bare-assert/receive check, structural gate, package contract build/tests, config/docs guards, and `aiur pre-pr`. For each new behavior test, use an isolated clean worktree to prove the test fails with its production hunk reverted and passes when restored.

### Manual acceptance

This issue workspace cannot run the real reset-capable CLI/TUI smoke. Record the following unchanged in the PR body under `## Local tests` and do not claim it ran here:

`Post-deploy check: from the Executor repository root, launch scripts/aiurdev --test --force --allow-remote, use the authenticated dashboard API to PUT a tiny USD spend cap on a pinned sandbox ticket, drive that ticket through the real TUI until recorded API-equivalent spend reaches the cap, and confirm in the rendered TUI that its agent stops; then GET the cap and confirm state and end_state are budget_exhausted, confirm the ticket has agent:budget-exhausted, and confirm a different ticket remains running (operator: Executor with the real CLI/TUI and pinned GitHub sandbox tickets).`

## Definition of Done

- Every R1-R10 requirement maps to implemented code, tests, generated package artifacts, and current documentation.
- Exhaustion is durably visible and exactly named `budget_exhausted` across the stop request and both consumer contracts; the tracker uses `budget-exhausted`.
- A stopped ticket cannot redispatch during tracker-write delay or after daemon restart, while unrelated tickets remain unaffected.
- The reached event and cap read are versioned, fixture-backed, TypeScript-exported, repository-qualified, and carry `contract` plus `contract_version`.
- All automated local gates pass on the pushed head; mutation evidence and the unrun post-deploy CLI/TUI check are recorded truthfully in the PR body.
- The draft PR is self-reviewed, marked ready, verified non-draft, and handed to the full required CI set.
