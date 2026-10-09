---
ticket_id: MP-E6-C6-T02
feature_id: MP-E6
chunk_id: MP-E6-C6
bucket: 2-platform
title: Transcript index, boot reconciliation of unfinished sessions, cap accounting and list/get read API
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C6-T01, MP-E6-C2-T04]
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

- **Predecessors:** C6-T01; C2-T04 (`ProviderCleanup.enqueue/2`, called by the boot
  reconciliation; Phase D, M1).

## Verified starting point

New. Pagination semantics follow the conversations contract (`before`/`after` cursors,
limit 1..200 there; 1..500 here because transcript lines are short).

## Chosen design

- Index rebuilt from transcript files at boot if missing or torn (scan headers and
  `session_ended` lines).
- **Boot reconciliation of unfinished sessions (Phase D, M1; voice-session §9).** Every boot,
  before the voice-conversation supervisor accepts a `start_session`, scan each transcript
  that has no `session_ended`. For each: append and fsync
  `session_ended{reason: "daemon_restart", at: <last record's at>, duration_s: <that at −
  session_started.at>}`; write the index `closed` line with `end_reason: "daemon_restart"`;
  then call `ProviderCleanup.enqueue(provider_id, conversation_id)` for every
  `provider_conversation` record in the file. The reason is a recorded fact (the daemon lost
  the session), not an inferred user action, so it is never `user_end`. A transcript with no
  `provider_conversation` record (crash before the provider named it) gets the `session_ended`
  line and no enqueue. The scan is idempotent: a second boot finds `session_ended` and does
  nothing.
- **Cap accounting (Phase D, M8).** `minutes_today/0` = sum of `duration_s` over sessions
  started today (local time), including `daemon_restart` sessions, plus the elapsed time of
  sessions still open in this boot (from the live registry, injected). A crashed session
  therefore never takes minutes off the count.
- `get/2` streams the file by line number (`seq` = line index); returns records plus
  `next_cursor`.
- Read API has no write side effects.

## Implementation steps

1. Index writer hooks in `open/2` and on `session_ended`.
2. Boot rebuild and boot reconciliation (module `Aiur.VoiceConversation.BootReconcile`,
   called from the voice-conversation supervisor's `init/1` before the session supervisor
   child starts; `enqueue` and the clock injected).
3. list/get.
4. `minutes_today/0` with open-session elapsed time.

## Non-happy paths

| Case | Behaviour |
| --- | --- |
| Index/file disagreement | files win; index rebuilt and a warning logged |
| Torn last line in an unfinished transcript | skipped (C6-T01 rule); `at` taken from the last whole record |
| `ProviderCleanup` not running at boot scan | the enqueue is written to its queue file directly through its persisted API (C2-T04 `enqueue/2` appends before it schedules), so nothing is lost |
| Append of `session_ended` fails (disk full) | the transcript stays unfinished, the enqueue still runs, one warning; next boot retries |

## Compatibility and rollout

Internal. Rollback: revert (index is derived).

## Verification

| Test | Expected |
| --- | --- |
| "a 2,000-turn transcript paginates without gaps or duplicates" | walk `after` cursors; every seq once |
| "a transcript with a provider id and no session_ended is enqueued at boot" | fixture file with `provider_conversation` and no end; fake `enqueue` receives `{provider_id, conversation_id}` exactly once; file now ends with `session_ended{daemon_restart}` |
| "boot reconciliation is idempotent" | run twice; one `session_ended`, one enqueue |
| "a crashed conversation lists end_reason daemon_restart" | index line after the scan |
| "crashed session counts toward minutes_today" | `started_at` 10:00, last record 10:12, no end → `minutes_today` includes 12 |
| "an open session counts its elapsed time" | registry fake with a session started 5 min ago |
| "the index is rebuilt from files when missing" | delete index → same list |
| "minutes_today sums durations for today in local time" | fixtures across midnight |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/transcript_index_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation checks.** Skip the boot scan: the "enqueued at boot" test fails. Default a missing
end reason to `user_end` or `unknown`: the crash-listing test fails. Count only `closed` lines
with a duration from a clean end: the "crashed session counts" test fails.

**Docs.** None of its own: the end-reason table and the cap rule are documented by C4-T01 /
C9-T01 (`website/docs-app/concepts/`), and this ticket adds one sentence there: "a session
interrupted by a daemon restart is closed as `daemon_restart` at the next start, its minutes
count, and the provider copy is deleted".

## Completion and handoff

- [ ] Index, boot reconciliation, list/get, minutes_today.
- **Dependents:** C6-T03, C8-T01, C8-T02, C4-T01 (daily cap).

## Amendment 2026-10-09 — independent package

Source: [../plan.md](../plan.md) §17. Kevin, 2026-10-09: build the voice assistant as "its own
independent package that can be used separately from [aiur]". The core is the Mix project
`packages/elixir/voice_converse/` (OTP app `:voice_converse`, namespace `VoiceConverse.*`).
It has no `Aiur.*` reference, and aiur is one host behind ports (§17.4). Module moves:
plan §17.9. Core tests run with `env -C packages/elixir/voice_converse mise exec -- mix test`
and do not boot aiur.

- Home: `VoiceConverse.TranscriptIndex` (`list/2`, `get/2`, `minutes_today/1`, boot
  reconciliation on instance start). The reconciliation runs inside
  `VoiceConverse.child_spec/1`, so a standalone host gets the same crash cleanup.
