---
ticket_id: MP-N4-C3-T02
feature_id: MP-N4
chunk_id: MP-N4-C3
bucket: 3-mobile-watch
title: Durable push outbox — persist-before-send, idempotent per (intent, device), restart resume
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C3-T00, MP-N4-C3-T01]
prior_units: []
prior_boundaries: [new #41 candidate push-relay, DEC #27 (persist-before-notify precedent)]
prior_features: [MP-N5 (writes intents, owns staleness rules)]
prior_findings: [plan §4 "Commands persist before they notify"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C3-T02 — Push outbox

## Identity and outcome

Bucket 3, MP-N4, chunk C3. Deliver `Aiur.Push.Outbox` (PROPOSED,
`src/lib/aiur/push/outbox.ex`): a per-instance, append-only ndjson journal plus an
in-memory projection that records every `(intent_id, device_id)` delivery job **before**
any network call, its attempts and its terminal outcome. On restart it resumes unsent
jobs, after asking the MP-N5 staleness hook whether each is still worth sending.

API (PROPOSED):

```elixir
@spec accept(NotificationIntent.t(), [device_id]) :: {:ok, [job_id]} | {:error, term()}
@spec next_due(now) :: [job]             # jobs whose next_attempt_at <= now
@spec record(job_id, outcome) :: :ok      # :sent | {:retry, at} | {:gone} | {:dropped, reason} | {:encode_failed}
@spec purge_device(device_id) :: :ok      # unpair (C3-T05)
```

Non-goals: deciding what to send (MP-N5), sealing/sending (C3-T03).

## Dependencies and blockers

- C3-T00, C3-T01. DESIGN-N4 releases C3 core. MP-N5-C2/C3 call `accept/2` and provide the
  staleness hook; the outbox works with a stub hook until then.

## Verified starting point

- Persist-before-notify precedent: `Aiur.DecisionStore` fsyncs `decisions.ndjson` before
  projecting and publishing (moduledoc; `request/2` at `src/lib/aiur/decision_store.ex:154`).
- Location: `Aiur.Config.Paths.runtime_state_dir/0` (`src/lib/aiur/config/paths.ex:243`):
  "Runtime state is what the daemon reads back after a restart … It shares the instance-
  and repository-qualified root"; tests override with the `:runtime_state_dir` app env.
- Journal helper: MP-R2-C6 names a `Journal` used by the exporter; at `45a290e3` the
  DecisionStore writes its own ndjson. Reuse whichever shared journal module exists after
  C3-T00; otherwise a 60-line local writer (open append, write, `:file.sync/1`).

## Chosen design

- File: `<runtime_state_dir>/push/outbox.ndjson` (PROPOSED), mode 0600. Records:
  `accepted {job_id, intent_id, device_id, kind, stream, seq, urgency, expires_at,
  dedup_key, accepted_at}` (no summary text — the intent body is kept in a sibling
  `intents/<intent_id>.json`, 0600, deleted at terminal state), `attempt {job_id, at,
  result}`, `terminal {job_id, outcome, at}`.
- `job_id = sha256(intent_id ‖ device_id)` hex → idempotent: `accept/2` of an existing
  pair is a no-op returning the same id.
- Backoff: 1 s, 2 s, 4 s … capped at 5 min, ±20 % jitter; `429` uses `retry_after_s`.
- Restart: replay the journal into the projection; for each non-terminal job call
  `staleness_hook.(job, now)` (MP-N5-C3-T03) → `:send | {:drop, reason} | {:fold, digest}`
  before scheduling. Default hook (until N5): drop if `expires_at < now`.
- Compaction: when terminal records exceed 10 000 or the file > 5 MB, rewrite
  (temp + fsync + rename) keeping only non-terminal jobs and the last 24 h of terminal
  ones (for dedup visibility).

## Implementation steps

1. `outbox.ex` GenServer + `outbox/journal.ex` + `outbox/projection.ex` (PROPOSED).
2. Scheduler: `Process.send_after` to the earliest `next_attempt_at`.
3. Staleness hook behaviour `Aiur.Push.Outbox.StalenessHook` with the default.
4. Tests with an injected clock and temp `runtime_state_dir`.

## Non-happy paths

- Crash after `accepted` written, before send → after restart, exactly one send
  (AC-N5-5 / chunk test).
- Crash during write → torn last line ignored with a warning; job re-accepted by N5's
  ledger replay (N5 records the ledger at accept time; same `job_id` → no duplicate).
- Disk full / unwritable → `accept/2` returns `{:error, :outbox_unavailable}`; C3-T04
  reports `push: degraded`, reason `not_running`; nothing is sent unpersisted.
- Device removed while jobs pending → `purge_device/1` writes terminal `{:dropped,
  :device_gone}` for each.

## Compatibility and rollout

New file under runtime state; no migration. Rollback: delete `push/`; pending
notifications are lost (acceptable — pushes are hints; the app reconciles on open).

## Verification

`src/test/aiur/push/outbox_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"accept is persisted before any send is scheduled"` | journal contains `accepted` when the fake sender is first called | schedule before writing |
| `"kill after persist, before send → exactly one send after restart"` | fake relay counts 1 | skip replay of non-terminal jobs |
| `"accepting the same intent and device twice is a no-op"` | one job | random job ids |
| `"expired job is dropped at restart by the default hook"` | terminal `{:dropped, :expired}` | send regardless |
| `"backoff caps at five minutes and honours retry_after_s"` | schedule times | uncapped |
| `"purge_device terminates that device's jobs only"` | others untouched | purge all |
| `"no summary text in outbox.ndjson"` | file lacks the fixture title | write the intent inline |

Commands (from `src/`): `mise exec -- mix test test/aiur/push/outbox_test.exs`.

## Completion and handoff

- [ ] Persist-before-send proven by the ordering test.
- Docs: none (internal). Dependents: C3-T03, C3-T05, MP-N5-C2-T01, MP-N5-C3-T03.
