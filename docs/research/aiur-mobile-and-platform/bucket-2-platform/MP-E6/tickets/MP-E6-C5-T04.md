---
ticket_id: MP-E6-C5-T04
feature_id: MP-E6
chunk_id: MP-E6-C5
bucket: 2-platform
title: consult_agent — ask the real agent a framed, non-instruction question asynchronously
status: blocked
blocked_by: [DESIGN-E6, E6-OQ2, MP-E6-C5-T02, MP-E6-C5-T03, MP-E6-C1-T01, "MP-E7 contract request (origin option)"]
prior_units: []
prior_boundaries: [VOX, MSG]
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C5-T04 — Consult the agent

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C5.
- **User value:** the assistant can find out what the agent actually thinks ("why did you
  choose that migration?") without the operator switching windows, and without the question
  acting as an instruction.
- **Deliverable:** tool `consult_agent(question)` creating a `consult` draft; delivery as in
  C5-T03 with text framed exactly as the DESIGN-E6-approved copy (proposal in MP-E6 plan §6:
  "Question from the operator's voice assistant. Answer briefly. This is not an instruction;
  do not change your plan."); one outstanding consult per session; the agent's next reply in
  its conversation after `in_context` is captured (C4-T02 port / E4 subscription) and sent to
  the provider as `contextual_update` ("The agent answered: …"); session state `consulting`
  while waiting (contract §6).
- **E6-OQ2:** recommended — the first consult in a session requires an on-screen confirm;
  later consults go when the operator asks aloud. The implementation follows the answer.

## Dependencies and blockers

- **Owner:** E6-OQ2, DESIGN-E6 (framing copy; how a consult looks in the agent transcript).
- **Spike:** RQ-E6-2 — the tool returns immediately ("Asked; I'll tell you when it answers")
  because a reply can take minutes; no tool call stays open.
- **Predecessors:** C5-T02, C5-T03; E7 `origin` request (R-4).

## Verified starting point

- Agent replies are observable in the bounded live conversation
  (`Aiur.LiveConversation.subscribe/1`, `live_conversation.ex:109-110`) and later via E4
  `subscribe(ConversationRef)` (conversations contract §7).

## Chosen design

- Reply capture: first agent message with `occurred_at` after the consult's `in_context`
  receipt; timeout 5 minutes → the assistant is told "No answer yet"; the consult record
  stays open in the transcript (MP-E6 plan §8).
- Listener mode is the agent's configured mode (default `sync`, D13); in `async` mode the
  consult waits for a pull (`read`) — the assistant says so.
- A consult is never sent with `steer`/interrupt semantics chosen by voice (contract §11:
  the voice layer never picks the mode).

## Implementation steps

1. Tool + consult draft kind; 2. confirmation gate per E6-OQ2; 3. reply watcher;
   4. tests.

## Non-happy paths

- Second consult while one is open → tool error text "A question is already waiting."
- Agent ends → consult `stale`; assistant told.
- Session ends while waiting → watcher stops; transcript notes the open consult.

## Compatibility and rollout

Requires E7 and E4/LiveConversation. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| "consult sends exactly one framed message with origin voice_assistant" | stub records text starting with the approved framing |
| "a second consult while one is open is refused" | — |
| "the agent's next reply returns as a contextual update" | FakeProvider `send_context` with the reply text |
| "no reply in 5 minutes tells the assistant" | injected clock |
| "first consult waits for on-screen confirm (if E6-OQ2 = yes)" | send count 0 until `confirm_draft` |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/consult_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Drop the framing prefix: the first test fails.

## Completion and handoff

- [ ] Consult per E6-OQ2; docs (concepts page "relationship to the agent") in C9-T01.
- **Dependents:** C7-T02 (`consulting` state), MP-E4 rendering of `origin` entries.

## Amendment 2026-10-08 — fast voice over a slow agent

Source: [../realtime-convo-research.md](../realtime-convo-research.md) (Kevin's request of
2026-10-08: voice with high-effort agents is "extremely slow and broken up"). Context-handoff
requirement: the voice assistant must be able to answer from a current briefing in about one
second, without stopping or waiting for the coding agent.

- Rename the tool to `ask_agent(question)` (keep `consult` as the transcript record kind).
  It is **non-blocking**: the tool result returns at once ("Asked. I'll tell you when it
  answers."), the assistant keeps talking from the card, and the answer is spoken at the next
  pause (C4-T05 amendment). No tool call stays open (RQ-E6-2 no longer matters for consults).
- **Delivery is `:checkpoint` by default**, never the `AgentChat.send/3` default
  `:interrupt` (`agent_chat.ex:27`). Steer/interrupt only when the operator says the
  question is urgent and the listener mode allows it.
- Routing: questions about the agent's reasoning or history go to the side-query path when it
  exists (MP-E6-C10-T05); questions that need fresh work go to the queued consult.
- While waiting, a progress line every 60 s at most, only if the operator is silent ("Still
  waiting; the agent is in a long test run."), taken from the status card.
