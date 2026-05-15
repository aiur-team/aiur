---
date: 2026-05-15
topic: alert-lifecycle
---

# Alert Lifecycle Requirements

## Summary

Symphony should treat alerts as first-class lifecycle events that are always written to logs and may optionally play audio. Alerts are named with scoped identifiers, configured through a checked-in `alerts.yaml` with inline event definitions, and divided between Symphony-owned system events and agent-emitted custom workflow milestones.

---

## Problem Frame

Symphony already has meaningful moments in the life of a task, agent run, and operator interaction, but those moments are not yet expressed through a single alert model. The user wants important operational transitions to be visible without watching the UI constantly, while also keeping the feature lightweight enough that it does not require a new orchestration subsystem.

The feature also needs to support opinionated task flows where agents may explicitly mark research, planning, or implementation milestones. Those milestones should be durable enough to appear in logs and optional enough that the system does not need to hard-enforce a full phase machine before the team is ready for it.

---

## Actors

- A1. Operator: configures alert sounds, reviews logs, and wants to be notified when meaningful work or UI events happen.
- A2. Symphony runtime: emits authoritative system alerts for task, agent, and chat lifecycle moments from tracker and UI activity.
- A3. Active agent/workflow: emits advisory milestone alerts for custom workflow moments.

---

## Key Flows

- F1. System lifecycle alert
  - **Trigger:** Symphony observes a meaningful built-in event such as a task starting, an agent slot shortage, or a chat action.
  - **Actors:** A1, A2
  - **Steps:** Symphony emits an alert event with a scoped name, title, and message; the event is written to logs; if audio is configured for that alert, Symphony picks one clip at random and plays it.
  - **Outcome:** The moment is durably visible in logs and optionally audible.
  - **Covered by:** R1, R2, R3, R4, R5

- F2. Agent milestone alert
  - **Trigger:** The active agent or workflow decides to announce a milestone such as brainstorming, planning, work, or review.
  - **Actors:** A1, A3
  - **Steps:** The agent emits an alert event with a scoped custom name plus title and message; Symphony records it in logs; audio playback occurs only if configured for that name.
  - **Outcome:** Workflow milestones become visible and optionally audible without requiring Symphony to enforce a rigid phase machine.
  - **Covered by:** R2, R3, R6, R7, R15, R16, R17, R18

---

## Requirements

**Alert model**
- R1. Symphony must model alerts as lifecycle events rather than as audio-only side effects.
- R2. Every emitted alert must contain exactly two user-facing fields: `name` and `message`.
- R3. Alert names must be scoped strings.
- R4. Symphony must support these default top-level scopes: `task`, `phase`, `agent`, and `chat`.
- R5. `chat.*` alerts may represent UI and operator actions such as opening, closing, or sending chat interactions.
- R6. Alert names under `task.*`, `agent.*`, and `chat.*` are system-owned and must not be agent-emittable.

**Alert logging and playback**
- R7. Every alert must be written to logs even when no audio clip is configured for it.
- R8. Audio playback must be optional and secondary to the alert event itself.
- R9. Symphony must read alert definitions from a checked-in `alerts.yaml` file that users can edit directly.
- R10. Each `alerts.yaml` entry must define `name` and `message`, and may optionally define `sound`.
- R11. When multiple audio clips are configured for the same alert name, Symphony must choose one clip at random for playback.
- R12. Alert log rendering must show a dedicated `[alert]` label instead of folding alert events into generic system log output.

**Built-in and custom lifecycle coverage**
- R13. Symphony must emit built-in tracker-state alerts using normalized `task.*` names that correspond to observed tracker states such as `task.todo`, `task.in-progress`, `task.human-review`, `task.rework`, `task.merging`, `task.done`, and cancellation variants.
- R14. Those `task.*` alerts must be emitted by the tracker/event-listener path that already observes task state changes rather than by the agent process.
- R15. Symphony must support a built-in `task.todo.more_agents` system alert that fires once when the number of todo tasks exceeds `agent.max_concurrent_agents`.
- R16. Symphony must support a built-in `agent.more_tokens` system alert for agent token exhaustion or equivalent token-budget failure signals.
- R17. The `phase.*` namespace must remain open-ended rather than restricted to a fixed catalog.
- R18. Agents and workflows must be able to emit custom alerts for workflow milestones using the same `name` and `message` structure.
- R19. The alert feature must support advisory lifecycle milestones such as brainstorming, planning, work, or review without requiring Symphony to introduce a hard-enforced task phase state machine in v1.
- R20. The initial shared agent guidance must direct agents to use paired `phase.*.start` and `phase.*.end` alerts for brainstorming, planning, work, and review when they explicitly choose those delivery phases.
- R21. Unknown custom alert names must still be accepted as loggable events even when they are absent from `alerts.yaml`; they simply produce no audio until configured.

---

## Acceptance Examples

- AE1. **Covers R7, R8, R21.** Given an alert is emitted and no audio clips are configured for its name, when Symphony processes the event, the alert still appears in logs and no playback is required.
- AE2. **Covers R10, R11.** Given `task.todo` defines three audio clips, when `task.todo` is emitted, Symphony plays one of the three clips chosen at random.
- AE3. **Covers R12.** Given an alert is rendered in the log surfaces, when Symphony formats it, the entry uses a dedicated `[alert]` label.
- AE4. **Covers R13, R14.** Given a tracked issue moves from `agent:todo` to `agent:in-progress`, when Symphony observes the state change, Symphony emits `task.in-progress` from the tracker/event-listener path rather than from the agent process.
- AE5. **Covers R15.** Given the number of todo tasks exceeds `agent.max_concurrent_agents`, when Symphony first observes that condition, it emits `task.todo.more_agents` once for that overload condition.
- AE6. **Covers R16.** Given an agent turn fails because the backend reports token exhaustion or an equivalent terminal token-budget condition, when Symphony classifies that failure, it emits `agent.more_tokens`.
- AE7. **Covers R17, R18, R19, R20.** Given a workflow decides a large feature needs brainstorming, when the active agent uses `ce-brainstorm`, it emits `phase.brainstorm.start` on entry and `phase.brainstorm.end` on exit, and Symphony records each alert.
- AE8. **Covers R6.** Given an agent attempts to emit `task.done`, when Symphony validates the alert, the system rejects it because `task.*` is system-owned.

---

## Success Criteria

- Operators can rely on logs as the complete record of alert-worthy moments, regardless of whether audio is configured.
- Operators can customize audible feedback by editing `alerts.yaml` without needing to store media files in the repo itself.
- Workflow authors can add phase-oriented milestone alerts without needing Symphony to implement a rigid lifecycle engine first.
- System-owned tracker and UI alerts remain authoritative because they are emitted outside the agent process.
- A later implementation plan can focus on event ownership, emission surfaces, and playback wiring without having to invent product behavior or naming rules.

---

## Scope Boundaries

- v1 does not require a general-purpose hook execution framework.
- v1 does not require Symphony to enforce a mandatory task phase machine for every run.
- v1 does not require all alerts to have configured audio.
- v1 does not require remote media hosting; local paths and URLs are both acceptable configuration targets.
- v1 does not require agents to emit or understand system-owned alerts under `task.*`, `agent.*`, or `chat.*`.
- v1 does not require a closed phase vocabulary beyond the initial shared guidance for brainstorming, planning, work, and review milestones.

---

## Key Decisions

- Alerts are lifecycle events first and audio playback second: this keeps logs authoritative and makes sound optional.
- Alert names use scoped identifiers: this gives room for built-in and custom alert growth without a flat namespace collision problem.
- `task.*`, `agent.*`, and `chat.*` are system-owned: this keeps tracker and UI alerts authoritative and separate from agent behavior.
- `phase.*` remains open-ended: this preserves flexibility for opinionated workflows without prematurely freezing a universal task lifecycle model.
- `alerts.yaml` is checked in directly rather than using an example-only file: the user wants repo defaults that can be edited in place.
- The initial system alert catalog follows normalized tracker states plus a small set of capacity, token-exhaustion, and chat events rather than a broader lifecycle engine.

---

## Dependencies / Assumptions

- The system already has enough durable run and UI events to back the first set of built-in alerts.
- Agents are trusted enough to emit advisory milestone alerts for workflow phases.
- Random clip selection is acceptable behavior and does not require deterministic or weighted playback in v1.
- Audio files may temporarily live in-repo for bootstrap convenience, but the intended runtime path is outside the repo under `~/alerts`.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R9, R10, R11][Technical] What exact `alerts.yaml` parsing rules should apply for single-clip versus multi-clip entries while staying easy to edit by hand?
- [Affects R7, R12, R16][Technical] Where should alert events be surfaced in existing logs and dashboards so they read clearly alongside current event output?
- [Affects R14][Technical] What dedupe rule should determine when `task.todo.more_agents` can fire again after the overload condition clears and later returns?
- [Affects R15][Technical] Which concrete backend error or rate-limit signals should be classified as `agent.more_tokens` across Codex and Claude?
