---
ticket_id: MP-E6-C2-T04
feature_id: MP-E6
chunk_id: MP-E6-C2
bucket: 2-platform
title: Delete each provider conversation after the local transcript is durable, with a persistent retry queue
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C2-T02, MP-E6-C6-T01]
prior_units: []
prior_boundaries: [VOX]
prior_features: [integrations-51]
prior_findings: []
size_owner: n/a (new file)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C2-T04 — `ProviderCleanup`

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C2.
- **User value:** copies of the operator's conversations do not accumulate at ElevenLabs
  (default retention 2 years, `../provider-research.md` §2); aiur keeps the only full
  transcript locally (D17, contract §10).
- **Deliverable:** `Aiur.VoiceConversation.ProviderCleanup` (PROPOSED GenServer) with
  `enqueue(provider_conversation_id, conversation_id)`; it calls `DELETE
  /v1/convai/conversations/{id}` (<https://elevenlabs.io/docs/api-reference/conversations/delete>,
  accessed 2026-10-06), retries with backoff, persists pending deletions so a restart does not
  forget them, and raises one needs-attention alert after the retry budget is spent.
- **Non-goals:** proving what `DELETE` removes (spike RQ-E6-3).

## Dependencies and blockers

- **Predecessors:** MP-E6-C2-T02 (http seam and error mapping); MP-E6-C6-T01 (state dir and
  fsync writer; the queue file lives beside transcripts).
- **Invariant from the contract:** enqueue happens only **after** the transcript's
  `session_ended` record is fsynced (contract §9 write rule). Two callers: C4-T01 on a normal
  end, and the boot reconciliation in C6-T02 for sessions a crash or restart interrupted, after
  it writes `session_ended{daemon_restart}` (Phase D, M1). `enqueue/2` appends to the queue
  file before it schedules, so it is safe to call during boot.

## Verified starting point (base `45a290e3`)

- Durable write precedent: `DecisionStore` append + fsync before notify (MP-E6 plan §1);
  state root `Aiur.Config.Paths.decision_state_dir/0` (`paths.ex:60-66`) and derived leaf
  precedent `current_run_membership_state_dir/0` (`paths.ex:76-87`).
- Alert path: `Aiur.Alerts.emit_custom(name, message, opts)` (`src/lib/aiur/alerts.ex:108-119`),
  the daemon-side alert emitter with a stable name; this ticket uses the name
  `voice-conversation-delete-failed`.

## Chosen design

- Queue file `<voice_conversation_state_dir>/provider-cleanup.ndjson`: lines
  `{"op":"enqueue","provider_id","conversation_id","at"}` and
  `{"op":"done"|"gave_up","provider_id","at","status"}`. On boot, pending = enqueued minus
  done/gave_up.
- Retry schedule: 30 s, 2 min, 10 min, 1 h, 6 h, then every 24 h up to 7 days; `404` counts
  as done (already gone); `401/403` pauses the queue and raises the alert once
  ("ElevenLabs refused to delete voice conversations; check the key's Agents permission").
- On give-up: write `gave_up`, raise one alert naming the count, and append
  `provider_delete_failed` to the conversation's transcript (C6) so a reviewer sees it.
- Provider ids are not secrets but are never shown in the dashboard; they appear only in the
  transcript and the queue file.

## Implementation steps

1. GenServer with injected http and clock/scheduler (no test waits on time).
2. Persistent queue read/append through the C6-T01 writer.
3. Alert on auth failure and on give-up via `Aiur.Alerts.emit_custom/3` (injected in tests).
4. Supervise under the voice-conversation supervisor (C4-T01).

## Non-happy paths

| Case | Behaviour |
| --- | --- |
| Daemon restart with pending items | reloaded and retried |
| Torn last line in the queue file | skipped and reported (C6-T01 recovery rule) |
| Key removed | queue pauses with `unconfigured`; resumes when a key appears |
| Many sessions | requests serialized, ≤ 1 in flight |

## Compatibility and rollout

New file in the daemon-private state dir. No config. Rollback: revert; leftover queue file is
inert.

## Verification

| Test | Expected |
| --- | --- |
| "a successful delete marks the item done" | fake http 204 → `done` line; pending empty |
| "404 counts as done" | done |
| "a 500 retries on the schedule" | injected scheduler sees 30 s then 2 min |
| "pending deletions survive a restart" | stop, start with the same dir → retried |
| "401 pauses and alerts once" | one alert for three items |
| "give-up writes provider_delete_failed into the transcript" | transcript file has the record |
| "enqueue during boot, before the scheduler runs, is persisted" | call `enqueue/2` before the first tick, stop, restart → item pending and retried |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/provider_cleanup_test.exs
make -C src fmt-check lint
```

Tests use a temp state dir via the `:decision_state_dir` app env (`paths.ex:62-63`). Run in
an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Skip the boot reload: the restart test fails. Treat 404 as failure: the
404 test fails.

## Completion and handoff

- [ ] Queue, retries, alerts, tests.
- [ ] Docs: covered by MP-E6-C9-T01 privacy table ("deleted after each session; retried").
- **Dependents:** MP-E6-C4-T01, MP-E6-C6-T02 (boot reconciliation; its test "a transcript
  with a provider id and no session_ended is enqueued at boot" covers the crash path, M1).
