---
ticket_id: MP-E6-C6-T04
feature_id: MP-E6
chunk_id: MP-E6-C6
bucket: 2-platform
title: Operator-initiated deletion of a whole voice conversation (only if E6-OQ5 allows it)
status: blocked
blocked_by: [DESIGN-E6, E6-OQ5, MP-E6-C6-T02, MP-E6-C6-T03]
prior_units: []
prior_boundaries: [VOX]
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C6-T04 — Transcript deletion

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C6.
- **User value:** the operator can remove a conversation they do not want kept, by explicit
  action only — never automatically and never as storage optimisation (brief E6).
- **Deliverable (only if E6-OQ5 = allow; otherwise this ticket closes as "not built"):**
  `TranscriptStore.delete(conversation_id, confirm: conversation_id)`; CLI `aiur voice
  transcripts <id> --delete --confirm <id>`; dashboard Delete in the C8-T01 detail view with a
  confirmation step (DESIGN-E6 copy). The index records a tombstone
  `{deleted_at, by}` (no content), so "a conversation existed and was deleted" stays true.
- **Non-goals:** bulk delete, retention policies (out of scope by D17/brief).

## Dependencies and blockers

Owner E6-OQ5. Predecessors C6-T02, C6-T03.

## Verified starting point

New. The provider copy is already deleted by C2-T04; this removes the local file.

## Chosen design

- Delete only `ended` conversations (an active one refuses: "End the conversation first").
- File removed via rename into `voice-conversations/.deleted/` then unlink after fsync of the
  index tombstone (crash leaves either both or a recoverable rename, never a half state).

## Implementation steps

Store function, CLI flag, detail-view button, tests, docs (`reference/cli.md`,
`concepts` page note).

## Non-happy paths

Mismatched `--confirm` → exit 64; active session → refused.

## Compatibility and rollout

Opt-in action. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| "delete requires the id twice" | mismatch refused |
| "an active conversation cannot be deleted" | refused |
| "deletion leaves a content-free tombstone" | index line has no text fields |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/transcript_delete_test.exs
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Skip the confirm comparison: the first test fails.

## Completion and handoff

- [ ] Built per E6-OQ5, or closed as not built with the owner's answer linked.
