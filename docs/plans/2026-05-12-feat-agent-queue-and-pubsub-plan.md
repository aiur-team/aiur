---
title: Agent queue, sub-turn input, and blocker PubSub
type: feat
status: active
date: 2026-05-12
origin: docs/brainstorms/2026-05-12-agent-queue-and-pubsub-requirements.md
branch: symphony/agent-queue-and-pubsub
---

# Agent queue, sub-turn input, and blocker PubSub

## Enhancement Summary

This plan turns the current operator chat controls into a real messaging model. The existing branch and PR #19 direction are still useful, but only as the UI/control shim:

1. Keep `AgentChat`, CLI composer, web composer, and pause controls as the public control surface.
2. Replace process-mailbox-only delivery with a durable per-issue queue that becomes the source of truth for both human messages and PubSub events.
3. Add a runtime/session checkpoint seam so human messages can be surfaced during ongoing work at safe sub-turn checkpoints when the backend can support it, with turn-boundary delivery retained only as fallback.
4. Use the same queue primitive for blocker-ticket PubSub, auto-subscribed from tracker dependency metadata.

Execution posture: characterization-first around the current adapter/session lifecycle and current turn-boundary operator controls. The queue/checkpoint refactor touches the most fragile orchestration path in the repo; preserving existing behavior before widening it is more important than raw implementation speed.

---

## Overview

Symphony already has first-pass operator controls:

- `SymphonyElixir.AgentChat` exposes `send/2` and `pause/1`.
- `SymphonyElixir.Orchestrator` routes those controls to a running worker pid.
- `SymphonyElixir.AgentRunner` consumes those messages only between `run_turn` calls.
- CLI and LiveView composers already exist on the current branch.

That is useful scaffolding, but it is not yet the product described by the requirements doc. Today the control path is an in-memory process mailbox tied to one running worker task. It has no durable queue, no subscription model, and no defined way to surface human input during a long-running turn. The next implementation pass needs to convert that shim into a real queue-backed coordination layer while preserving protocol ordering and current UX simplicity.

This plan treats `docs/plans/2026-05-11-feat-agent-chat-send-plan.md` as the immediate predecessor pattern for operator controls, but expands the architecture in three directions:

1. **Queue as source of truth**
2. **Sub-turn safe checkpoint delivery for human messages**
3. **Blocker-ticket PubSub through the same queue primitive**

---

## Problem Statement

The requirements doc establishes two distinct user-facing needs:

- Human steering should feel like Codex/Claude-style live collaboration, not like a delayed ticket-comment workflow.
- Dependency coordination should stop depending on manual handoff documents and human relay.

The current codebase only partially satisfies the first need and does not satisfy the second:

- `elixir/lib/symphony_elixir/orchestrator.ex` forwards operator control messages directly to the running worker task pid.
- `elixir/lib/symphony_elixir/agent_runner.ex` only drains those messages after `CodingAgent.run_turn/4` returns.
- `elixir/lib/symphony_elixir/codex/coding_agent.ex` and `elixir/lib/symphony_elixir/claude/coding_agent.ex` own the live stream loop during a turn and currently expose no AgentRunner-level checkpoint hook.
- `elixir/lib/symphony_elixir/orchestrator.ex` already knows which issues are blocked by non-terminal blockers for dispatch gating, but no event path exists to notify those blocked issues when blocker state changes.

So the design gap is not “add another send button.” It is:

- define a durable queue model
- decide where queue items live before they are consumed
- create a runtime checkpoint seam for safe sub-turn delivery
- route non-human coordination events through the same primitive

---

## Requirements Traceability

This plan implements the origin requirements document in `docs/brainstorms/2026-05-12-agent-queue-and-pubsub-requirements.md`.

Most important carried-forward constraints:

- One unified queue primitive, not separate transport systems (`R1`, `R14-R18`)
- Human chat is priority 1 (`R8-R13`)
- Human messages should target sub-turn checkpoints in v1 when the runtime can safely surface them (`R4a`, `R10`, `R21`)
- Interrupt is secondary and state-gated, not the default send action (`R5-R7`, `R11-R13`)
- Blocker-ticket PubSub is the first concrete non-human event flow (`R15`, `R17`)
- Local commands stay outside the agent-facing queue (`R19`)
- Tool/result ordering remains a hard invariant (`R4`, `R20`)

The plan deliberately treats turn-boundary delivery as fallback rather than as the desired conceptual model (see origin: `R21`).

---

## Current-State Research

### Relevant existing code

- `elixir/lib/symphony_elixir/agent_chat.ex`
  - current public facade for `send/2` and `pause/1`
- `elixir/lib/symphony_elixir/orchestrator.ex`
  - current control-message routing
  - current blocked-by dispatch gating
  - current snapshot/capability surface
- `elixir/lib/symphony_elixir/agent_runner.ex`
  - current turn loop
  - current between-turn operator delivery and pause semantics
- `elixir/lib/symphony_elixir/coding_agent.ex`
  - current backend boundary
- `elixir/lib/symphony_elixir/codex/coding_agent.ex`
  - current live turn stream loop and tool-response handling
- `elixir/lib/symphony_elixir/claude/coding_agent.ex`
  - current Claude proxy turn/session behavior
- `elixir/lib/symphony_elixir/status_dashboard.ex`
  - current CLI composer, send, and pause integration
- `elixir/lib/symphony_elixir/terminal_input.ex`
  - current key handling and CLI input semantics
- `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
  - current web composer and pause button
- `elixir/lib/symphony_elixir/linear/client.ex`
  - existing extraction of `blocked_by` relationships into issue structs

### Existing patterns to follow

- Public orchestration control surfaces already go through `AgentChat` rather than importing `Orchestrator` directly.
- Snapshot/state detail endpoints already expose per-issue runtime metadata from `Orchestrator`.
- Tests already cover:
  - operator send/pause orchestration (`elixir/test/symphony_elixir/orchestrator_status_test.exs`)
  - adapter send behavior (`elixir/test/symphony_elixir/coding_agent_test.exs`)
  - CLI key semantics (`elixir/test/symphony_elixir/terminal_input_test.exs`)
  - queue gating by blocker terminality (`elixir/test/symphony_elixir/workspace_and_config_test.exs`)

### Planning conclusion

There are strong local patterns and active recent work for the operator-control surface already. External research is not necessary for this plan. The key work is a repo-internal orchestration refactor and product-shape expansion, not adoption of a new external framework.

---

## Key Technical Decisions

- **Decision 1: Keep `AgentChat` as the public command surface.**
  - Rationale: the surface already exists, is referenced by CLI/web, and cleanly separates callers from orchestration internals. The implementation behind it changes from “send to running pid” to “enqueue durable item,” but the seam remains stable.

- **Decision 2: Introduce a durable per-issue queue that is independent of a live worker task.**
  - Rationale: blocker-ticket PubSub must be able to enqueue work for blocked issues that are not currently running, and human messages must survive worker-task replacement. A process mailbox is insufficient.

- **Decision 3: Treat sub-turn checkpoints as the intended human-message delivery model.**
  - Rationale: the requirements explicitly moved back toward sub-turn input in v1. Turn-boundary delivery remains fallback only when the backend cannot safely expose finer checkpoints (see origin: `R4a`, `R10`, `R21`).

- **Decision 4: Separate pause from interrupt-capable send.**
  - Rationale: pause affects autonomous progression with no message payload; interrupt-capable send couples a payload with a stop-or-redirect request. Conflating them would make the UI and queue semantics misleading (see origin: `R13`).

- **Decision 5: Use tracker dependency metadata as the authority for the first subscription graph.**
  - Rationale: the current orchestrator already trusts `blocked_by` for dispatch gating. PubSub should begin from the same authority rather than inventing a second source of truth.

- **Decision 6: Build the queue envelope for generality now, but only implement one human category and one event category in v1.**
  - Rationale: avoid premature lane explosion while still preventing another redesign when future event types arrive.

- **Decision 7: Preserve log/order correctness over immediacy.**
  - Rationale: even with sub-turn delivery, messages may only surface at safe checkpoints after protocol-invariant sections such as tool-call/result matching. “Responsive” does not mean arbitrary stream injection.

---

## Proposed Architecture

### High-level model

```text
Input surface
  CLI / LiveView / HTTP / tracker-driven event producer
    -> AgentChat / event enqueue API
    -> durable per-issue queue
    -> runtime/session checkpoint consumer
    -> active thread context
```

### Queue model

Use a unified queue envelope for all agent-facing items with:

- source metadata
- target issue/thread metadata
- category / event type
- delivery policy
- ordering / dedupe / causal metadata
- ack / consumption status

The v1 plan does not need a giant type lattice. It needs one general shape that supports:

- operator conversational messages
- blocker-ticket coordination events

### Runtime model

Current state:

- the adapter owns the live stream loop for a turn
- `AgentRunner` regains control only after `run_turn` returns

Planned state:

- the live session/adapter path exposes explicit safe checkpoints during ongoing work
- `AgentRunner` (or a dedicated session-control seam immediately below it) can ask for the next queue item at those checkpoints
- if a runtime cannot expose those checkpoints, `AgentRunner` falls back to turn-boundary delivery

### Subscription model

The first subscription graph is automatic:

- if issue B is blocked by issue A in tracker metadata
- B becomes subscribed to relevant blocker events from A
- the queue receives events for B when A changes in ways that may affect dispatch/work planning

This uses the same queue primitive; PubSub is not a separate inbox subsystem.

---

## Implementation Units

### Unit 1: Durable queue domain and storage

**Purpose**

Create the queue primitive that replaces direct worker-mailbox delivery as the source of truth for human messages and blocker events.

**Primary files**

- new `elixir/lib/symphony_elixir/agent_queue.ex`
- new `elixir/lib/symphony_elixir/agent_queue_item.ex`
- new `elixir/lib/symphony_elixir/agent_queue_store.ex`
- `elixir/lib/symphony_elixir/agent_chat.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex`

**Design**

- `AgentChat.send/2` and future enqueue surfaces stop directly targeting a running worker pid.
- Introduce a queue API that can:
  - enqueue operator messages
  - enqueue coordination events
  - fetch the next deliverable item for a target issue/thread
  - mark delivery / consumption / supersession state
- Persist queue state outside the worker-task mailbox so it survives worker replacement and is available for blocked issues that are not actively running.
- Preserve enough metadata to support:
  - priority ordering
  - explicit interrupt-request policy
  - durable deferred event delivery
  - dedupe for blocker events
  - causal tracing for “why did this item exist?”

**Why this shape**

The queue must exist independently of the live worker because blocker PubSub and resumable agent steering both require pre-consumption persistence. Folding this into `Orchestrator.State.running` alone would make the system collapse back to “only live workers can have messages.”

**Test files**

- new `elixir/test/symphony_elixir/agent_queue_test.exs`
- update `elixir/test/symphony_elixir/agent_chat_test.exs`
- update `elixir/test/symphony_elixir/orchestrator_status_test.exs`

**Test scenarios**

- enqueue human message for a running issue and read it back with preserved delivery policy
- enqueue coordination event for a blocked non-running issue and read it back later
- mark queue item delivered, consumed, failed, and superseded
- dedupe repeated blocker events using the chosen dedupe key semantics
- preserve ordering when operator messages and deferred events coexist

---

### Unit 2: Session/runtime checkpoint seam for sub-turn delivery

**Purpose**

Make v1 human messages deliverable during ongoing work at safe checkpoints instead of only between completed turns.

**Primary files**

- `elixir/lib/symphony_elixir/coding_agent.ex`
- `elixir/lib/symphony_elixir/codex/coding_agent.ex`
- `elixir/lib/symphony_elixir/claude/coding_agent.ex`
- `elixir/lib/symphony_elixir/agent_runner.ex`
- update or add a session-owner/helper module if needed, such as new `elixir/lib/symphony_elixir/agent_session.ex`

**Design**

- Extend the backend/session contract so a running turn can advertise safe checkpoints to `AgentRunner`.
- The first v1 checkpoints should come from the adapter/runtime, not from UI speculation.
- In Codex, the most promising seam is inside the current turn stream loop after the adapter has safely completed a tool-response or approval-response cycle and before it recurses into the next receive/model continuation step.
- Claude should expose the same abstract checkpoint semantics through the shared `CodingAgent` boundary, even if the underlying granularity differs.
- `AgentRunner` becomes the consumer of checkpoint notifications and asks the durable queue for deliverable items at those points.
- When a runtime cannot expose sub-turn checkpoints safely, the queue is still drained between turns exactly as today.

**Why this shape**

The requirements explicitly reject turn-boundary-only delivery as the intended human-conversation model. The only place to restore that behavior honestly is below the UI and above protocol-invalid insertion, which means the adapter/session seam.

**Test files**

- update `elixir/test/symphony_elixir/coding_agent_test.exs`
- update `elixir/test/symphony_elixir/core_test.exs`
- update `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- add adapter-focused coverage where needed, likely in `elixir/test/symphony_elixir/app_server_test.exs`

**Test scenarios**

- human message queued during a long-running turn is surfaced at a declared safe sub-turn checkpoint
- runtime with no sub-turn checkpoints falls back to turn-boundary delivery
- checkpoint delivery never inserts unrelated content between a tool call and its matching result
- checkpoint delivery works for both Codex and Claude adapter contracts
- stale / repeated checkpoint signals do not double-deliver the same queue item

---

### Unit 3: Interrupt, pause, and capability semantics

**Purpose**

Define and expose the control semantics for:

- normal send
- interrupt-capable send
- pause after turn / safe boundary

**Primary files**

- `elixir/lib/symphony_elixir/agent_chat.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/lib/symphony_elixir/coding_agent.ex`
- `elixir/lib/symphony_elixir/codex/coding_agent.ex`
- `elixir/lib/symphony_elixir/claude/coding_agent.ex`

**Design**

- Preserve normal send as checkpoint delivery.
- Interrupt-capable send becomes a queue delivery policy, not a second queue.
- Pause remains a separate control path with no message payload.
- Add explicit runtime capability metadata such as:
  - accepts operator messages
  - can interrupt safely right now
  - safe-checkpoint capability set
- If interrupt is requested when the runtime is not interruptible:
  - reject, or
  - downgrade only when the caller explicitly requested that fallback
- Do not silently treat interrupt as normal send.

**Why this shape**

The operator must be able to trust what the UI/API says happened. A false promise of interruption is worse than a clear “not interruptible right now” response.

**Test files**

- update `elixir/test/symphony_elixir/agent_chat_test.exs`
- update `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- update `elixir/test/symphony_elixir/core_test.exs`

**Test scenarios**

- normal send while busy enqueues for checkpoint delivery
- interrupt-capable send on interruptible runtime preempts lower-priority queued items at the next valid checkpoint
- interrupt-capable send on non-interruptible runtime rejects
- interrupt-capable send with explicit fallback downgrades visibly
- pause stops autonomous continuation without injecting a new message

---

### Unit 4: Human-facing surfaces and capability-aware UX

**Purpose**

Keep the existing simple human surfaces, but route them through the queue/capability model and align labels with actual semantics.

**Primary files**

- `elixir/lib/symphony_elixir/status_dashboard.ex`
- `elixir/lib/symphony_elixir/terminal_input.ex`
- `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- `elixir/lib/symphony_elixir_web/router.ex`

**Design**

- Web:
  - `Send` remains the primary action
  - relabel current pause control to “Pause after turn” or equivalent safe-boundary language
  - only show/enable “Stop & send” when the runtime advertises interrupt capability
- CLI:
  - `Enter` stays normal send
  - `Alt-Enter` stays newline
  - `/pause` becomes the explicit pause-after-turn local command
  - `/interrupt <message>` becomes the explicit interrupt-capable local command
- HTTP:
  - extend message-posting endpoint/body to carry delivery policy
  - expose capability hints so non-human callers can distinguish checkpoint-only from interrupt-capable targets
- All local slash commands that do not mutate agent conversation stay outside the agent-facing queue.

**Why this shape**

The product goal is not a cockpit of transport modes. It is a boring primary send action with an explicit advanced escape hatch when the runtime can honor it.

**Test files**

- update `elixir/test/symphony_elixir/terminal_input_test.exs`
- update `elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs`
- update `elixir/test/symphony_elixir_web/router_auth_test.exs`
- add or extend LiveView coverage for `DashboardLive` interaction

**Test scenarios**

- CLI normal send still works with existing typing flow
- CLI `/pause` does not enqueue a conversational item
- CLI `/interrupt ...` becomes an interrupt-request item rather than plain text
- web modal shows `Send` as primary and only exposes interrupt when capability says yes
- web pause label reflects safe-boundary semantics
- HTTP message endpoint accepts default checkpoint policy and explicit interrupt policy

---

### Unit 5: Blocker-ticket PubSub production and subscription graph

**Purpose**

Implement the first non-human event flow using existing tracker dependency semantics.

**Primary files**

- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/tracker.ex`
- `elixir/lib/symphony_elixir/linear/client.ex`
- `elixir/lib/symphony_elixir/issue.ex`

**Design**

- Build a subscription index from `blocked_by` metadata already present on `Issue` structs.
- Track enough prior state during poll/reconcile to detect:
  - blocker moved non-terminal -> terminal
  - blocker moved terminal -> non-terminal
  - dependency edge added
  - dependency edge removed
  - blocker entered a failure/human-needed condition if tracker state exposes one materially
- Emit durable coordination events into the blocked issue’s queue only for meaningful dependency changes.
- Do not stream ordinary blocker-agent progress noise by default.
- Keep tracker state as authority for satisfied/unsatisfied dependency transitions; freeform agent logs may enrich the event body later but should not define terminality in v1.

**Why this shape**

The orchestrator already gates dispatch on non-terminal blockers. PubSub should mirror that meaning first. The highest-value first event is “the blocker has crossed the dispatch boundary.”

**Test files**

- update `elixir/test/symphony_elixir/workspace_and_config_test.exs`
- update `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- update `elixir/test/symphony_elixir/extensions_test.exs`
- extend tracker-client tests if needed for dependency state extraction

**Test scenarios**

- dependency edge added creates a subscription/event for the blocked issue
- blocker terminality transition emits a coordination event
- repeated “still blocked” snapshots do not spam the queue
- dependency removal emits a coordination event and removes future delivery path
- blocked issue with no running worker still accumulates event queue state for later consumption

---

### Unit 6: Observability, logging, and agent-log rendering

**Purpose**

Ensure queue-backed human/event delivery is visible and debuggable without confusing it for ticket prompts or generic tool noise.

**Primary files**

- `elixir/lib/symphony_elixir/agent_log.ex`
- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/lib/symphony_elixir/status_dashboard.ex`
- `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`

**Design**

- Preserve current canonical echo behavior for accepted human messages.
- Add queue/control observability events that let operators and tests distinguish:
  - queued
  - delivered
  - rejected
  - downgraded
  - consumed
- Keep blocker-ticket coordination events visually distinct from operator chat rows.
- Avoid brittle content heuristics as the source of truth when metadata can distinguish message provenance.

**Why this shape**

Once human and event delivery share a queue, observability becomes the only practical way to debug priority, checkpoint, and fallback behavior.

**Test files**

- update `elixir/test/symphony_elixir/agent_log_test.exs`
- update `elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs`
- update `elixir/test/symphony_elixir/extensions_test.exs`

**Test scenarios**

- operator message, queue event, and system notice render distinctly
- rejected interrupt request is visible to the operator
- blocker coordination event appears distinctly from ordinary prompt/user rows
- snapshot output remains stable when queued items are pending but not yet consumed

---

## Sequencing

1. **Unit 1 first**: queue shape and storage must exist before any runtime/control refactor.
2. **Unit 2 second**: establish the checkpoint seam and fallback model.
3. **Unit 3 third**: layer interrupt/pause semantics on top of the queue and checkpoint capabilities.
4. **Unit 4 fourth**: wire CLI/web/API surfaces to the capability-aware queue model.
5. **Unit 5 fifth**: add blocker-ticket PubSub using the established queue primitive.
6. **Unit 6 last**: polish observability/logging once the state transitions are real.

This order lets `ce-work` land vertical slices while keeping the risky adapter/session changes ahead of UI promises.

---

## Risks and Mitigations

- **Risk: adapter/session refactor breaks normal turn execution**
  - Mitigation: characterization-first tests around current `run_turn` lifecycle before adding checkpoint behavior.

- **Risk: “sub-turn checkpoint” accidentally violates tool/result ordering**
  - Mitigation: only surface queued items at adapter-declared safe points after protocol-critical sections complete.

- **Risk: queue persistence semantics are unclear for issues with no active workspace**
  - Mitigation: do not tie queue storage to a live worker mailbox or only to an active git worktree; keep queue persistence independent of the worker task lifecycle.

- **Risk: PubSub emits too many low-value events**
  - Mitigation: begin from tracker dependency transitions and terminality changes only; explicitly suppress ordinary progress noise.

- **Risk: UI promises interruption that the runtime cannot actually honor**
  - Mitigation: state-gate interrupt-capable affordances and reject unsupported interrupt requests visibly.

---

## Out of Scope

- General freeform agent-to-agent chat
- Full taxonomy of future event types
- Rich inbox management UI for manual subscription editing or queue triage
- Real-time arbitrary stream injection into unsafe protocol sections
- Per-operator identity/attribution beyond current control surfaces

---

## Integration Test Scenarios

1. Human message sent during ongoing work is consumed at a safe sub-turn checkpoint when the runtime advertises one.
2. Human message sent during ongoing work falls back to turn-boundary delivery when the runtime advertises no finer checkpoint.
3. Interrupt-capable send preempts ordinary queued items only when capability is present.
4. Pause after turn stops autonomous continuation without injecting a conversational item.
5. Blocked issue receives a durable coordination event when its blocker becomes terminal.
6. Blocked issue does not receive repeated duplicate “still blocked” events from unchanged tracker snapshots.
7. CLI `/interrupt` and web “Stop & send” produce the same queue delivery policy.
8. HTTP and human surfaces see the same capability hints for checkpoint-only versus interrupt-capable targets.
9. Queue state survives worker-task replacement and is drained when the issue resumes.

---

## References

- Origin requirements: `docs/brainstorms/2026-05-12-agent-queue-and-pubsub-requirements.md`
- Prior operator-chat plan to reuse and supersede where still relevant: `docs/plans/2026-05-11-feat-agent-chat-send-plan.md`
