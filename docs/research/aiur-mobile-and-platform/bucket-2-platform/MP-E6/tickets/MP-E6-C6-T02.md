---
ticket_id: MP-E6-C6-T02
feature_id: MP-E6
chunk_id: MP-E6-C6
bucket: 2-platform
title: Transcript index and list/get read API with pagination
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C6-T01]
prior_units: []
prior_boundaries: [VOX]
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C6-T02 — Index and read API

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C6.
- **User value:** past conversations are findable per ticket or for the Executor, and long
  ones open quickly.
- **Deliverable:** `index.ndjson` maintained by the store (one `opened` and one `closed` line
  per conversation: id, target, role_id, started_at, ended_at, end_reason, turn_count,
  draft counts by status, duration_s) and the API
  `TranscriptStore.list(filter: %{target?, since?}, limit: 1..100, before: cursor)` and
  `get(conversation_id, after: seq, limit: 1..500)`. Also `minutes_today/0` for the daily cap
  (C4-T01).

## Dependencies and blockers

- **Predecessors:** C6-T01.

## Verified starting point

New. Pagination semantics follow the conversations contract (`before`/`after` cursors,
limit 1..200 there; 1..500 here because transcript lines are short).

## Chosen design

- Index rebuilt from transcript files at boot if missing or torn (scan headers and
  `session_ended` lines); a conversation without `session_ended` after a crash is listed with
  `end_reason: "unknown"` (never inferred).
- `get/2` streams the file by line number (`seq` = line index); returns records plus
  `next_cursor`.
- Read API has no write side effects.

## Implementation steps

1. Index writer hooks in `open/2` and on `session_ended`; 2. boot rebuild; 3. list/get;
   4. `minutes_today/0`.

## Non-happy paths

Index/file disagreement → files win; index rebuilt and a warning logged.

## Compatibility and rollout

Internal. Rollback: revert (index is derived).

## Verification

| Test | Expected |
| --- | --- |
| "a 2,000-turn transcript paginates without gaps or duplicates" | walk `after` cursors; every seq once |
| "a crashed conversation lists end_reason unknown" | file without `session_ended` |
| "the index is rebuilt from files when missing" | delete index → same list |
| "minutes_today sums durations for today in local time" | fixtures across midnight |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/transcript_index_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Default a missing end reason to `user_end`: the crash test fails.

## Completion and handoff

- [ ] Index, list/get, minutes_today.
- **Dependents:** C6-T03, C8-T01, C8-T02, C4-T01 (daily cap).
