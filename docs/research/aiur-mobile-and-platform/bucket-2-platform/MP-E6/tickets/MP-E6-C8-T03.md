---
ticket_id: MP-E6-C8-T03
feature_id: MP-E6
chunk_id: MP-E6-C8
bucket: 2-platform
title: Link a delivered draft to its position in the agent conversation (E4 anchor)
status: blocked
blocked_by: [DESIGN-E6, DESIGN-E4, MP-E6-C8-T01, MP-E4-C3, MP-E7-C3]
prior_units: []
prior_boundaries: [VOX, WEB]
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C8-T03 — Draft → agent conversation link

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C8.
- **User value:** from a voice transcript, one click shows the exact place in the agent's
  conversation where a confirmed instruction or consult landed, and what the agent did next.
- **Deliverable:** when a draft reaches `delivered`, record `delivery{draft_id, delivery_id,
  pos}` where `pos` is the E4 journal position of the entry with that `delivery_id`
  (RC-07: the journal position is the anchor address); the history view renders a link to
  `/conversations/:conversation_id?pos=N` (E4-C5 route, final path per DESIGN-E4).

## Dependencies and blockers

DESIGN-E6, DESIGN-E4. Predecessors MP-E4-C3 (journal positions), MP-E7-C3 (delivery ids),
C8-T01.

## Verified starting point

New; anchor rules in `contracts/conversations-transcripts-anchors.md` and RC-07.

## Chosen design

- Resolve `pos` by subscribing to the agent conversation (E4 `subscribe/1`) for the
  `delivery_id`, with a 10-minute window; unresolved → link omitted with "position unknown"
  (never a guessed position).

## Implementation steps

Resolver, record, link rendering, tests.

## Non-happy paths

Agent restarted into a new session → link points into the session that received it (E4
sessions overlap pages).

## Compatibility and rollout

Ships with DESIGN-E6/E4. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| "a delivered draft records the journal position of its delivery id" | — |
| "an unresolved delivery renders position unknown" | no link |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/anchor_link_test.exs
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Use the latest position instead of the matched one: the first test fails.

## Completion and handoff

- [ ] Anchored links for delivered drafts.
