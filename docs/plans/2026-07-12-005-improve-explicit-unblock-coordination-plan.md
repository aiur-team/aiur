---
title: "improve: Require explicit unblock coordination"
type: improve
status: completed
date: 2026-07-12
---

# improve: Require explicit unblock coordination

## Summary

Make `blocked` and `unblocked` durable operating requirements for dependency seams, and make a blocker's explicit `agent.unblocked` event—not its incidental branch push—the signal that resumes a parked consumer. Branch pushes remain useful metadata for fetching and inspecting a concrete ref after the consumer is active.

## Problem Frame

Aiur already subscribes consumers to blocker state events and delivers `agent.unblocked` at safe mid-turn checkpoints, but its orchestrator still wakes paused consumers on `ticket.<blocker>.branch.push`. That lets agents skip the semantic unblock event and makes dependency coordination depend on a coarse repository firehose. The canonical skill also phrases the required emissions as ordinary numbered steps without defining the non-blocking, no-retry contract needed under coordination RPC latency.

## Requirements

- R1. A non-stubbable parked seam must emit `blocked` with `stubbable: false` after declaring its blocker.
- R2. A consumer that integrates a real dependency must emit `unblocked` as a required fire-and-forget action.
- R3. A paused consumer resumes from `ticket.<blocker>.agent.unblocked`, while `branch.push` remains an inspect cue and does not independently claim semantic readiness.
- R4. Focused coverage must model a parked consumer receiving and consuming the explicit unblock signal.

## Scope Boundaries

- Preserve provisional `unblocked` emissions for useful local stubs.
- Preserve branch-push subscriptions and mid-turn delivery for ref discovery by active agents.
- Do not add event durability or retry machinery; #1031 owns the non-blocking coordination-tool boundary.
- Do not run operator-only `aiurdev --test` from this issue workspace.

## Key Technical Decisions

- Reuse the existing topic-subscription check and pending-auto-resume mechanism, generalized from push-specific naming to unblock-event naming where appropriate.
- Classify the exact `ticket.<id>.agent.unblocked` topic in `Aiur.Orchestrator.EventTopics` and route only that semantic signal into auto-resume.
- Keep branch-push event routing side-effect free for paused consumers; subscribed running consumers still receive it through the normal digest path.
- Treat emission calls as single-attempt enqueue operations: required means the agent must call them, while fire-and-forget means it must not wait, poll, or retry when downstream publication is still pending.

## Implementation Units

### U1. Strengthen the canonical dependency contract

**Goal:** Make blocked/unblocked emissions unmistakably required and define their fire-and-forget semantics.

**Requirements:** R1, R2

**Files:**
- Modify: `.claude/skills/aiur-agent/stub-then-fetch.md`
- Modify: `.claude/skills/aiur-agent/emit-and-subscribe.md`
- Modify: `src/prompts/shared-agent-instructions.md`
- Test: `src/test/aiur/aiur_agent_skill_test.exs`

**Test scenarios:**
- The canonical skill requires `blocked` for a non-stubbable parked seam.
- The canonical skill requires real-integration `unblocked` and explicitly says single-attempt fire-and-forget/no retry.
- Consumer guidance names `ticket.<blocker>.agent.unblocked` as the readiness signal and limits `branch.push` to inspection.

### U2. Resume parked consumers only on explicit unblock

**Goal:** Align orchestrator behavior with the semantic coordination contract.

**Requirements:** R3, R4

**Files:**
- Modify: `src/lib/aiur/orchestrator/event_topics.ex`
- Modify: `src/lib/aiur/orchestrator/push_routing.ex`
- Test: `src/test/aiur/orchestrator/event_topics_test.exs`
- Test: `src/test/aiur/orchestrator_deactivate_test.exs`

**Test scenarios:**
- Exact `ticket.99.agent.unblocked` classifies as an unblock event; malformed/prefixed/suffixed topics do not.
- A paused subscribed consumer stays paused on `ticket.99.branch.push`.
- The same consumer resumes on `ticket.99.agent.unblocked` and receives a fresh activity timestamp.
- An unsubscribed consumer and the emitting blocker itself remain unchanged.
- A cap-full resume retains a pending hint that drains later without losing the explicit unblock signal.

## Dependencies and Risks

- #1031 / PR #1036 supplies prompt-bounded, asynchronous coordination tool admission. This branch can implement and test independently, but must stack only after the prerequisite emits or lands with a usable ref.
- Existing tests and comments are strongly push-specific. Rename them carefully so no stale contract continues teaching branch-push readiness.
- Removing push-driven wakeup makes missing `unblocked` emissions visible instead of silently masked; that is intentional and is why U1 contract coverage is part of the same change.

## Validation Strategy

- Run affected orchestrator topic/routing tests and the Aiur agent skill contract test with `--max-cases 4`.
- Run `mix compile --warnings-as-errors` and `mix format` from `src/`.
- Inspect the final diff for residual claims that branch pushes auto-resume parked consumers.
