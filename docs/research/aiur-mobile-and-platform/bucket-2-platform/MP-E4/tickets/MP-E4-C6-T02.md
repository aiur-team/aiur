---
ticket_id: MP-E4-C6-T02
feature_id: MP-E4
chunk_id: MP-E4-C6
bucket: 2-platform
title: "Answer this agent's open Commands inline in its conversation"
status: blocked
blocked_by: [DESIGN-E4, DESIGN-E2, MP-E7-C3-T03, MP-E2-C1-T01, MP-E2-C3-T01, MP-E4-C4-T02]
prior_units: [U8]
prior_boundaries: [WEB, DEC]
prior_features: [MP-E2 (Command answer contract, supersede rule D11)]
prior_findings: [RC-05 (chunk-level dependency); D15; contract conversations-transcripts-anchors §9.2]
size_owner: "U8 WEB owner"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C6-T02 — Inline Command answers

## Identity and outcome

- Bucket 2 · MP-E4 · C6 · T02.
- **User value:** when the agent asks, answer it right where it asked, without
  leaving the conversation.
- **Deliverable:** an inline Command card (open Commands whose requester is this
  conversation's subject) that answers through the existing dashboard answer
  path, shows "already answered by …" when another surface won, and never edits
  the transcript.
- **Non-goals:** new Command fields or routing (MP-E2); supersede UI beyond what
  MP-E2-C3 defines.

## Dependencies and blockers

- **RC-05** puts every E4-C6 write chunk behind MP-E7-C3. This ticket does not
  use the listener path (Command answers are excluded from listener modes,
  listener-mode contract §2), so the coordinator may lift that dependency; it is
  kept here until the coordinator says so (CONTRACT-REQUESTS.md, item 4).
- DESIGN-E4 (card placement), DESIGN-E2 (card content and states).
- MP-E2-C1-T01 (v2 fields), MP-E2-C3-T01 (answer resolution, "already answered" summary in the conflict response).
- MP-E4-C4-T02 (Command anchors in the conversation).

## Verified starting point

- Dashboard answer path: `phx-submit="answer-decision"` in `DecisionAction`
  (`components/operator_control_center/decision_action.ex:59`) →
  `DecisionEvents.handle("answer-decision", …)` →
  `DecisionCommands.record_answer/4` (`operator_control_center/decision_events.ex:30-32`).
  Store: `DecisionStore.answer/5` (`decision_store.ex:188-193`).
- Command detail component to reuse: `DecisionAction.decision_action/1` with
  `decision`, `state`, `writable` (`decision_detail.ex:26-31`).
- Requester link: `Decision.source.session_id` (provider thread id) and
  `decision.ticket.identifier` (`decision.ex:17,113-117`).

## Chosen design

- `ConversationLive` loads open Commands for the subject: worker → Commands
  with `ticket.identifier` equal to the subject's identifier and status open
  (existing DecisionStore list API used by the inbox); executor → MP-E2-C6
  Executor-originated Commands (when MP-E3 provides the subject).
- Each card renders `DecisionAction.decision_action/1` unchanged, placed at the
  Command's anchor position (C4-T02) or, without an anchor, pinned at the top
  with "position unknown".
- Events `answer-decision` etc. are delegated to `DecisionEvents.handle/4`
  (add `ConversationLive` as a caller; no new answer logic). `expected_version`
  and conflict handling come from MP-E2-C3; a conflict shows the winning answer
  and actor.
- After the answer, the card shows resolved state from the Command store, not
  from the transcript (plan §6). The transcript shows the agent receiving the
  answer when it does.
- Subscribe to the Command lifecycle PubSub the inbox uses so a card resolves
  live when answered elsewhere.

## Implementation steps

1. Query + subscription in `ConversationLive` (≤ 40 lines).
2. Render `decision_action/1` inside the entry stream at the anchor, or pinned.
3. Delegate the decision events.

## Non-happy paths

- Read-only dashboard: cards render without answer controls (`writable: false`,
  same as the inbox).
- Answered elsewhere first: the card switches to "Answered by <actor>" via the
  lifecycle subscription; a late submit gets the MP-E2-C3 conflict response.
- Multi-question native Commands (MP-E2-C4/C5): rendered by MP-E2's form
  component; if that component is not yet available, the card links to
  `/commands/:id` instead of answering inline.

## Compatibility and rollout

- No new answer path. Rollback: remove the cards.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur_web/live/conversation_commands_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "open Command of this ticket renders at its anchor" | card after entry `pos` | placement |
| "Command of another ticket is not shown" | absent | subject filter |
| "answer goes through DecisionEvents" (spy) | `record_answer/4` called once | delegation |
| "answered elsewhere resolves the card live" | "Answered by …" | lifecycle subscription |
| "read-only shows no answer controls" | no submit button | writable flag |
| "no edit/hide control exists on any entry" (static render scan) | none | — guard for D15, not counted as coverage |

## Completion and handoff

- [ ] Cards behave identically to the inbox for the same Command.
- [ ] `guide/gui.md` "Conversations" section notes inline answers.
- Dependents: MP-E3-C6-T03 (Executor blockers panel reuses the card).
