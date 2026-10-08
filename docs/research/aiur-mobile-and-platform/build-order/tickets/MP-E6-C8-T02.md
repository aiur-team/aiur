---
ticket_id: MP-E6-C8-T02
feature_id: MP-E6
chunk_id: MP-E6-C8
bucket: 2-platform
title: Continue a past conversation — seed a new session with the previous tail and open drafts
status: blocked
blocked_by: [DESIGN-E6, MP-E6-C8-T01, MP-E6-C4-T03, MP-E6-C5-T02]
prior_units: []
prior_boundaries: [VOX, WEB]
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C8-T02 — Continue

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C8.
- **User value:** context recovery when returning later (brief E6): "Continue" picks up where
  the last talk ended, including drafts still waiting for confirmation.
- **Deliverable:** `Session.start_session(target, role_id, client, continue_from:
  conversation_id)`; ContextBuilder `prior` block = last N final turns (budgeted) + every
  draft still `proposed` (re-validated: stale ones are marked stale first); the new
  transcript's `session_started` carries `continued_from`. "Continue" button on the history
  detail and the ended panel.
- **Running summary:** none. An optional derived recap is out of scope; the transcript tail
  is the context (MP-E6 plan §3 decision).

## Dependencies and blockers

DESIGN-E6. Predecessors C8-T01, C4-T03, C5-T02.

## Verified starting point

New. Draft projection rebuild from records (C5-T02 replay test).

## Chosen design

- Open drafts are **carried**, not copied: the old draft ids stay valid and confirmable from
  the new session (same `draft_id` = same idempotency key), and the new transcript records
  `draft_carried{draft_id, from}`.
- Continue across a daemon restart works (everything is on disk).

## Implementation steps

Session option, ContextBuilder `prior` input, button wiring, tests.

## Non-happy paths

Previous conversation's target is gone → Continue disabled with reason; the history stays
readable.

## Compatibility and rollout

Ships with DESIGN-E6. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| "Continue includes open drafts in the context" | FakeProvider `open` context lists the draft text |
| "a carried draft confirms once across both sessions" | confirm in new session → one send with the original id |
| "a draft whose Command was resolved is stale on Continue" | — |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/continue_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Mint new draft ids on carry: the "confirms once" test fails (two ids).

## Completion and handoff

- [ ] Continue with carried drafts.
- **Dependents:** MP-N6/N7 "resume converse".
