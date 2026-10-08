---
ticket_id: MP-R2-C3-T03
feature_id: MP-R2
chunk_id: MP-R2-C3
bucket: 1 (refactor; new unwired primitive)
title: Aiur.Events.DurableConsumer — subscribe, replay from a persisted cursor, then live, at-least-once (not wired)
status: ready
blocked_by: [DESIGN-R2 §1, MP-R2-C3-T01]
prior_units: [U3, U8]
prior_boundaries: [BUS #10, EXE #26]
prior_features: []
prior_findings: [events-webhooks-executor-01 (ordering lesson), MP-R2 F2, F5]
size_owner: n/a (new files, each ≤ 200 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C3-T03 — `Aiur.Events.DurableConsumer`

## Identity and outcome

- **Bucket 1, MP-R2, chunk C3.** Adds a primitive; nothing in production
  starts it, so there is no behaviour change. First users are the export
  journal consumer (C6-T04) and the MP-N4 push producer / MP-N5 rules.
- **Value.** One tested implementation of "subscribe first, replay from my
  cursor, then live, dedupe, persist the cursor only after handling", so
  N4/N5 (and optionally MP-E1) do not each re-invent the
  `ExecutorListener` pattern and its bugs (#2039 replay-state loss noted at
  `executor_listener.ex:130-132`; the U3 stall reorder).
- **Deliverable.** `Aiur.Events.DurableConsumer` (GenServer) plus two
  behaviours, `DurableConsumer.Source` and `DurableConsumer.Handler`, and a
  fake-journal test suite.
- **Non-goals.** Not wired to `ExecutorListener` (plan §8, behaviour
  preservation). Whether ExecutorListener should adopt it to close the F5
  wake gap is a separate Bucket 2 ticket (recorded in chunks.md Phase C
  questions), not this one. No export journal (C6).

## Dependencies and blockers

- DESIGN-R2 §1; C3-T01 (`Journal.replay/3` is what a journal-backed source
  calls; the fake source in tests does not need it, but the reference
  `JournalSource` adapter does).
- Concurrent with C2-*, C3-T02, C4-*.

## Verified starting point (45a290e3)

| Pattern reused | Evidence |
| --- | --- |
| ExecutorListener subscribes missing patterns first, then replays from its watermark, then handles live | `src/lib/aiur/executor_listener.ex:44-75` |
| Replay threads state so a watermark advanced during replay survives (#2039) | `executor_listener.ex:130-142` |
| Freshness check `id > watermark`; watermark persisted after successful delivery only | `executor_listener.ex:144-178` |
| Executor watermark is by event **id**, which is not a delivery order (F2), so a late lower id is dropped | `executor_listener.ex:169-178`; `id_generator.ex:83-85`; `exchange.ex:93-108` |
| Durable JSON write helper | `Aiur.JsonStore.write!/2` (used `subscription_store.ex:715-726`) |
| Corrupt journal → stop replay + `needs_attention` alert precedent | `executor_events.ex:416-440` |

PROPOSED: `src/lib/aiur/events/durable_consumer.ex`,
`src/lib/aiur/events/durable_consumer/source.ex`,
`src/lib/aiur/events/durable_consumer/handler.ex`,
`src/test/aiur/events/durable_consumer_test.exs` (the fake source is a
nested module in this test file: `src/test/support/` holds only `.exs`
helpers listed in `test_ignore_filters`, `src/mix.exs:131-134`).

## Chosen design

```elixir
defmodule Aiur.Events.DurableConsumer.Source do
  # cursor = dense, single-writer position (the export journal's seq). NOT an event id.
  @callback subscribe(source_opts :: term(), consumer :: pid()) :: :ok   # live: send consumer {:durable_record, record}
  @callback replay(source_opts :: term(), after_cursor :: non_neg_integer(), limit :: pos_integer()) ::
              {:ok, [record :: map()]} | {:reset, oldest :: non_neg_integer()} | {:error, term()}
  @callback position(record :: map()) :: non_neg_integer()
end

defmodule Aiur.Events.DurableConsumer.Handler do
  @callback handle_record(record :: map(), state :: term()) :: {:ok, term()} | {:error, term()}
  @callback handle_reset(oldest :: non_neg_integer(), state :: term()) :: {:ok, term()}
  @callback handle_unavailable(reason :: term(), state :: term()) :: {:ok, term()}
end
```

`DurableConsumer.start_link(name:, source: {module, opts}, handler: {module, init_state},
cursor_path:, replay_batch: 500, retry_ms: 5_000)`.

State machine:

| State | On entry | Transitions |
| --- | --- | --- |
| `:catching_up` | `source.subscribe/2` **first**, then load cursor (missing file → 0), then replay batches after the cursor | all batches applied → `:live`; `{:reset, oldest}` → call `handle_reset/2`, persist cursor `oldest - 1`, continue; `{:error, r}` → `:unavailable` |
| `:live` | — | `{:durable_record, r}` with `position(r) == cursor + 1` → handle, persist; `<= cursor` → drop (duplicate); `> cursor + 1` (gap: live arrived before replay caught up) → go back to `:catching_up` from the persisted cursor |
| `:unavailable` | `handle_unavailable/2` called **once per entry**; schedule retry after `retry_ms` | retry → `:catching_up` |

Rules:

- **At-least-once.** Persist the cursor (atomic `JsonStore.write!/2`) only
  after `handle_record/2` returns `{:ok, _}`. A crash between handle and
  write redelivers that record after restart; handlers must be idempotent
  (contract §7.1; N4 dedupes on `(instance, id)`).
- **Handler error.** `{:error, reason}` keeps the cursor, logs, and retries
  the same record after `retry_ms`; never skips (no dead-lettering in the
  primitive; a consumer that needs one does it in its handler).
- **Dense cursor only.** Positions must be gap-free per source; the
  moduledoc states this is why the primitive is not used with event ids.
- **Reset** means the source no longer holds the cursor's successor
  (retention, new epoch): consumer state built from events is stale, so
  `handle_reset/2` must re-read snapshots (contract §4.3, §7.2).

A reference adapter `Aiur.Events.DurableConsumer.JournalSource` (≤ 60
lines) implements `replay/3` over `Journal.replay/3` for a journal whose
records carry `"seq"`; `subscribe/2` is a no-op for it (C6-T04 supplies the
live path). It exists so the fake and a real journal run the same suite.

## Implementation steps

1. Behaviours and GenServer as above; no `Aiur.*` references beyond
   `Aiur.Events.*` and `Aiur.JsonStore` (kernel).
2. `JournalSource` adapter.
3. Nested `FakeDurableSource` in the test file: in-memory list in an `Agent`, with
   knobs: `fail_next_replay`, `reset_below`, `push_live/2`.
4. Add the new files to the C1-T06 member list.

## Non-happy paths

| Case | Behaviour |
| --- | --- |
| Live record arrives during replay | Buffered in the mailbox (subscribe happened first); dropped if `<= cursor` after replay, applied if next |
| Live gap (`> cursor + 1`) | Re-enter catch-up from the persisted cursor; never apply out of order |
| Corrupt or unreadable source | `:unavailable`, one `handle_unavailable/2` per entry, retry timer; no cursor movement |
| Cursor file corrupt | Treated as missing → cursor 0 → replay from oldest or `reset` (at-least-once, never skip). Logged warning |
| Cursor ahead of source head (journal re-created) | Source returns `{:reset, oldest}` because the successor does not exist with the same epoch (C6-T03 epoch rule) |
| Consumer crash | Supervisor restarts; restart = `:catching_up` from persisted cursor |
| Back-pressure | Replay in batches of `replay_batch`; live mailbox length is the exporter's concern (C6-T05) |

## Compatibility and rollout

Nothing starts it; no config. Rollback: revert.

## Verification

`src/test/aiur/events/durable_consumer_test.exs`, temp `cursor_path` per
test, `FakeDurableSource`, handler that sends `{:handled, pos}` to the test pid:

1. `"replays records after the persisted cursor, then handles live ones in order"`
   — source holds 1..5, cursor file 2 → handled 3,4,5; push 6 → handled 6;
   cursor file = 6.
2. `"subscribes before replay so a record published during replay is not lost"`
   — fake source pushes 6 from inside its `replay/3` callback → 6 handled once.
   **Fails if subscribe is moved after replay.**
3. `"crash between handle and cursor write redelivers (at-least-once)"` —
   handler kills the consumer after sending `{:handled, 3}`; on restart
   `{:handled, 3}` arrives again. **Fails if the cursor is written before
   `handle_record/2`.**
4. `"duplicate live record is dropped"` — push 4 twice → one `{:handled, 4}`.
5. `"live gap triggers catch-up instead of applying out of order"` — cursor
   3, push 6 while 4,5 exist in the source → handled 4,5,6 in order.
6. `"reset calls handle_reset and resumes from oldest"` — `reset_below: 10`,
   cursor 2 → `{:reset, 10}` → `handle_reset(10, _)` then handled 10..
7. `"unavailable source reports once per outage and retries"` — fail two
   replays, then succeed; exactly one `handle_unavailable` call per
   `:unavailable` entry; records handled after recovery.
8. `"handler error holds the cursor and retries the same record"`.
9. `"JournalSource reads the same records as the fake"` — write 5 lines with
   `"seq"` via `Journal.append/2`; run test 1 against `JournalSource`.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/durable_consumer_test.exs test/aiur/events/bus_boundary_test.exs
env -C <worktree>/src mise exec -- make fmt-check lint
```

No sleeps: use `retry_ms: 0`/injected timer messages and `:sys.get_state/1`
(chunks.md C1 test strategy).

Mutation check (clean worktree): move `subscribe` after replay → test 2
fails; persist cursor before `handle_record` → test 3 fails; replace the
gap branch with "apply anyway" → test 5 fails. Record each command and
`git status --porcelain` in the PR body.

## Completion and handoff

- [ ] Tests 1–9 green; three mutations fail as listed.
- [ ] Nothing in `aiur.ex` starts a DurableConsumer.
- [ ] Docs: none (no user-facing surface; C4-T05 documents the class rules).
- Dependents: C6-T04 (export-journal consumer), MP-N4-C3 (push producer),
  MP-N5-C2 (notification rules cursor), optionally MP-E1 (not needed in v1,
  queue contract E-A5).
