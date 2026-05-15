---
date: 2026-05-14
topic: CLI interrupt-first operator input and separate composer rendering
branch: symphony/agent-pubsub
status: ready-for-planning
---

# CLI interrupt-first operator input and separate composer rendering

## Summary

Rework the CLI chat model so operator typing is rendered independently from the dashboard refresh cycle and every submitted message is delivered with an interrupt-first policy. The visible queued-input section stays as the honest UI, but it should act as a short-lived safety buffer rather than a long-lived workflow state.

## Problem Frame

The current checkpoint-first model is producing repeated failures and rework:

- Typing improved but still visibly batches behind rendering pauses, which means local input is still coupled to dashboard redraw work.
- Pressing Enter still causes the log pane and surrounding chrome to disappear and then reappear, which makes submission feel unstable.
- Queued input is not draining reliably. Messages can disappear from the grey queue without entering the canonical log, and pause/unpause paths still produce inconsistent outcomes.
- The queue/checkpoint delivery model is adding substantial complexity while failing at the user-visible goal: "I typed a message, the agent should get it now."

These issues suggest the approach itself is wrong, not just one more bug in the current implementation.

## Requirements

1. Typing in the CLI composer must be real-time and must not wait on dashboard snapshot refresh, log parsing, or top-pane redraw.
2. Pressing Enter must leave the main log body visually stable; the log pane and top chrome must not blank or disappear during submission.
3. Submitted text must move immediately into the grey queued-input section above the composer.
4. The queued-input section must preserve FIFO ordering for multiple submissions and remain accurate if several messages are entered quickly.
5. User-visible delivery semantics must be interrupt-first: submitting a message should immediately ping the running agent instead of waiting for a passive safe checkpoint as the normal path.
6. The grey queued-input section should usually drain almost immediately after submission, but remain visible until delivery has been confirmed.
7. The main chat log should only gain the operator message once the runtime or delivery path has actually accepted it; the queue is the honest state before that.
8. If immediate interrupt delivery cannot happen, backend queueing may still exist, but it is a fallback transport detail rather than the primary interaction model.
9. Pause / resume must remain compatible with this model, but "pause first, then type" should no longer be the only reliable way to get text into the log.

## Key Decisions

- Keep the grey queued-input section in the UI.
- Do not optimistically append operator messages directly into the main chat log on Enter.
- Change the delivery model from checkpoint-first to interrupt-first.
- Separate composer rendering from the main dashboard render loop so local typing is not blocked by log or snapshot work.
- Treat any backend queue as durability/transport plumbing, not as the user-facing interaction model.

## Scope Boundaries

### In scope

- CLI composer rendering architecture
- Interrupt-first operator message delivery
- Grey queued-input section behavior and drain semantics
- Confirmation rules for when queued input becomes a canonical log entry
- Regression coverage for pause/resume, rapid multi-submit, and stable rendering

### Out of scope

- PubSub or cross-agent event features
- New web UX beyond shared logic changes that may later be ported
- Rich retry/history controls beyond accurate queued-input visibility
- Broader agent event architecture work unrelated to CLI operator input

## Notes For Planning

- The current `2026-05-14-fix-cli-pending-input-and-operator-delivery-plan.md` plan reflects the older checkpoint-first model and should not be treated as the source of truth for next implementation work.
- Planning should start from this interrupt-first model and decide whether immediate delivery is best implemented as true interrupt, pause-send-resume, or another equivalent transport path.
