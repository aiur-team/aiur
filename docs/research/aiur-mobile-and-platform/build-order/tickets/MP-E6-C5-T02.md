---
ticket_id: MP-E6-C5-T02
feature_id: MP-E6
chunk_id: MP-E6-C5
bucket: 2-platform
title: Draft store — propose_instruction and the draft lifecycle recorded in the transcript
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend; confirm UI is C5-T03/C7-T03)", MP-E6-C5-T01, MP-E6-C6-T01]
prior_units: []
prior_boundaries: [VOX]
prior_features: []
prior_findings: []
size_owner: n/a (new file `drafts.ex`)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C5-T02 — Drafts

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C5.
- **User value:** the line between discussion and instruction is a data structure, not a
  model's judgement: an instruction exists only as a visible draft the operator can confirm,
  edit or discard (brief E6, V5).
- **Deliverable:** `Aiur.VoiceConversation.Drafts` (PROPOSED) — pure functions over session
  state plus transcript appends; tool `propose_instruction(text)`; statuses and transitions
  of contract §5.3; `draft` events to subscribers.

## Dependencies and blockers

- **Predecessors:** C5-T01 (router), C6-T01 (writer).

## Verified starting point

New capability; no draft concept exists at base. Contract §5.3 defines kinds and statuses.

## Chosen design

- `draft_id` = `"vd_" <> 22 base64url chars` (16 random bytes).
- Record `draft{draft_id, kind, status, text, target, base_version?, at}` appended on every
  transition; the session projection is rebuilt from these on resume (C8-T02).
- Transitions (only these): `proposed → confirmed → sent → delivered | failed`;
  `proposed → discarded`; `proposed → stale`; `failed → confirmed` (retry, same id).
- `propose_instruction(text)`: text ≤ 4,000 chars (same cap as the operator composer's
  Command field, `decision_answer.ex:15`), redacted; result to provider: "Draft vd_… is
  waiting for the operator to confirm. Do not say it was sent."
- At most 5 open (`proposed`) drafts per session; the 6th is refused with a tool error text.
- **Confirmation comes only from the client (Phase D, security m4; voice-session V8).** The
  only function that moves a draft to `confirmed` is `Drafts.confirm(state, draft_id,
  %{source: :client_socket, principal: p})`, called by the channel (C7-T01) on a
  `confirm_draft` event. The tool router (C5-T01) never registers a confirm-like tool, and the
  session never inspects provider transcripts or assistant text for confirmation words. A
  provider `tool_call` named `confirm_draft` (or any unknown name) is answered with
  `is_error: true` and changes nothing.

## Implementation steps

1. Draft struct and transition function (table-tested).
2. Tool handler; 3. events; 4. tests.

## Non-happy paths

Invalid transition → `{:error, :invalid_transition}`, nothing written.

## Compatibility and rollout

Internal. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| "propose_instruction creates a proposed draft and sends nothing" | E7 send port call count 0 |
| "only listed transitions are allowed" | table over all pairs |
| "the projection rebuilt from the transcript equals live state" | replay test |
| "the sixth open draft is refused" | — |
| "no provider tool can confirm a draft" | for every registered tool name plus fabricated `confirm_draft`, `confirm`, `send`: a scripted `ToolCall` leaves the draft `proposed`; E7 send and E2 answer ports called 0 times |
| "a provider transcript saying confirm does not confirm" | `UserTranscript{text: "yes, confirm and send it", final?: true}` and `AgentText{"Confirmed, sending now"}` → draft stays `proposed` |
| "confirm requires source client_socket" | `confirm/3` with any other source → `{:error, :not_client}` |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/drafts_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Allow `proposed → sent`: the transition table test fails. Register a
`confirm_draft` tool that calls `confirm/3`: the "no provider tool can confirm" test fails.

**Docs.** None of its own: C9-T01 states "the assistant can only draft; you confirm with the
button" on the voice guide page (`website/docs-app/guide/`).

## Completion and handoff

- [ ] Draft lifecycle and `propose_instruction`.
- **Dependents:** C5-T03, C5-T04, C5-T05, C7-T03, C8-T02.
