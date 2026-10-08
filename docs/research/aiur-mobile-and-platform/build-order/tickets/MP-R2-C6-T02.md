---
ticket_id: MP-R2-C6-T02
feature_id: MP-R2
chunk_id: MP-R2-C6
bucket: 1 (Bucket-2-enabling, RC-09)
title: Export journal writer — single exporter process, dense seq, gap on start, corrupt tail → unavailable + one attention, end-of-tree placement
status: ready
blocked_by: [DESIGN-R2 §2 (S4 reset rule), MP-R2-C6-T01, MP-R2-C5-T02, MP-R2-C5-T04, MP-R2-C3-T01, MP-R2-C2-T07, MP-R2-C2-T08]
prior_units: [U3, U8]
prior_boundaries: [BUS #10, APP_BOOT, K #1]
prior_features: [MP-R1 (identity, signal port), MP-N4/MP-N5 (first consumers)]
prior_findings: []
size_owner: APP_BOOT (aiur.ex 610 at base; this ticket adds ≤ 3 lines — offset or justify per the U0 size gate at start, RC-23); new files ≤ 300 lines each
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C6-T02 — Exporter process and export journal

## Identity and outcome

- **Bucket 1 (Bucket-2-enabling, RC-09), MP-R2, chunk C6.** With
  `events.export.enabled: false` (default) nothing in this ticket starts,
  writes or binds (plan acceptance AC6). Scheduled just before MP-N4/N5.
- **User value (later):** the phone, push relay and notification rules can
  catch up on what happened while they were disconnected, with an honest
  `gap`/`reset` instead of silent loss (contract §7.2).
- **Deliverable:** `Aiur.Events.Export.Exporter` — one GenServer that
  subscribes to the catalog's exported patterns, serializes each event with
  `Envelope.to_external/2`, assigns a dense `seq`, and appends to a
  segmented journal under the runtime state dir; plus a read-only
  `Aiur.Events.Export.Reader` used by C6-T04 and C7.
- **Non-goals:** retention trim and epoch rules (C6-T03), durable consumer
  (C6-T04), mailbox alarm (C6-T05), HTTP/socket (C7).

## Dependencies and blockers

- DESIGN-R2 §2 (feed exists; S4 reset semantics).
- Same-feature predecessors: C6-T01 (keys), C5-T02 (envelope), C5-T04
  (instance id), C3-T01 (`Aiur.Events.Journal`), C2-T07 (`:floor_files`),
  C2-T08 (facade `subscribe/1`).
- Concurrent with C6-T03 (agree the segment/meta layout below first), C6-T05.

## Verified starting point (45a290e3)

| Fact | Evidence |
| --- | --- |
| Root supervisor is `:rest_for_one` | `src/lib/aiur.ex:116-119` |
| Child order: `IdGenerator`, `Exchange`, … `Publisher` | `aiur.ex:358-374` |
| Executor recording children placed late "after the Exchange and the Publisher they subscribe to" | `aiur.ex:454-463,503` |
| `AllowedContributors` placed last in the always-on list so its restart cannot cascade into dashboard/Principal/opencode | `aiur.ex:476-480` |
| `cli_children` (Tmux, PaneManager, AgentList…) are appended **after** that list | `aiur.ex:260-272,484` |
| `SupervisionHealth` gets the full child list | `aiur.ex:487-489` |
| `DecisionLog.append/2` writes one line and fsyncs per call; `replay/3` truncates a torn tail unless `repair_torn_tail: false`; supports `max_file_bytes`, `max_record_bytes` | `src/lib/aiur/decision_log.ex:126-145,150-194,196-207` |
| Corrupt-journal precedent: log + one `needs_attention` alert, replay stopped | `src/lib/aiur/executor_events.ex:416-440` |
| Runtime state dir resolver | `src/lib/aiur/config/paths.ex:243` (`runtime_state_dir/0`, `{:ok, dir} | {:error, reason}` as used at `events/id_generator.ex:273-285`) |
| Cold-boot id floor scans `"id": <int>` in floor files | `events/id_generator.ex:350-357`; `:floor_files` option from C2-T07 |

PROPOSED files: `src/lib/aiur/events/export/exporter.ex`,
`src/lib/aiur/events/export/reader.ex`,
`src/lib/aiur/events/export/layout.ex` (paths + meta read/write),
`src/test/aiur/events/export/exporter_test.exs`.

## Chosen design

**Placement (decision; overrides contract §8 "before producers start").**
Appended **after `cli_children`**, as the very last child:

```elixir
|> Kernel.++(cli_children)
|> Kernel.++(export_children(export_enabled?))   # [] when disabled
```

Reason: under `:rest_for_one`, an exporter crash restarts every later
sibling. Placed right after the Exchange it would restart the Publisher,
DecisionStore and Orchestrator; placed before `cli_children` it would
restart the TUI panes. As the last child it restarts nothing, while an
Exchange crash still restarts it (it is after the Exchange) and it re-binds.
It therefore binds after producers start; everything published before it
binds is covered by the start `gap` (contract D-2: loss surfaces as `gap`,
never silently).

**Files** (`<runtime_state_dir>/events/export/`, dir `0700`, files `0600`):

- `seg.<first_seq>.ndjson` — append-only segments; roll at 8 MiB
  (`max_file_bytes` for reads) so readers never load an unbounded file.
- `export.meta.json` — `{"v":1,"epoch":"<16 random bytes base32>","instance":"…","oldest_seq":N,"head_seq":M}`
  written with `JsonStore.write!/2` (atomic rename) after each append batch.

**Records** (one JSON object per line):

```json
{"type":"event","seq":18234, …envelope v1 fields…}
{"type":"gap","seq":18235,"scope":"*","reason":"exporter_start","from":"2026-10-06T15:02:13Z","to":"2026-10-06T15:09:40Z"}
```

`from` = `observed_at` of the last retained record (or `null`), `to` = now.

**Process states:**

| State | Entered when | Behaviour |
| --- | --- | --- |
| `:starting` | `init/1` | `{:continue, :boot}` |
| `:live` | boot ok | handle `{:event, e}`: `Envelope.to_external/2` → `:skip` ignored; else `seq = head + 1`, `Journal.append/2`, update head |
| `:unavailable` | instance id unavailable (C5-T04), runtime dir unresolvable, corrupt interior line, append error | stays alive, **does not crash**; counts dropped events; `status/0` reports `{:unavailable, reason}`; reporter called **once per boot** |

**Boot sequence:** (1) `InstanceId.current/0` — error → `:unavailable`
`identity_unavailable`, no subscribe. (2) `Journal.prepare/2`, read meta,
replay the newest segment with `repair_torn_tail: true` (only the writer
repairs) to recover `head_seq`; meta/segment disagreement → trust the
segment (meta is a cache). Corrupt interior line → `:unavailable`
`journal_corrupt`. (3) `Aiur.Events.subscribe/1` each `Catalog.exported/0`
pattern. (4) append the `gap` record. Order 3-before-4 means no event can
fall between the gap and the first live record.

**Public read interface `Aiur.Events.Export`** (the module C6-T04 and C7
call; agreed with the C7 ticket writer):

```elixir
@spec enabled?() :: boolean()
@spec status() :: %{state: :available | :unavailable | :disabled, reason: atom() | nil,
                    instance: String.t() | nil, epoch: String.t() | nil,
                    oldest_seq: non_neg_integer() | nil, head_seq: non_neg_integer() | nil}
@spec read(after_seq :: non_neg_integer(), limit :: 1..500, topic_patterns :: [String.t()]) ::
        {:ok, %{instance: String.t(), epoch: String.t(), head_seq: non_neg_integer(),
                oldest_seq: non_neg_integer(), records: [map()]}}
        | {:reset, %{oldest_seq: non_neg_integer(), head_seq: non_neg_integer(), epoch: String.t()}}
        | {:error, :events_unavailable}
```

- `status/0` and `enabled?/0` never call the exporter: the exporter writes
  its status map to `:persistent_term` key `{Aiur.Events.Export, :status}`
  on every state change and after each append batch (one `put` per batch;
  `head_seq` changes are batched so `persistent_term` global GC cost stays
  bounded — if the C6-T05 census shows > 10 appends/s sustained, switch the
  status to a `:public` ETS table owned by the exporter; the API is
  unchanged). A missing key means `:disabled` (or not yet booted).
- **Read signature (one for C6-T02/T03/T04 and C7, T-7):**
  `Aiur.Events.Export.read(after_seq, limit, patterns, opts \\ [])`, so
  `read/3` and `read/4` are the same public function; `opts[:epoch]` is the
  caller's last epoch (reset rules in C6-T03). `Aiur.Events.Export.Reader` is
  private to the component and is never called by other tickets.
- `read/4` runs in the caller's process (`Reader`): list segments, pick
  those covering `after_seq + 1`, read with `Journal.replay(path, validator,
  repair_torn_tail: false, max_file_bytes: 8 MiB)` — readers never truncate
  (a concurrent append can look like a torn tail). Reset rules are C6-T03's.
  Unavailable or disabled → `{:error, :events_unavailable}`.
- Status `reason` atoms (used verbatim as capability reasons by C7-T03, per
  AGENTS.md "collapsed cause names the collapse"): `:identity_unavailable`,
  `:runtime_dir_unavailable`, `:journal_corrupt`, `:append_failed`.

**Append notification (live channel trigger, C7-T02):** after each
successful append batch the exporter calls an injected
`on_appended.(head_seq, epoch)`. `aiur.ex` supplies
`fn head, epoch -> Phoenix.PubSub.broadcast(Aiur.PubSub, "events:export", {:export_appended, head, epoch}) end`,
so the bus core keeps no `Phoenix.PubSub` edge (C2-T05) while the web
channel gets an invalidation (contract rule R-2: PubSub carries "re-read",
the records are read from the journal).

**Injected boot dependencies** (no bus → signal/identity compile edge):
the child spec built in `aiur.ex` passes
`on_unavailable: fn reason -> Signal.alert("system.events.export_unavailable", reason: inspect(reason), needs_attention: true, severity: "warning") end`,
so the exporter never names the signal port either. C6 ships in wave 5, after the
signal port exists (plan-refresh row PR-07), so the callback uses `Signal.alert/2`,
not `Aiur.Alerts.emit_system` (X-48). Topic is in-grammar (`system.`) and gets a C5 catalog
entry (ledgered, not exported).

**Id floor:** `Aiur.IdFloorSources.floor_files/0` (C2-T07) adds the newest
export segment path when it exists, so a lost `event-id.json` cannot
re-issue ids already exported.

**Invariants:** `seq` is dense and strictly +1 per appended record; one
writer; a record is visible to readers only after `append/2` returned
(fsynced); disabled ⇒ no process, no directory.

## Implementation steps

1. `Layout` (paths, meta read/write, segment listing).
2. `Exporter` with the state table, `:persistent_term` status, `on_appended`.
3. `Aiur.Events.Export` facade (`enabled?/0`, `status/0`, `read/4` with `opts \\ []`) and
   `Reader` (stateless, caller's process).
4. `aiur.ex`: `export_children/1` and the append after `cli_children`;
   `export_enabled?` read once via `Aiur.Config.events_export_enabled?/0`.
5. `IdFloorSources.floor_files/0`: include the newest segment.
6. C5 catalog entry for `system.events.export_unavailable`.
7. Add the new bus files to the C1-T06 member list.

## Non-happy paths

| Case | Behaviour |
| --- | --- |
| Disabled | no child, no dir, no subscription (AC6) |
| Identity unavailable | `:unavailable/identity_unavailable`, one attention; API (C7) answers `events_unavailable` |
| Interior corruption at boot | `:unavailable/journal_corrupt`, one attention; never truncates retained lines; operator recovery = move the directory away and restart → new epoch (C6-T03) → clients `reset` |
| Torn last line at boot | repaired by the writer (DecisionLog semantics), then `gap` |
| `append/2` error at runtime (disk full) | `:unavailable/append_failed`, one attention; later events counted as dropped; on restart → `gap` covers them |
| Exchange crash | exporter restarted after it (rest_for_one) → new subscription → new `gap` |
| Exporter crash | restarts alone (last child); boot path writes a `gap` |
| Duplicate delivery | not possible from one subscription; clients still dedupe on `(instance, id)` |
| Event published before subscription | covered by `gap` (D-2) |
| Throughput | fsync per record (DecisionLog); acceptable only if C6-T05's census shows the rate is low; C6-T05 decides batching if not |

## Compatibility and rollout

Off by default. Enabling creates the directory; disabling leaves it in place
(not deleted) and stops writing; re-enabling continues with a `gap`.
Rollback: revert; the directory is inert data.

## Verification

`exporter_test.exs` (temp `runtime_state_dir` via `Application.put_env`,
fake catalog with one exported pattern `ticket.*.pr.merged`, fake
`InstanceId` provider, injected `on_unavailable` sending to the test pid):

1. `"start writes exactly one gap, then events with dense seq"` — start,
   publish two exported events and one non-exported → journal has
   `gap(seq 1)`, `event(seq 2)`, `event(seq 3)`; non-exported absent.
2. `"restart writes one gap and continues seq"` — stop, start → `gap(seq 4)`.
   **Fails** if the boot gap is removed (mutation).
3. `"no instance id: no subscription, no file, one unavailable report"`.
4. `"interior corruption: unavailable, retained lines untouched, one report"` —
   write a bad middle line; start; file bytes unchanged; one
   `{:unavailable, :journal_corrupt}` message; a second boot in the same test
   reports again (per boot), not per event.
5. `"readers never truncate a torn tail"` — append half a line manually,
   call `Export.read/4` → file size unchanged. **Fails** if the reader passes
   `repair_torn_tail: true`.
6. `"exporter is the last child"` — in `test/aiur/application_test.exs`
   (describe "child_specs/1 run-shape gating"), with export enabled the last
   spec is the exporter; with it disabled no exporter spec exists. **Fails**
   if moved before `cli_children` or the Publisher.
7. `"export segment is an id floor file"` — `IdFloorSources.floor_files/0`
   includes the newest segment when present.
8. `"status is readable without the exporter process"` — after boot, suspend
   the exporter with `:sys.suspend/1`; `Aiur.Events.Export.status/0` still
   returns `%{state: :available, head_seq: n}` within 10 ms. **Fails** if
   `status/0` is a `GenServer.call`.
9. `"each append batch notifies once with head_seq and epoch"` — injected
   `on_appended` sends to the test pid; two events → `{:appended, 2, epoch}`
   then `{:appended, 3, epoch}`.
10. `"corrupt journal reports reason :journal_corrupt"` — `status().reason`.
11. Existing `application_test.exs`, `id_generator_test.exs` green.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/export/exporter_test.exs test/aiur/application_test.exs \
  test/aiur/events/id_generator_test.exs test/aiur/events/bus_boundary_test.exs
env -C <worktree>/src mise exec -- make fmt-check lint
```

Mutation checks (clean worktree each): drop the boot `gap` → test 2 fails;
reader with `repair_torn_tail: true` → test 5 fails; move the child before
`cli_children` → test 6 fails.

Manual (with C7-T04 or by reading the file): `aiurdev --test` with
`events.export.enabled: true` in the dogfood `.aiur/config`; confirm
`<runtime_state_dir>/events/export/seg.1.ndjson` begins with one `gap`
and gains an `event` line when a test ticket's PR opens; restart and see a
second `gap`.

## Completion and handoff

- [ ] Disabled run: byte-identical `aiur status` and no new file/process (AC6).
- [ ] Tests 1–7 added and mutation-checked.
- [ ] Docs: `website/docs-app/concepts/message-bus.md` gets a short "Export
      journal" paragraph (location, gap/reset meaning) — C4-T05 owns the page;
      add the paragraph here because this ticket creates the behaviour.
- Dependents: C6-T03, C6-T04, C6-T05, C7-T01..T04.
