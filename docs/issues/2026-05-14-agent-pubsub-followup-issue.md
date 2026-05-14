---
title: Agent PubSub for cross-agent coordination, branches, and PR events
type: issue-draft
status: proposed
date: 2026-05-14
origin:
  - docs/brainstorms/2026-05-12-agent-queue-and-pubsub-requirements.md
  - docs/plans/2026-05-12-feat-agent-queue-and-pubsub-plan.md
---

# Agent PubSub for cross-agent coordination, branches, and PR events

## Summary

PubSub should be split out of the current queue/control work and treated as the next issue. This follow-up introduces a general event publish/subscribe model so agents can receive durable coordination events from other agents and from agent-owned branch and PR lifecycle changes without relying on manual operator relay.

## Why This Is Separate

The current branch is already doing enough: durable queueing, checkpoint delivery, pause/resume semantics, and human message routing. PubSub expands the scope from "how one agent safely receives input" to "how multiple agents and repository workflows emit and consume coordination events." That is a separate product and orchestration problem and should not stay coupled to the current implementation slice.

## Problem

Symphony can run multiple issue agents in parallel, but coordination between them is still mostly manual. Even with a unified agent-facing queue, there is not yet a first-class way for:

- one agent to publish a durable event another agent can subscribe to
- a blocked or related issue to react to branch creation, pushes, PR opening, PR review state, or merge completion
- an agent to consume repository workflow events without treating them as ad hoc operator chat

Today that coordination depends on human supervision, handoff docs, or polling for state indirectly. That does not scale once multiple issue agents are active against related work.

## Scope

This issue should cover a general PubSub layer on top of the queue primitive, including:

- agent-published coordination events
- automatic subscriptions derived from tracker relationships such as `blocked_by`
- repository workflow events tied to an agent's branch and PR lifecycle
- durable event delivery into the subscriber agent's queue
- subscription metadata, filtering, dedupe, and causal references needed to keep event delivery usable

This issue should not reopen or expand the current queue/control implementation except where a small seam is needed to support future publishers/subscribers.

## Event Sources To Support First

Start with a small, explicit event set:

- agent status events
  - agent paused
  - agent resumed
  - agent finished
  - agent hit human-review or blocked state
- branch events
  - branch created
  - branch updated/pushed
- PR events
  - PR opened
  - PR updated
  - PR entered review-needed / changes-requested / approved state
  - PR merged or closed
- dependency events
  - blocker became terminal
  - blocker became non-terminal
  - dependency edge added or removed

## Desired Behavior

- Agents can publish structured events without writing directly into another agent's conversation stream.
- Subscriber agents receive those events through the same durable queue model already being introduced for human and coordination input.
- Subscription setup is automatic for the first use cases where Symphony already has an authoritative relationship source.
- Branch and PR events are attached to the agent or issue that owns that branch/PR so related agents can subscribe without guessing provenance.
- Event delivery remains checkpoint-safe and does not violate tool/result ordering.

## Design Expectations

- PubSub should reuse the queue envelope rather than create a second transport.
- Publishers and subscribers should be explicit in metadata.
- Events should carry enough context to be actionable without forcing the receiving agent to scrape logs.
- The system should suppress noisy low-value updates and dedupe repeated equivalent events.
- Subscription logic should remain general enough that future event types can be added without another architecture reset.

## Acceptance Criteria

- A related or blocked issue can subscribe to another issue agent's coordination events and receive them durably.
- Symphony can publish branch and PR lifecycle events for an agent-owned workstream and route them to subscribed agents.
- Repeated unchanged snapshots do not spam subscribers with duplicate events.
- Events remain visible in logs and observability surfaces as distinct coordination items, not operator chat.
- The implementation defines a minimal publisher/subscriber model that future event types can reuse.
- The current queue/control branch does not need to absorb full PubSub implementation scope before shipping.

## Suggested Implementation Areas

- `SymphonyElixir.Orchestrator`
- queue/event store and subscription metadata
- tracker-derived subscription indexing
- git/PR lifecycle publishers
- observability and log rendering for published and consumed coordination events

## References

- [docs/brainstorms/2026-05-12-agent-queue-and-pubsub-requirements.md](/Users/kevin/github/optimism/symphony/docs/brainstorms/2026-05-12-agent-queue-and-pubsub-requirements.md)
- [docs/plans/2026-05-12-feat-agent-queue-and-pubsub-plan.md](/Users/kevin/github/optimism/symphony/docs/plans/2026-05-12-feat-agent-queue-and-pubsub-plan.md)
