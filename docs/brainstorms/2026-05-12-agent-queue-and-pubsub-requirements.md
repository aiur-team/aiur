---
date: 2026-05-12
topic: agent-queue-and-pubsub
---

# Agent Queue and PubSub Requirements

## Summary

Symphony will define agent interaction around a unified per-agent queue that supports live human conversation and durable event delivery without splitting them into separate transport systems. Human messages should feel conversational and arrive quickly at safe checkpoints, while non-human coordination events are stored durably and consumed according to policy, with blocker-ticket PubSub as the first concrete event flow.

---

## Problem Frame

Today, multi-agent coordination outside Symphony is largely manual. The operator can run multiple coding agents in parallel, but when one issue depends on another, coordination happens through human supervision and handoff documents rather than through built-in message delivery. The current workaround is to manually spin up multiple agents, point them at related issues, instruct them to write handoff documents, and tell them to read each other's notes.

That workaround is expensive in attention and timing. A blocked issue may have substantial work it can still complete, but there is no native way for the agent to subscribe to relevant progress from another issue and react when that progress matters. Likewise, the current operator-chat shape in Symphony is too tied to turn boundaries to fully match the feel of Codex- or Claude-style live collaboration, where the UI can accept input continuously and the system surfaces it at the next safe opportunity.

The immediate need is to give Symphony a single message-delivery model that can support both human steering and durable coordination events without proliferating distinct lanes for each actor type. The first concrete coordination case is blocker-ticket PubSub, but the system should be general enough that future event types can reuse the same queue model instead of forcing a redesign.

---

## Actors

- A1. Operator: sends conversational steering messages to a running or resumable agent and expects responsive feedback.
- A2. Active issue agent: performs ticket work, consumes queued messages at safe checkpoints, and decides when to act on surfaced input.
- A3. Related issue agent: publishes coordination-relevant events that another issue's agent may subscribe to.
- A4. Issue tracker: provides dependency metadata that can drive automatic subscription for blocker-ticket flows.

---

## Key Flows

- F1. Human steering during active work
  - **Trigger:** The operator submits a new message while an agent is idle, dispatching, or actively working.
  - **Actors:** A1, A2
  - **Steps:** The UI accepts the message immediately; if the agent is idle, the message starts agent work right away; if the agent is already active, the message is added to the unified queue with conversational delivery policy; the active agent surfaces the message at the next safe checkpoint or via an explicit interrupt path when allowed; the agent then decides whether to respond immediately, defer the request internally, or incorporate it into ongoing work.
  - **Outcome:** The operator experiences live conversational steering without violating model or tool-call ordering.
  - **Covered by:** R1, R2, R3, R4, R5, R8

- F2. Automatic blocker-ticket subscription and delivery
  - **Trigger:** An issue is marked as blocked by another issue in tracker metadata, and both issues have active or resumable Symphony agents.
  - **Actors:** A2, A3, A4
  - **Steps:** Symphony derives the dependency relationship from tracker data; the blocked issue's agent is automatically subscribed to relevant events from its blocker issue; when the blocker issue emits an event that may affect the blocked issue, Symphony writes that event into the blocked agent's queue with durable deferred delivery policy; the blocked agent consumes the event at a safe checkpoint and decides whether the new information changes its work.
  - **Outcome:** Dependency coordination no longer depends on manual human relay or handoff-document polling.
  - **Covered by:** R6, R7, R9, R10, R12

- F3. Future event reuse of the same queue primitive
  - **Trigger:** A future coordination need requires publishing or subscribing to an event type other than blocker-ticket progress.
  - **Actors:** A2, A3
  - **Steps:** The new event type reuses the same underlying queue and delivery-policy model; Symphony configures the event's source and consumption behavior without introducing a separate transport lane.
  - **Outcome:** The first PubSub implementation becomes a reusable platform primitive rather than a one-off blocker feature.
  - **Covered by:** R10, R11

---

## Requirements

**Unified queue model**
- R1. Symphony must provide one agent-facing queue primitive per issue/thread for messages and events that are intended to reach the agent's working context.
- R2. The queue model must support at least source, priority, durability, and consumption-rule metadata on each queued item.
- R3. Symphony must separate input collection from agent consumption so that the UI can accept operator input while the agent is busy, even when the agent cannot safely consume that input immediately.
- R4. Symphony must surface queued items to the active agent only at valid checkpoints that preserve model and tool-call ordering.
- R4a. V1 must target sub-turn checkpoint delivery for human conversational input whenever the runtime can safely surface queued items during ongoing work.
- R5. Symphony must support an interrupt-request delivery policy for higher-priority conversational items without making interruption the default behavior for all input.
- R6. An interrupt request may only stop or redirect work at runtime-defined interruptible points, and the associated message must still be surfaced at a valid model/tool checkpoint.
- R7. If the current activity is not interruptible, Symphony must either reject the interrupt request with an operator-visible reason or explicitly apply the caller's requested fallback policy; it must not silently treat the request as an ordinary send.

**Human conversation**
- R8. User-to-agent conversation is the first-priority interaction this system must optimize for.
- R9. Human messages must feel conversational and responsive from the operator's perspective, even when the agent is already active.
- R10. Human messages submitted while an agent is active must default to fast delivery at the next safe checkpoint within the ongoing work loop when available, rather than waiting for full issue completion or long-lived worker completion.
- R11. V1 user interfaces must expose ordinary Send as the primary action.
- R12. Interrupt-capable send may be exposed only as a secondary action and must be disabled, hidden, or rejected when the selected agent cannot interrupt safely.
- R13. V1 must keep pause semantics distinct from interrupt-capable send: pause stops further autonomous progress after the current safe boundary without requiring a message, while interrupt-capable send couples a message with a stop-or-redirect request.

**PubSub and subscriptions**
- R14. Symphony must support durable non-human event delivery using the same queue primitive as human conversation, with different delivery-policy defaults.
- R15. Blocker-ticket PubSub is the first concrete non-human event flow Symphony must support, but it must be implemented as an instance of a general event model rather than as a one-off hard-coded special case.
- R16. The queue and subscription design must remain extensible enough to support future event types without requiring a separate message transport or queueing subsystem.
- R17. Symphony must automatically subscribe a blocked issue's agent to relevant events from blocker issues when the issue tracker expresses that dependency relationship.
- R18. The queue envelope must preserve enough source, target, delivery, ordering, and subscription metadata to support durable PubSub delivery, deduplication, and later extension to additional event types.

**Command and safety boundaries**
- R19. Local UI commands that do not mutate agent conversation state must remain outside the agent-facing queue.
- R20. Symphony must preserve strict ordering guarantees so that unrelated queued items are not inserted in ways that break tool-call/result sequencing or other protocol invariants.
- R21. Turn-boundary delivery is an acceptable fallback when the runtime cannot safely expose finer-grained checkpoints, but it must not be treated as the intended interaction model for human conversational input.

---

## Acceptance Examples

- AE1. **Covers R3, R4, R4a, R10, R21.** Given a running agent is in the middle of ongoing work and the runtime reaches a safe sub-turn checkpoint, when the operator submits a new human message, the UI accepts it immediately and the agent receives it at that checkpoint without waiting for the entire issue run to finish.
- AE2. **Covers R5, R6, R12.** Given a running agent in an interruptible state, when the operator chooses the interrupt-capable send action, Symphony requests cancellation or redirection safely and surfaces the new message ahead of deferred items at the next valid checkpoint.
- AE3. **Covers R7.** Given an active agent is not in an interruptible state, when the operator chooses the interrupt-capable send action, Symphony does not silently treat the message as a normal send and instead rejects the interrupt request with a clear reason or applies the caller's explicit fallback policy.
- AE4. **Covers R13.** Given a running agent, when the operator chooses pause, Symphony stops further autonomous progress after the current safe boundary without attaching a new conversational message to the agent queue.
- AE5. **Covers R14, R15, R17.** Given issue `#2` is blocked by issue `#1` according to tracker metadata, when issue `#1` emits a coordination-relevant event, Symphony automatically delivers that event durably to issue `#2`'s agent queue without requiring manual operator relay.
- AE6. **Covers R16, R18.** Given a future event type unrelated to blocker relationships, when Symphony adds support for publishing and subscribing to that event, it reuses the same queue and delivery-policy model instead of introducing a separate lane, preserving durable metadata and ordering semantics.
- AE7. **Covers R11, R12, R13.** Given a v1 human-facing UI, when the operator opens the composer, ordinary Send appears as the primary action, interrupt-capable send is available only as a secondary, state-gated action, and pause remains a separate control.
- AE8. **Covers R19, R20.** Given the operator runs a local UI command while the agent is busy, when that command does not affect agent conversation state, it executes immediately without entering the agent-facing queue or disturbing tool/result ordering.

---

## Success Criteria

- Operators can steer active agents in a way that feels much closer to Codex- or Claude-style collaboration than to long-delayed checkpoint-only messaging.
- Blocked issues can react to blocker progress without relying on manual handoff documents or human relay.
- The first PubSub flow establishes a reusable coordination primitive rather than a bespoke blocker-only mechanism.
- The requirements are specific enough that `ce-plan` can design queue, checkpoint, and subscription behavior without inventing product semantics from scratch.

---

## Scope Boundaries

- This first cut does not define a full catalog of all future event types agents may publish or subscribe to.
- This first cut does not include general freeform agent-to-agent chat.
- This first cut does not assume the agent can ingest arbitrary new messages at any instant during unsafe protocol sections.
- This first cut does not require a separate queueing or transport subsystem for each actor type.
- This first cut does not define advanced user-managed subscription topology or rich inbox administration workflows unless needed by the blocker-ticket flow.

---

## Key Decisions

- Unified queue over separate lanes: storage and delivery should be generalized once, then specialized by metadata and policy.
- Human chat is the primary UX driver: the queue model is being shaped first around responsive operator collaboration, not around background event plumbing alone.
- Blocker-ticket PubSub is the first concrete event flow: it provides a real coordination problem to solve now without prematurely freezing the broader event taxonomy.
- Safe-checkpoint consumption is a core invariant: responsiveness should improve without sacrificing tool-ordering correctness.
- V1 human UX uses one primary send action: interrupt-capable send is secondary and state-gated, while pause remains a separate control with different semantics.
- V1 aims for sub-turn checkpoint delivery for human chat: turn-boundary handling is fallback behavior for runtimes that cannot yet expose finer-grained safe checkpoints.

---

## Dependencies / Assumptions

- Tracker dependency metadata is available and trustworthy enough to drive automatic blocker subscriptions.
- The active coding-agent runtime can support safe checkpoint delivery during ongoing work, or Symphony can extend it in v1 to expose those checkpoints for human conversational input.
- The agent can decide whether a surfaced message requires immediate action or can be deferred internally after it enters working context.

---

## Outstanding Questions

### Resolve Before Planning

- None.

### Deferred to Planning

- [Affects R11, R12, R13][Implementation UX] What exact affordances should implement the resolved v1 interaction model on each surface: web uses Send as primary, Pause after turn as a separate control, and Stop & send only when interruption is available; CLI uses Enter for send, Alt-Enter for newline, `/pause` for pause-after-turn, and `/interrupt <message>` for interrupt-capable delivery.
- [Affects R4, R4a, R5, R6, R21][Technical] Which safe sub-turn checkpoints can the runtime expose in v1 without violating protocol ordering, and what fallback behavior applies when only turn-boundary delivery is available?
- [Affects R6, R7][Technical] How should interrupt-capable delivery interact with the current turn-based execution model when the active work is not safely interruptible, including explicit downgrade versus rejection behavior?
- [Affects R14, R15, R17, R18][Technical] What concrete queue envelope shape is sufficient for blocker-ticket PubSub while remaining general enough for future event types, including dedupe and causal metadata?
- [Affects R17][Needs research] Which tracker-state transitions or emitted coordination events should count as relevant blocker updates for the first PubSub flow, and which ordinary progress updates should be suppressed by default?
