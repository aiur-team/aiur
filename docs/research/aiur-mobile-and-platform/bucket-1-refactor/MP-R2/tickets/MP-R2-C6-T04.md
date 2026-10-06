---
ticket_id: MP-R2-C6-T04
feature_id: MP-R2
chunk_id: MP-R2-C6
bucket: 1 (Bucket-2-enabling, RC-09)
title: ExportSource — DurableConsumer source over the export journal (replay by seq, live by append notification, reset/unavailable mapping)
status: ready
blocked_by: [DESIGN-R2 §2, MP-R2-C3-T03, MP-R2-C6-T02, MP-R2-C6-T03]
prior_units: [U3, U8]
prior_boundaries: [BUS #10]
prior_features: [MP-N4 (first consumer: push producer), MP-N5 (notification rules), MP-E1 (optional, E-A5 says not needed in v1)]
prior_findings: []
size_owner: n/a (new file ≤ 120 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C6-T04 — Durable consumer over the export journal

## Identity and outcome

- **Bucket 1 (Bucket-2-enabling, RC-09), MP-R2, chunk C6.** Nothing starts
  a consumer in this ticket; the first user is MP-N4's push producer.
- **User value (later):** a daemon-side consumer (push, notification rules)
  survives restarts with a persisted cursor, gets every exported record at
  least once, and is told — once — when it must re-read state (`reset`) or
  when the feed is unavailable (contract §7.1).
- **Deliverable:** `Aiur.Events.DurableConsumer.ExportSource`, an
  implementation of C3-T03's `DurableConsumer.Source` behaviour over
  `Aiur.Events.Export` (C6-T02/T03), plus an end-to-end test with a real
  exporter and a test handler.
- **Non-goals:** any consumer logic (MP-N4/N5 own handlers and their
  staleness rule, contract §7.2 item 6); wiring `ExecutorListener` to it
  (a separate Bucket-2 ticket if ever wanted, plan C3 note).

## Dependencies and blockers

DESIGN-R2 §2; C3-T03 (behaviours `Source`/`Handler`, state machine,
cursor persistence); C6-T02 (`Export.read/3`, `on_appended` notification on
PubSub `events:export`); C6-T03 (reset rules). Concurrent with C6-T05, C7-*.

## Verified starting point

At `45a290e3` there is no durable consumer. Inputs this ticket binds to are
proposed by sibling tickets:

| Input | Defined in |
| --- | --- |
| `Source` callbacks `subscribe/2`, `replay/3 → {:ok, records} | {:reset, oldest} | {:error, term}`, `position/1` | `MP-R2-C3-T03.md` "Chosen design" |
| `JournalSource` reference adapter (replay only; "C6-T04 supplies the live path") | same |
| `Export.read/3` shapes and `{:export_appended, head_seq, epoch}` on `events:export` | `MP-R2-C6-T02.md` |
| Reset when epoch differs / cursor below oldest / beyond head | `MP-R2-C6-T03.md` |
| Precedent: subscribe first, replay from cursor, then live, dedupe | `src/lib/aiur/executor_listener.ex:44-75,133-178` |

PROPOSED: `src/lib/aiur/events/durable_consumer/export_source.ex`,
`src/test/aiur/events/durable_consumer/export_source_test.exs`.

## Chosen design

- **Cursor = `{epoch, seq}`.** C3-T03's cursor is an integer; the epoch is
  kept by the source in the consumer's source opts state: `ExportSource`
  stores the epoch alongside the cursor file
  (`<cursor_path>.epoch`, written with `JsonStore.write!/2`) and passes it to
  `Reader.read/4`; an epoch mismatch returns `{:reset, oldest}` → the
  consumer calls `handle_reset/2` and persists `oldest - 1` plus the new epoch.
- **`replay/3`** → `Export.read(after, limit, ["#"])`:
  `{:ok, %{records: r}}` → `{:ok, r}`; `{:reset, %{oldest_seq: o}}` →
  `{:reset, o}`; `{:error, :events_unavailable}` → `{:error, :events_unavailable}`.
- **`subscribe/2`** (C3-T03: "live: send consumer `{:durable_record, record}`")
  → starts a relay process linked to the consumer, which subscribes to PubSub
  `events:export` and tracks the last seq it forwarded; on `{:export_appended, head, epoch}` it reads
  `Export.read(cursor, 500, ["#"])` and sends each record as
  `{:durable_record, record}`. The notification is an invalidation, never
  the data (contract R-2), so a missed notification only delays delivery
  until the next one or the C3-T03 retry timer; correctness comes from
  `seq` density (C3-T03 re-enters catch-up on a gap).
- **`position/1`** = `record["seq"]`.
- **Gap records** are delivered to the handler like events (type `gap`);
  handlers must treat them as "re-read snapshots for scope" (contract §4.3).
- PubSub use here is allowed: `ExportSource` is a consumer adapter, not a
  bus-core member; record it in C2-T11's manifest under the event-bus
  component's optional adapters, or exclude it from the C1-T06 member list
  with a one-line reason.

## Implementation steps

1. Implement `ExportSource` per above.
2. Persist/restore epoch next to the cursor.
3. End-to-end test with temp runtime dir, real `Exporter`, test handler.

## Non-happy paths

| Case | Behaviour |
| --- | --- |
| Export disabled or unavailable | `{:error, :events_unavailable}` → consumer `:unavailable`, one `handle_unavailable/2` per entry, retry (C3-T03) |
| Consumer down for longer than retention | `reset` once; handler re-reads snapshots; no backlog burst (MP-N5 rule is in the handler) |
| Journal re-created (new epoch) | `reset` once |
| Daemon restart | exporter writes `gap`; consumer resumes from persisted cursor and receives the `gap` |
| Handler crash after side effect, before cursor write | redelivery (at-least-once); handler dedupes on `(instance, id)` |
| Notification storm | each notification triggers one bounded read (≤ 500); reads are caller-process file reads |

## Compatibility and rollout

No process is started by this ticket. Rollback: delete the module.

## Verification

`export_source_test.exs`:

1. `"replays from the persisted cursor then follows live appends"` — exporter
   with 3 events, consumer cursor 1 → handler sees seq 2, 3, then a 4th
   published event; cursor file = 4.
2. `"restart resumes without loss or duplicate beyond at-least-once"` — stop
   consumer after seq 2 handled, publish 2 more, start → handler sees 3, 4
   (and possibly 2 again only if killed between handle and write — inject
   that case separately and assert redelivery of exactly that seq).
3. `"epoch change yields exactly one reset"` — change instance (C6-T03 rule)
   → one `handle_reset/2`, cursor = new oldest - 1. **Fails** if the epoch
   file is ignored (mutation: do not pass epoch to the reader).
4. `"unavailable feed calls handle_unavailable once per entry"`.
5. `"a missed live notification is recovered by seq density"` — drop one
   `events:export` message; next append delivers both records in order.
6. `"gap records reach the handler"`.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/durable_consumer/export_source_test.exs \
  test/aiur/events/durable_consumer_test.exs test/aiur/events/export/
```

Mutation checks: ignore epoch → test 3 fails; skip `gap` records in
`replay/3` → test 6 fails; restore → pass.

## Completion and handoff

- [ ] Tests 1–6 added and mutation-checked.
- [ ] Docs: none (internal primitive; contract §7.1 already describes it).
- Dependents: MP-N4-C3 (push producer), MP-N5-C2 (policy engine cursor),
  optionally MP-E1.
