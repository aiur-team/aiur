---
title: "fix: Escalate blocked operator decisions"
type: fix
status: completed
date: 2026-07-10
issue: 934
---

# fix: Escalate blocked operator decisions

## Summary

Convert an agent's open `attention.*` event into a durable, question-bearing
operator alert and re-emit it at a bounded interval until the matching
`attention.resolved` event arrives. Routine pause control remains unchanged.

## Requirements

- R1. An open agent attention creates a needs-attention alert containing its ticket and question.
- R2. Decision attention is distinguishable from a routine pause and reaches the alert feed consumed by `aiurdev watch` and the real-time alert relay.
- R3. An unresolved decision attention is re-surfaced on a bounded interval and stops when resolved.
- R4. Focused tests prove opening, re-asking, resolution, and watch rendering.

## Scope Boundaries

- Do not change ordinary `pause.request` semantics or automatically resume an agent.
- Do not create a second push path; the existing needs-attention alert relay owns PushNotification delivery.

## Implementation Units

### U1. Track and emit decision attentions

**Goal:** Persist active attention slugs and turn each open attention into an operator-visible alert with its question.

**Requirements:** R1, R2, R3

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/agent_runner/tool_executor.ex`
- Create: `src/lib/aiur/decision_attention.ex`
- Modify: `src/lib/aiur/alert_feed.ex`
- Modify: `.aiur/alerts.yaml`
- Modify: `src/prompts/shared-agent-instructions.md`
- Modify: `src/lib/aiur.ex`
- Test: `src/test/aiur/decision_attention_test.exs`
- Test: `src/test/aiur/agent_runner/tool_executor_test.exs`

**Approach:** Use one supervised registry keyed by ticket and attention slug. Opening registers the slug, writes it to `SubscriptionStore`, emits a `ticket.<id>.agent.attention.<slug>` alert with the question and schedules a bounded re-ask. An explicit `attention.*` or a `blocked`/`pause.request` payload marked `reason: operator_decision` opens the same flow. Resolution removes the matching record and cancels future reminders.

**Patterns to follow:** `Aiur.Alerts` structured alert delivery and `Aiur.Events.SubscriptionStore` durable attention state.

**Test scenarios:** Opening an attention persists its slug and writes a warning alert with the question; a timer re-emits the same decision alert; resolution removes the slug and prevents re-asks; unrelated routine pause behavior is unchanged.

**Verification:** Focused registry and tool-executor tests observe alert entries and cancellation.

### U2. Verify operator surfaces consume the alert

**Goal:** Demonstrate that decision alerts appear in `aiurdev watch`'s ACTIONABLE section with their question.

**Requirements:** R2, R4

**Dependencies:** U1

**Files:**
- Modify: `src/test/aiur/agent_control_cli_test.exs`

**Approach:** Reuse the existing alert-feed path instead of duplicating watch or push-notification behavior.

**Patterns to follow:** Existing needs-attention watch assertions in `src/test/aiur/agent_control_cli_test.exs`.

**Test scenarios:** A decision attention alert is rendered under ACTIONABLE with the ticket and operator-decision reason.

**Verification:** Focused CLI test renders the persisted alert in the actionable output.
