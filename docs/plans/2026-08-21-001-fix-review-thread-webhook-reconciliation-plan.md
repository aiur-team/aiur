---
title: "fix: Reconcile review-thread webhook changes"
date: 2026-08-21
type: fix
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Fix review-thread webhook reconciliation

## Goal Capsule

- Route GitHub `pull_request_review_thread` state changes into Aiur's existing comment/review reconciliation path without inventing a second event shape.
- Preserve polling as the loss-recovery path and keep resource/version suppression as the only safe duplicate-event filter.
- Ship code, focused tests, and the operator-facing webhook event requirement together.

## Product Contract

### Problem Frame

Aiur accepts and proves GitHub webhook delivery, but `pull_request_review_thread` is currently unsupported by the normalizer. A thread resolved or reopened without a new review comment therefore waits for the next scheduled GraphQL reconciliation sweep.

The repository's measured contract in `docs/measurements/2026-08-17-comment-poll-webhook-reconciliation.md` rules out standing down reconciliation polls in webhook mode: deliveries can be lost during daemon restarts, and skipping the sweep would silently lose CI and comment state. `CommentPollBatch` also no longer reads issue comments, so suppressing it for `issue_comment` deliveries would remove PR discovery and review-state reads rather than eliminate duplicate comment fetches.

### Requirements

- R1. Accept `resolved` and `unresolved` `pull_request_review_thread` deliveries for a tracked repository.
- R2. Map each valid delivery to the Aiur ticket named by the pull request head branch and request reconciliation through the existing webhook nudge path.
- R2a. Preserve a review-thread reconciliation request that arrives while a comment poll is already running, and force the named ticket into the next comment poll without ordinary discovery caps or freshness omission.
- R2b. Treat a later `unresolved` transition as a new review-thread generation so reopening the same thread can wake the agent again while redeliveries of one transition remain suppressed.
- R3. Reject malformed payloads, drop unsupported actions, and drop pull requests that do not map to an Aiur ticket without raising.
- R4. Document `pull_request_review_thread` as a required GitHub webhook event while retaining polling as reconciliation and loss recovery.
- R5. Do not suppress `CIPollBatch`, `CommentPollBatch`, or the review-thread safety sweep based only on repo-level webhook transport.

## Planning Contract

### Key Technical Decisions

- KTD1. Normalize review-thread state changes to `{:reconcile, hint}`. The poller owns authoritative unresolved-thread classification and event publication; the webhook should accelerate that producer rather than publish a parallel topic.
- KTD2. Reuse pull-request head-ref ticket resolution. GitHub's official payload requires `pull_request` and `thread`, so the existing `TicketBranch` mapping remains the canonical identity boundary.
- KTD3. Keep reconciliation polling. Repo-level webhook health proves ingress, not subscription to every event class, and observed delivery loss makes transport-wide suppression correctness-breaking.
- KTD4. Route review-thread hints to a dedicated comment-reconciliation queue instead of the generic debounced poll-cycle message. The queue is claimed by one asynchronous comment poll at a time; arrivals during that poll remain queued for an immediate follow-up.
- KTD5. Deposit the webhook's thread transition in `ResourceStore` and include its generation in the poller's thread dedup/version identity. The payload timestamp is preferred; the admitted delivery id is the fallback when GitHub supplies a null timestamp.

### Scope Boundaries

- In scope: semantic admission identity, normalizer support, a lossless targeted comment-reconciliation queue, reopen-safe thread identity, webhook-tail behavior tests, and the GitHub API documentation event list.
- Out of scope: mutating the live repository hook, changing poll cadence, adding event-class subscription discovery, or projecting aggregate CI/review state directly from individual deliveries.

## Implementation Units

### U1. Normalize review-thread state changes

- **Goal:** Convert valid thread resolution changes into an immediate reconciler nudge.
- **Files:** Modify `src/lib/aiur/webhooks/event_key.ex`, `src/lib/aiur_web/controllers/github_webhook_controller.ex`, `src/lib/aiur/events/github_webhook/normalizer.ex`, and `src/lib/aiur/events/github_webhook.ex`; test in their existing focused test files.
- **Requirements:** R1, R2, R3, R5; KTD1, KTD2, KTD3.
- **Approach:** Add a semantic event key for timestamped thread transitions, propagate the admitted delivery id to the publish tail, normalize `resolved` and `unresolved` with the thread node id and transition generation, and send review-thread hints to the dedicated orchestrator message while retaining the generic debounce for CI and issue-state hints.
- **Test scenarios:** A resolved delivery returns a review-thread reconcile hint; an unresolved delivery does the same; repeated semantic transitions dedupe while a later timestamp differs; a null timestamp preserves delivery-id admission; an unknown action drops; a missing thread errors; a non-ticket head ref drops; an unsupported repository remains filtered by the existing tracked-repo gate.
- **Verification:** The focused webhook tests name and execute every scenario.

### U2. Retain and target reconciliation requests

- **Goal:** Guarantee that a review-thread delivery causes a comment poll for its ticket even when another asynchronous comment poll is already running.
- **Files:** Modify `src/lib/aiur/orchestrator/state.ex`, `src/lib/aiur/orchestrator.ex`, and `src/lib/aiur/orchestrator/comment_polling.ex`; test in the existing orchestrator/comment-polling regression suite.
- **Requirements:** R2, R2a, R5; KTD1, KTD4.
- **Approach:** Queue normalized ticket ids in orchestrator state, claim and clear that queue only when spawning a dedicated forced-target comment poll, retain arrivals during the in-flight poll, and start an immediate follow-up after completion. Forced reconciliation bypasses normal target discovery/caps but still uses the existing comment batch and publisher.
- **Test scenarios:** An idle orchestrator starts a targeted poll; a hint received during an in-flight poll remains queued; completion starts the queued follow-up; duplicate hints coalesce; a frozen/non-GitHub poller retains or safely ignores work according to existing lifecycle boundaries.
- **Verification:** Focused orchestrator tests observe the real state transitions and the named target in the poll seam.

### U3. Make reopened threads a new generation

- **Goal:** Wake again when the same review thread is reopened without weakening duplicate suppression for one transition.
- **Files:** Modify `src/lib/aiur/events/github_webhook/deposit.ex`, `src/lib/aiur/events/github_comments_poller.ex`, and `src/lib/aiur/events/github_keys.ex`; test in the existing deposit, poller, and webhook/poll reconciliation suites.
- **Requirements:** R2b, R5; KTD3, KTD5.
- **Approach:** Deposit a compact thread-transition marker before reconciliation. When the poller publishes the unresolved thread's latest comment, derive its dedup key and resource version from both the stable thread id and the stored transition generation; ordinary later sweeps reuse that generation.
- **Test scenarios:** One unresolved transition publishes once across forced and ordinary sweeps; a resolved-then-unresolved transition with the same latest comment publishes again; a redelivery of the same unresolved generation remains suppressed; missing transition metadata falls back to the existing thread identity.
- **Verification:** The reconciliation test runs the webhook and poll paths through the real `ResourceStore` and `Publisher` gates.

### U4. Document the required event and safety boundary

- **Goal:** Make operator setup match the newly supported delivery contract without implying polling can stop.
- **Files:** Modify `website/docs-app/apis/github.md`; update its owning documentation test to assert the new event name.
- **Requirements:** R4, R5; KTD3.
- **Approach:** Add the supported/required GitHub hook event list near the existing optional-webhook setup table and state that review-thread state changes accelerate reconciliation while polling remains the recovery path.
- **Test scenarios:** The docs test asserts the new event name and the existing polling/reconciliation language remains present.
- **Verification:** The affected website documentation test passes.

## Verification Contract

- Elixir compilation succeeds with warnings treated as errors.
- Formatting produces no diff.
- `mix aiur.affected_tests` identifies the focused root-runnable test set, and every emitted test command runs with `--max-cases 4`.
- The webhook normalizer tests exercise valid, malformed, unsupported-action, and unmapped-ticket deliveries.
- Orchestrator tests prove a reconcile request is not swallowed by an in-flight comment poll.
- Webhook/poll reconciliation tests prove a reopened thread with an unchanged latest comment wakes once for the new transition.
- Documentation tests cover the new required event name.

## Definition of Done

- Valid review-thread resolution changes trigger a targeted existing reconciliation tail immediately or remain queued behind its current in-flight run.
- Invalid or irrelevant deliveries fail safely without publication or process failure.
- A reopened thread can wake again, while one transition still deduplicates across webhook and poll paths.
- Scheduled polling remains the loss-recovery path; webhook mode does not suppress safety sweeps.
- Operator documentation names `pull_request_review_thread` and explains its role.
- Scoped compile, format, affected tests, self-review, and CI handoff are complete against `main`.
