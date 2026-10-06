---
ticket_id: MP-E4-C1-T02
feature_id: MP-E4
chunk_id: MP-E4-C1
bucket: 2-platform
title: "Journal writer process: positions, sessions, dedup, gaps, broadcast, restart recovery"
status: blocked
blocked_by: [DESIGN-E4, MP-E4-C1-T01]
prior_units: [U4, U6]
prior_boundaries: [PRJ, RUN]
prior_features: []
prior_findings: [contract conversations-transcripts-anchors §4-§7, §11]
size_owner: n/a (new modules; one-line child additions in src/lib/aiur.ex)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C1-T02 — Journal writer process

## Identity and outcome

- Bucket 2 · MP-E4 · C1 · T02.
- **User value:** every transcript record gets a durable position exactly
  once, survives daemon restarts, and shows honest gaps.
- **Deliverable:** `Aiur.Conversation.Journal` (one writer per conversation),
  its Registry and DynamicSupervisor, and the non-blocking facade
  `Aiur.Conversation.Ingest` that every producer (T03, MP-E3, C8 importer)
  calls.
- **Non-goals:** wiring producers (T03); reading pages (C2-T01).

## Dependencies and blockers

- DESIGN-E4; MP-E4-C1-T01 (records and store).
- Consumed by: MP-E4-C1-T03, MP-E4-C8-T01, MP-E3-C2-T01, MP-E3-C3-T02.
- Concurrent with: MP-E4-C2-T01 (it reads files the writer produces; agree on
  T01's store API first).

## Verified starting point

- Per-key process pattern: `Aiur.IssueLog.Registry` + `Aiur.IssueLog.Supervisor`
  started in `src/lib/aiur.ex:303,307`; writers looked up with
  `Registry.lookup/2` and started with `DynamicSupervisor.start_child/2`
  (`issue_log.ex:582-628`).
- PubSub server name: `Aiur.PubSub` (`aiur.ex:302`).
- BEAM-run identity: `Aiur.Boot.run_id/0` (`boot.ex:85-98`), "opaque identity
  for this BEAM-lifetime run".
- `LiveConversation` already models restart honesty with `:restart_unknown`
  (`live_conversation.ex:680-687`).
- System alerts: `Aiur.Alerts.emit_system(name, message:, needs_attention:)`
  with a `.resolved` companion (`alerts.ex:103-106`; usage
  `supervision_health.ex:162`).

## Chosen design

PROPOSED files: `src/lib/aiur/conversation/journal.ex`,
`src/lib/aiur/conversation/ingest.ex`; edit `src/lib/aiur.ex` to add
`{Registry, keys: :unique, name: Aiur.Conversation.Registry}` and
`{DynamicSupervisor, strategy: :one_for_one, name: Aiur.Conversation.JournalSupervisor}`
next to the IssueLog pair (after `Aiur.PubSub.Boot`).

**Facade (`Ingest`), all return `:ok`, never raise, never block on disk:**

```elixir
@spec append(Ref.t(), source(), [map()]) :: :ok      # transcript events
@spec end_session(Ref.t(), String.t() | nil, end_reason()) :: :ok
@spec gap(Ref.t(), gap_reason(), DateTime.t(), DateTime.t()) :: :ok
@type source :: %{harness: String.t(), role: :worker | :executor,
                  provider_session_id: String.t() | nil, aiur_attempt_id: String.t() | nil,
                  transcript_source: %{kind: atom(), locator_hash: String.t() | nil},
                  start_reason: atom()}
```

`append/3` maps events with `Entry.from_transcript_event/2` in the caller
(cheap, pure), then `GenServer.cast`s the inputs. Lookup: `Registry.lookup`;
on miss, `DynamicSupervisor.start_child` (the child's `init/1` only registers;
disk work runs in `handle_continue/2`, so `start_child` returns at once).
If the writer's `message_queue_len` exceeds 5,000 the facade drops the batch,
increments a counter in `:persistent_term`, and casts `{:dropped, from, to}`
so a `gap` is written later. Everything is wrapped in `try … catch` (the
message path must never fail, as `MessageHandler.safe_live_conversation/4`
does today, `message_handler.ex:485-503`).

**Writer state:** `dir`, `segment_state`, `next_pos`, `open_session`
(`%Session{}` or nil), `dedup` (MapSet of keys for the open session, capped at
50,000, oldest evicted by a queue), `buffer`, `timer`, `failed_since`,
`dropped_span`.

**Flush:** when the buffer reaches 50 inputs or 200 ms after the first input.
For each input in order: resolve the session (below), drop if `dedup_key` is in
`dedup`, else assign `pos = next_pos`, `observed_at = DateTime.utc_now()`.
Then one `Store.append_entries/3` (one fsync). Only after `:ok`:
broadcast `{:entries_appended, conversation_id, entries}` and, for each
session change, `{:session_changed, conversation_id, session}` on
`"conversation:" <> conversation_id`.

**Session rules (contract §4):**

| Situation | Action |
| --- | --- |
| No open session | open one (`session_seq + 1`, `start_reason` from source, `aiur_run_id: Boot.run_id()`). |
| `{harness, provider_session_id}` equal to the open session | continue. |
| Different key | write an end line for the open session (`end_reason: "superseded"`), open a new one. |
| `end_session/3` | end line with the given reason; next append opens a new session. |
| Writer `handle_continue` finds an open session whose `aiur_run_id` ≠ current | end it `daemon_restart_unknown`; the next append opens a session with `start_reason: "resume"`. Same run id (the writer itself crashed) → continue it, and rebuild `dedup` from the session's entries. |

**Gaps:** on a failed flush keep the inputs' time span in `failed_since` and
retry with exponential backoff (1 s → 30 s) at most 5 times, then drop the
buffer and keep the span. On the first later successful write, append one
`gap` entry (`reason: "source_unreadable"`, `from`, `to`) before the new
entries. The first failure in an outage emits
`system.conversation.journal.degraded` (`needs_attention: true`, message names
the conversation and the error class, never a body); recovery emits
`….resolved`.

**Idle stop:** a writer with no input for 15 minutes flushes and stops
(`:normal`); it restarts on the next input. This bounds processes to active
conversations.

## Implementation steps

1. `Journal` GenServer: `start_link/1` via-tuple name in
   `Aiur.Conversation.Registry`; `init/1` → `{:ok, state, {:continue, :load}}`;
   `:load` = `Store.prepare/1`, `Store.read_head/1` (or rebuild), read
   `sessions.jsonl` tail, restart rule, dedup rebuild.
2. `handle_cast({:append, source, inputs})`, `{:end_session, …}`, `{:gap, …}`,
   `{:dropped, …}`; `handle_info(:flush)`; `handle_info(:idle)`.
3. `Ingest` facade with the queue-length guard and the never-raise wrapper.
4. Children in `src/lib/aiur.ex`.
5. A test helper `Aiur.Conversation.TestSupport.flush(ref)` (synchronous
   `GenServer.call(:flush)`) so tests are deterministic.

## Non-happy paths

- **Concurrency:** one writer per conversation; `pos` assigned only inside it.
  Two producers for the same conversation (worker closure and display tailer)
  are serialized by the mailbox; ordering across them is arrival order.
- **Corrupt segment** (T01 returns `{:error, {:corrupt, …}}`): the writer
  enters `:read_only`, refuses appends (counted, gap span kept), emits the
  degraded alert once. Never truncates interior data.
- **Clock jump backwards:** `observed_at` comes from `DateTime.utc_now/0` and
  is informative; order is `pos`, never time.
- **Very large backfill** (Remote-Control `from: :start` replay of a long
  session): inputs arrive in bursts of thousands; batching bounds fsyncs to
  one per 50 entries, and dedup drops already-stored records.
- **Writer crash mid-flush:** the batch was not acknowledged; the torn tail is
  truncated at reload; the producer's records are lost except where the
  source is a file read from a stored offset (Executor, MP-E3) — documented
  as a possible missing span, surfaced by T02's gap only when detected.

## Compatibility and rollout

- Two supervision children added; idle cost is a Registry and an empty
  DynamicSupervisor. No config key. Rollback: remove the children (producers
  from T03 must be reverted first or they log a no-op error).

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur/conversation/journal_test.exs test/aiur/conversation/ingest_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "positions are dense and increasing across batches" | 1..N with no gap or repeat | `next_pos` assignment |
| "duplicate input in a later batch is dropped" | one entry | the `dedup` check |
| "dedup survives a writer crash in the same run" (kill writer, re-append) | still one entry | dedup rebuild in `:load` |
| "different provider session opens a new session; old one ends superseded" | two session lines, end reason `superseded` | session-key comparison |
| "new run id ends an open session daemon_restart_unknown" (stub `Boot.run_id`) | end line + next `start_reason: resume` | the run-id rule |
| "append returns while the store is blocked" (store module stubbed to sleep 5 s) | `Ingest.append/3` returns in < 50 ms | the cast / `handle_continue` split |
| "failed write then success writes one source_unreadable gap" (store stub fails twice) | gap entry with the span, then the entries; one degraded alert, one resolved | `failed_since` handling |
| "broadcast only after fsync" | no PubSub message while the store stub is blocked | broadcast placement |
| "queue over 5,000 drops and later writes a gap" | dropped counter > 0, gap entry | the queue-length guard |
| "corrupt segment → read_only, no write" | append refused, file bytes unchanged | `:read_only` mode |

Tests set `:conversation_state_dir` to a temp dir and inject the store and
clock through `Application` env, as `EventPublicationLog` accepts `:path`
(`event_publication_log.ex:49-52`).

## Completion and handoff

- [ ] Writer, facade, children merged; `make ci` green on the head SHA.
- [ ] PR body: each test with the hunk it fails without.
- Dependents: MP-E4-C1-T03, MP-E4-C2-T01, MP-E4-C3-T02, MP-E4-C8-T01, MP-E3-C2-T01.
- Docs: none (operator-visible alert name goes into MP-E4-C8-T02's page).
