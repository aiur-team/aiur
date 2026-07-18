---
title: "fix: Fence stale lifecycle transitions"
type: fix
status: completed
date: 2026-07-17
issue: 1237
---

# Fence Stale Lifecycle Transitions

## Summary

Prevent an old agent turn or an in-flight CI poll from replacing a newer
Executor rework contract with `ci-wait`, `human-review`, or another handoff
state. Add an expected-state compare immediately before GitHub label swaps,
retain an orchestrator-owned handoff fence while authoritative input is queued
or merely claimed, and release that fence only when the provider accepts the
input. Expose the same distinction in operator evidence so accepted input is
reported as queued until provider acknowledgement arrives.

## Problem Frame

- Agent chat currently broadcasts accepted Executor text immediately, while
  `OperatorWaitLog.record_delivered/2` runs when a queue item is claimed. Neither
  proves that the provider accepted the input.
- A claimed queue item is internally named `:delivered` before Codex or Claude
  responds to `turn/start`; the real provider acknowledgement already exists in
  the app-server safe-checkpoint callback and the REPL injection callback.
- GitHub state updates fetch the issue before swapping labels, but callers
  cannot state which tracker state they observed. CI therefore fetches a
  `human-review` or `ci-wait` issue, performs a potentially long poll, and can
  overwrite a newer `rework` label with its stale result.
- Active trusted comments retain urgent queue priority, but `CommentWake`
  deliberately leaves a working entry unchanged. No orchestrator state records
  that the newer instruction must be delivered before the runner may hand off.
- Agent-written label changes bypass the tracker facade. The single-owner
  orchestrator must therefore reject a newly observed handoff state while its
  local authoritative-input fence remains outstanding, in addition to fencing
  its own tracker writes.

## Requirements

- **R1.** A tracker transition that supplies an expected state must fail
  without mutating labels when the immediately fetched GitHub state differs.
- **R2.** CI result and timeout transitions must carry the state observed when
  the poll began, so a concurrent `rework` epoch wins.
- **R3.** Accepted Executor messages and trusted, non-benign review comments for
  a running agent must open or extend an orchestrator-owned handoff fence.
- **R4.** `ci-wait`, `human-review`, terminal, and other non-active handoffs
  observed while that fence is outstanding must not pause, deactivate, or stop
  the runner; the authoritative pre-handoff state must be restored with an
  expected-state write.
- **R5.** Queue claim must not release the fence. Only a successful provider
  turn-start/paste acknowledgement for the matching queue item may release it;
  failed or retired deliveries remain fenced and are requeued or failed by the
  existing settlement rules.
- **R6.** Operator evidence must label accepted input as queued and record a
  separate provider-delivered acknowledgement, including the queue request ID.
- **R7.** Existing trusted-comment `priority: :now` and interrupt behavior,
  decision-correlation durability, one-writer orchestration, and tracker label
  vocabulary remain unchanged.

## Assumptions

- Every accepted Executor chat message is authoritative enough to delay a
  lifecycle handoff until it reaches the provider; this safely covers explicit
  rework instructions without parsing message prose.
- For trusted comment digests, the event ID is the durable identity when
  present and the queue item ID is the delivery identity. Duplicate event
  routing may extend the same fence but must not create an unacknowledgeable
  epoch.
- The expected-state compare is a GitHub label-state guarantee. A writer that
  requests a fence must fail closed when its configured adapter or client does
  not support the three-argument transition; only unfenced two-argument calls
  may retain legacy behavior.
- A provider acknowledgement means the provider accepted the input/turn. It
  does not imply that the model completed or obeyed the instruction.

## Scope Boundaries

### In scope

- Tracker expected-state option and GitHub pre-mutation validation
- CI lifecycle callers that transition from a previously fetched issue
- Running-entry authoritative-input fence and reconciliation guard
- Provider-acknowledged queue delivery state and operator evidence
- Regression tests for the reported delayed-turn and CI races

### Out of scope

- Queue-drain crash behavior tracked separately by #1110
- A new external tracker label or a redesign of existing lifecycle states
- A second workspace writer or a distributed compare-and-swap service
- Parsing free-form Executor text to decide whether it is a rework instruction
- Agent-workspace `aiurdev --test` manual verification, which the repository
  guard reserves for the Executor checkout

## Key Technical Decisions

- **Expected state is checked at the mutation boundary.** Extend
  `Tracker.update_issue_state/3` and GitHub `IssueState` so the normalized
  current state is compared with `expected_state:`. Because human-review
  verification can make network calls after the existing issue GET, perform a
  fresh state GET after that gate and immediately before label mutation. A
  mismatch returns a structured stale-transition error and performs no
  DELETE/POST/PATCH calls.
- **The running entry owns the handoff fence.** A small lifecycle-fence helper
  records the authoritative state and outstanding queue item IDs on the entry
  already owned by the Orchestrator GenServer. No new process or workspace
  writer is introduced.
- **Reconciliation fails closed.** Before terminal/non-active handling,
  `Reconciler` checks the running fence. A conflicting observed state is not
  admitted; it is conditionally restored to the fence's authoritative state.
  A failed restore keeps the runner alive and the fence intact for the next
  poll.
- **Claim and provider delivery are separate facts.** Keep the queue's existing
  claimed/in-flight status for settlement compatibility, add explicit provider
  acknowledgement metadata, and map operator-facing status to `queued` until
  that metadata exists.
- **Use existing provider callbacks.** App-server initial turns invoke a new
  delivery callback after `start_turn` returns a provider turn ID; safe
  checkpoint and REPL injection success callbacks acknowledge the matching
  queue item. Decision correlation is still prepared before input is exposed,
  but wait timing and fence release move to provider acknowledgement.

## Implementation Units

### U1. Add expected-state tracker transitions

**Goal:** Reject stale label swaps at the last reliable read before mutation.

**Requirements:** R1, R2, R7

**Dependencies:** None

**Files:**

- Modify: `src/lib/aiur/tracker.ex`
- Modify: `src/lib/aiur/github/tracker.ex`
- Modify: `src/lib/aiur/github/client.ex`
- Modify: `src/lib/aiur/github/issue_state.ex`
- Modify: `src/lib/aiur/orchestrator/ci_lifecycle.ex`
- Modify: `src/test/aiur/github/issue_state_test.exs`
- Modify: `src/test/aiur/orchestrator_deactivate_test.exs`

**Approach:**

- Add an optional `update_issue_state/3` adapter callback while preserving the
  public two-argument call for existing writers and test doubles. If an
  `expected_state:` call reaches an adapter or configured client without `/3`,
  return `{:error, :expected_state_unsupported}` instead of silently invoking
  the unfenced `/2` path.
- Derive the normalized GitHub state from the issue payload and return
  `{:error, {:stale_issue_state, expected, actual}}` on mismatch. Run the
  review-thread gate first, then re-fetch and compare the state immediately
  before label deletion so a slow human-review verification cannot age the
  expectation.
- Pass each CI poll target's observed state into pending, pass, failure, and
  fallback writes. Treat a stale-state result as a skipped transition and keep
  orchestrator cache/control state unchanged.

**Test scenarios:**

- Expected `human-review` matches and performs the normal label swap.
- Current `rework` differs from expected `human-review`; no mutation request is
  issued and the structured stale error is returned.
- A human-review gate succeeds after tracker state changes to `rework`; the
  post-gate revalidation rejects the write before any label mutation.
- A configured adapter/client without `/3` rejects a fenced write rather than
  falling back to `/2`.
- A CI result captured for `ci-wait` races with a newer `rework` state and does
  not update cache, publish a terminal event, or resume/pause the runner.

### U2. Fence authoritative input until provider acknowledgement

**Goal:** Keep a running rework/review contract authoritative while its input
is queued or in flight.

**Requirements:** R3, R4, R5, R7

**Dependencies:** U1

**Files:**

- Add: `src/lib/aiur/orchestrator/lifecycle_fence.ex`
- Modify: `src/lib/aiur/orchestrator/operator_messages.ex`
- Modify: `src/lib/aiur/orchestrator/comment_wake.ex`
- Modify: `src/lib/aiur/orchestrator/reconciler.ex`
- Modify: `src/lib/aiur/orchestrator.ex`
- Modify: `src/test/aiur/orchestrator_status_test.exs`
- Modify: `src/test/aiur/orchestrator_deactivate_test.exs`

**Approach:**

- Initialize a running entry with no fence. When a plain/correlated Executor
  message is accepted, add its queue item ID and preserve the entry's current
  authoritative active state. When a trusted non-benign comment digest is
  accepted for an issue-backed live runner, make `rework` the authoritative
  state, refresh the running entry, and transition the tracker to `rework`
  before allowing a later handoff. Preserve the existing no-label-mutation
  semantics for PR-anchored watch runners.
- Keep existing urgent trusted-comment delivery options and notifications
  untouched. Idempotently associate duplicate event routing with the queue item
  rather than opening an anonymous fence.
- Add an orchestrator call that acknowledges a provider-delivered queue item
  and removes only that item from the fence. Clear the fence when no protected
  items remain.
- In reconciliation, intercept any observed state that would pause,
  deactivate, complete, or terminate the runner while fenced. Restore the
  authoritative state using `expected_state: observed_state`; whether the
  restore succeeds or loses another race, retain the live runner and fence.

**Test scenarios:**

- A delayed active turn receives trusted review feedback, preserves
  `priority: :now`, moves its issue-backed contract to `rework`, and opens a
  fence tied to the queued digest.
- A stale `ci-wait` observation while fenced is conditionally restored to
  `rework` and never pauses the runner.
- A provider acknowledgement clears only its matching item; multiple queued
  authoritative inputs keep the fence closed until all are acknowledged.
- An untrusted or benign review-pass comment does not open a fence.

### U3. Make provider delivery observable and authoritative

**Goal:** Release lifecycle protection and report delivery only at the real
provider acceptance boundary.

**Requirements:** R5, R6, R7

**Dependencies:** U2

**Files:**

- Modify: `src/lib/aiur/agent_queue_item.ex`
- Modify: `src/lib/aiur/agent_queue_store.ex`
- Modify: `src/lib/aiur/orchestrator/operator_messages/capabilities.ex`
- Modify: `src/lib/aiur/agent_chat.ex`
- Modify: `src/lib/aiur/agent_runner/queue_drain.ex`
- Modify: `src/lib/aiur/agent_runner/checkpoint_delivery.ex`
- Modify: `src/lib/aiur/app_server/adapter.ex`
- Modify: `src/lib/aiur/claude/repl/hook_turn.ex`
- Modify: `src/lib/aiur/claude/repl/transcript_turn.ex`
- Modify: focused tests beside each touched delivery component

**Approach:**

- Add `provider_delivered_at` and provider turn metadata to queue items, plus a
  store transition that records provider acceptance idempotently without
  consuming the item.
- Move `OperatorWaitLog.record_delivered/2` out of queue claim/preparation and
  into the orchestrator acknowledgement path. Validate correlated answers
  synchronously with non-mutating `DecisionStore.validate_delivery/2` before
  exposure, then persist `DecisionStore.record_delivery/2` only from the
  provider receipt callback.
- Record queued wait/transcript evidence inside the orchestrator immediately
  after queue acceptance and before notifying the worker. On provider
  acknowledgement, broadcast a separate system evidence event and project
  visible operator messages as `queued` or `delivered` from explicit provider
  metadata.
- For new app-server turns, call the acknowledgement callback immediately
  after the provider returns a turn ID. For mid-turn app-server and REPL input,
  reuse the existing success callback that fires only after provider
  acceptance or successful paste. Failures retain existing restore/fail rules
  and never acknowledge delivery. A permanently failed fenced item remains
  visible as failed and raises actionable operator evidence instead of becoming
  an invisible, indefinitely blocking fence.

**Test scenarios:**

- AgentChat acceptance emits queued evidence with its request ID.
- Claiming an item leaves operator evidence queued and does not record wait-log
  delivery or clear the lifecycle fence.
- App-server turn-start acceptance records provider delivery, emits delivered
  evidence, and clears the matching fence.
- Provider rejection/retirement restores or fails the item without a false
  delivered marker.
- A permanently failed provider delivery remains observable with its request
  ID and leaves the lifecycle fence closed until an explicit retry succeeds.
- Existing correlated-decision preparation and trusted-comment prioritization
  continue to pass unchanged.

### U4. Verify the exact head and hand off to CI

**Goal:** Publish a reviewable draft against the configured integration branch
with deterministic regression evidence.

**Requirements:** R1-R7

**Dependencies:** U1, U2, U3

**Files:**

- No additional production files

**Approach:**

- Run formatter, warnings-as-errors compilation, the repository affected-test
  selector, and every selected test with `--max-cases 4`.
- Self-review the exact diff for stale callback paths, fence leaks, adapter
  compatibility, and false delivery evidence.
- Push the canonical branch, open or update a draft PR against `develop`,
  verify its exact base/head, and move the ticket to `agent:ci-wait` only after
  the draft and local scoped gate are complete.
- Leave the PR draft until full CI passes and exact-head review is complete.

## System-Wide Impact

- **Interaction graph:** Executor/comment acceptance -> Orchestrator queue ->
  running-entry fence -> provider acknowledgement -> fence release;
  CI poll snapshot -> expected-state tracker mutation.
- **State ownership:** The Orchestrator remains the sole owner of running and
  queue state. GitHub remains the tracker-label authority; no workspace writer
  is added.
- **Failure behavior:** Provider failure keeps input queued/failed under the
  existing settlement policy and retains lifecycle protection. A stale tracker
  compare is a normal rejected transition, not a retryable mutation.
- **Observability:** Operator transcript/queue evidence distinguishes
  acceptance (`queued`) from provider acknowledgement (`delivered`) by request
  ID and timestamp.
- **Unchanged invariants:** Label slugs and meanings, comment trust checks,
  urgent delivery priority, review-thread gating, and exact-head CI semantics.

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| A fence survives an item forever | Clear by exact queue item ID on provider acknowledgement; retain every claimed item ID when event digests coalesce; existing restore/fail paths keep the state inspectable and tests cover multiple items. |
| Duplicate event routing creates an anonymous fence | Fence only after a concrete queue item is accepted and use the item ID as release identity. |
| A stale restore overwrites an even newer state | Restore with `expected_state: observed_state`; a mismatch keeps the runner alive without another mutation. |
| Adapter mocks break on a new arity | Preserve `/2`, make `/3` optional, and use capability detection/fallback at the facade. |
| Decision answers lose pre-delivery durability | Validate the canonical durable answer before provider input, then record its transport edge only when the provider receipt callback fires. |
| REPL and app-server semantics diverge | Route both through the same queue acknowledgement API from their existing success callbacks. |

## Validation Plan

1. Run GitHub issue-state tests for matching and stale expected states.
2. Run orchestrator CI/reconciliation regressions for the delayed rework and
   CI result races.
3. Run queue-store, operator-message, checkpoint-delivery, app-server adapter,
   and REPL delivery tests for queued-versus-delivered evidence.
4. Confirm the existing trusted active-comment priority and correlated
   decision-delivery tests remain green.
5. Run `mix format`, `mix compile --warnings-as-errors`, and
   `mix aiur.affected_tests`; execute every selected command with
   `mix test --max-cases 4`.
6. Defer the real TUI `aiurdev --test` check to the Executor checkout because
   agent workspaces are explicitly blocked from that manual path.

## Acceptance Criteria

- [x] A delayed trusted rework input cannot be hidden by a stale `ci-wait` or
      `human-review` observation before provider acknowledgement.
- [x] A CI fetch/result race returns a stale-state error and leaves newer
      `rework` unchanged.
- [x] Accepted-but-undelivered input is observable as queued; provider-delivered
      evidence appears only after the provider callback succeeds.
- [x] Existing active-agent trusted-comment priority and decision correlation
      behavior remain intact.
- [ ] The scoped local gate passes, the draft PR targets `develop`, and the PR
      remains draft through exact-head review and full CI.
