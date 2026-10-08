---
ticket_id: MP-E8-C4-T01
feature_id: MP-E8
chunk_id: MP-E8-C4
bucket: 2-platform
title: Aiur.BuildOrder.History store
status: blocked
blocked_by: [DESIGN-E8]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-07, EC-31]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C4-T01 — `Aiur.BuildOrder.History` store

> Cites code at `origin/main` `58854d4c8` (runtime worktree
> `aiur-worktrees/runtime/src`). Paths marked PROPOSED do not exist yet. If MP-R1
> has moved `build_order/` before this starts, re-resolve the symbols below
> (CR-E8-6 places this store in `build-orders`).

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C4
  (durable history store), ticket T01. Level 0 after DESIGN-E8 (tickets/README.md
  "What may run concurrently").
- **User value.** The home page must show every closed ticket with its start,
  end, epic signals and edges. Today no cache keeps closed tickets:
  ResourceStore expires after 72 h, merges after 100 rows, telemetry after 30
  days (chunks.md C4). This store is the one place that keeps them, and it
  survives a daemon restart.
- **Deliverable.**
  - PROPOSED `src/lib/aiur/build_order/history.ex`: a GenServer that holds an
    event-sourced index of every issue in the configured repository, persists it
    to one versioned file, mirrors rows into ETS for lock-free reads, and
    broadcasts a PubSub change signal.
  - PROPOSED `src/lib/aiur/build_order/history/row.ex`: the row struct, event
    validation, merge rule, and JSON encode and decode.
  - `Aiur.Config.Paths.build_history_state_dir/0` (one new function).
  - One child line in the application tree.
  - One resolver name in the test boot isolation guard.
- **Non-goals.**
  - No feed. Nothing calls `apply/2` in this ticket. The backfill is C4-T02;
    the steady-state feed and boot catch-up are C4-T03.
  - No derivation. Start and end rules are C4-T04. Edges, the children index and
    order violations are C4-T05. Epic resolution is C5-T02. Day paging is C8-T04.
  - No UI, no payload, no config key, no CLI.

## 2. Dependencies and blockers

- **Blocked by DESIGN-E8** only (every MP-E8 ticket is, tickets/README.md
  rules). The store has no visible element. The chunk's only design item is
  S-5 ("start unknown" Gantt card), which C4-T04 and C9-T09 render. This ticket
  only guarantees that "start unknown" is stored as an explicit value.
- **Predecessors:** none.
- **Successors that consume this interface:** C4-T02 (writes pages and the
  backfill checkpoint, calls `mark_complete/1`), C4-T03 (writes steady-state
  events and the `:closed_since` checkpoint, adds handlers inside the store),
  C4-T04 (writes `in_progress_at`/`dispatched_at` and the derived
  `start`/`end` fields, adds `note_start/3`), C4-T05 (reads `blocked_by`, `parent`), C6-T05 (reads
  rows), C7-T01 and C7-T04 (read open rows), C8-T04 (subscribes, reads
  `rows/2`, `snapshot/1`).
- **Unresolved research:** none here. Names and checkpoint ownership are
  settled (reconciliation 2026-10-08); §11 lists them.
- **Contracts:** none shared. CR-E8-6 (component map placement) is filed by
  C3-T01, not here.
- **Concurrent with:** C1-T01, C2-T03, C5-T01 (different files).

## 3. Verified starting point (`58854d4c8`)

| What | Where | Use here |
| --- | --- | --- |
| Atomic JSON write | `lib/aiur/json_store.ex:32-37` `write!/2` (raises; no file mode); `:44-59` `read/2` | Not called directly (decision 2) |
| Atomic write with fsync and mode | `lib/aiur/fs.ex:18-19` `Fs.atomic_write/3`; `:86-87` `sync_filesystem/0` | The write path, `mode: 0o600`, as `ProgressRetention` does |
| Corrupt-file quarantine | `lib/aiur/fs.ex:105-119` `Fs.quarantine/1` (renames to `<path>.corrupt-<ms>`) | Keeps evidence of a corrupt file |
| Durable store pattern | `lib/aiur/progress_retention.ex`: `init/1` `:109-145` (state dir, load, ETS mirror, degraded health), debounce `:213-217` (`@debounce_ms 2_000`), `do_flush` `:222-233`, `persist_checkpoint` `:244-249`, `load_checkpoint` `:309-329` (lstat, size cap, symlink rejection), `quarantine_corrupt` `:352-356`, `ensure_regular_file` `:497`, `resolve_state_dir` `:507-508`, `mirror_table` `:510-514` | Copied shape. Two differences: this store never answers `%{}` when unavailable (`progress_retention.ex:76-79` does), and it traps exits so `terminate/2` runs on shutdown (`progress_retention.ex` does not set `trap_exit`) |
| State dir resolution | `lib/aiur/config/paths.ex:60-66` `decision_state_dir/0` (instance- and project-scoped, fails closed); `:99-110` `progress_retention_state_dir/0` (app-env override, then a leaf under the decision dir) | `build_history_state_dir/0` is a copy of `:99-110` with leaf `build-history` |
| Health struct | `lib/aiur/build_order/lifecycle.ex:1-62` `Aiur.BuildOrder.ProviderHealth` (`state` `:healthy/:stale/:unavailable/:structurally_invalid`, `complete?`, `observed_at`, `last_success_at`, `failure`, `generation`); `usable?/1` `:46-51` | Reused as the store's health, so C8-T04 handles it like every other Build Order source |
| Lifecycle facts | `lib/aiur/build_order/lifecycle.ex:65-104` `Aiur.BuildOrder.Lifecycle.from_github/2` (`:open/:closed/:unknown`; reasons `:completed/:not_planned/:duplicate/:reopened/:none/:unknown`), `valid?/1` `:79-86` | Row lifecycle field |
| PubSub signal pattern | `lib/aiur/build_order/pack_status.ex:51` `@topic`, `:79` `subscribe/0`, `:226-232` `broadcast_changed/1` (guards on `Process.whereis(Aiur.PubSub)`) | Same shape |
| Application tree | `lib/aiur.ex:447` `Aiur.ProgressRetention`; `:452` `{Aiur.BuildOrder.TicketHistoryProvider, runtime_config?: true}` | New child goes just before `:452` |
| Test support | `test/support/test_support.exs:167` `tmp_root!/1`; `test/aiur/progress_retention_test.exs:7-9` (store started per test with `state_dir`) | Test setup pattern |
| Test boot isolation guard | `test/support/test_boot_guard.exs:35-48` `derived_paths` resolver list (`:progress_retention_state_dir` at `:39`) asserts every derived state dir is outside the real `~/.aiur` | The new resolver is added to this list |
| Repository ref shape | `lib/aiur/build_order/bounded.ex:119-130` `Bounded.same_repository?/2` matches `%{owner:, repository:}` | `parent` and `blocked_by` refs use `%{owner, repository, number}` so C4-T05 can call it directly |
| Repository identity | `lib/aiur/tracker.ex:153-159` `Tracker.project_identity/0` (calls `Config.settings!/0`, can raise); `lib/aiur/github/tracker.ex:14` returns `Config.repo()` (`"owner/name"`); `lib/aiur/memory/tracker.ex:11` returns `"memory"`; `lib/aiur/config/paths.ex:311-317` private `safe_project_identity/0` rescues | Default `repository`, rescued the same way |

Current behaviour: no module named `Aiur.BuildOrder.History` exists, and no
store keeps closed issues past 72 h.

Design data shape this store must be able to feed (no pixels, but the fields
must exist): the design's history ticket record at `J:190-191` (`id`, `num`,
`title`, `type`, `epic`, `feature`, `also`, `cx`, `pts`, `start`, `end`,
`status` done or failed, `agent {model, effort}`, `created`, `deps`), the
`children` index at `J:288`, the history card logo at `J:828` (drawn for any
ticket with `t.agent` at detail level `"full"`, history included), the model
filter at `J:338` (`"none"` when a ticket has no agent; applies
to history rows), and the history status text at `J:1152-1153`.

## 4. Chosen design

### 4.1 Row (PROPOSED `Aiur.BuildOrder.History.Row`)

Every optional fact has three forms: a value, `:none` (known to be absent) or
`:unknown` (never observed). `nil` is not a valid stored value. This is what
keeps "unknown" from rendering as 0 or as "not merged" downstream (EC-08 is
owned by the renderers; this ticket makes it possible).

The field set is the union of what the four C4 neighbours write (C4-T02
"BackfillQuery.rows", C4-T03 "Contract with C4-T01", C4-T04 "Signals" and
"Derived fields"). Names follow C4-T04 for the timing signals, because C4-T04
owns them. Storing all of them now means C4-T04 does not have to bump the file
version (C4-T04 step 2 asks for a bump only "if C4-T01 shipped without the
signal fields").

A **ref** is `%{owner: String.t(), repository: String.t(), number: pos_integer()}`,
the shape `Bounded.same_repository?/2` (`bounded.ex:119-130`) matches. A
blocker in another repository keeps its owner and repository (C4-T02 table,
C4-T05 rule 4).

| Field | Type | Default | Merge class (§4.2) | Fed by |
| --- | --- | --- | --- | --- |
| `number` | `pos_integer` (key) | required | key | all |
| `title` | `String.t() \| :unknown` | `:unknown` | G | T02, T03 |
| `lifecycle` | `%Lifecycle{}` | `%Lifecycle{}` (`:unknown`/`:unknown`) | G | T02, T03 |
| `created_at` | `DateTime \| :unknown` | `:unknown` | G | T02, T03 |
| `node_id` | `String.t() \| :unknown` | `:unknown` | G | T02, T03 (GraphQL node id; C11-T02 reads closed-ticket bodies through it) |
| `updated_at` | `DateTime \| :unknown` | `:unknown` | G (it is the version; stale-delivery guard, rule 6) | T02, T03 (C4-T03 calls it `version`) |
| `closed_at` | `DateTime \| :none \| :unknown` | `:unknown` | G | T02, T03 |
| `last_closed_at` | `DateTime \| :none \| :unknown` | `:unknown` | latest | T02, T03 (latest close across reopen cycles) |
| `close_observed_at` | `DateTime \| :none \| :unknown` | `:unknown` | latest | T03 (open listing no longer names the issue) |
| `reopened_at` | `DateTime \| :none \| :unknown` | `:unknown` | latest | T02 |
| `merged_at` | `DateTime \| :none \| :unknown` | `:unknown` | latest (with `pr_number`) | T02 (CONNECTED/CLOSED timeline), T03 (`RecentMergeStore`) |
| `pr_number` | `pos_integer \| :none \| :unknown` | `:unknown` | moves with `merged_at` | T02, T03 |
| `labels` | `[String.t()] \| :unknown` | `:unknown` | G | T02, T03 (type, epic and feature inputs are labels) |
| `labels_complete` | `boolean \| :unknown` | `:unknown` | G | T02 (`totalCount <= 100`) |
| `label_events` | `[%{label, action: :labeled \| :unlabeled, at, actor: String.t() \| :unknown}] \| :unknown` | `:unknown` | union | T02 (`feature:` labels only), T03 (C6-T02 reads `actor`) |
| `sub_issues_added` | `[%{ref, at}] \| :unknown` | `:unknown` | union | T02 (C6-T03 root join times) |
| `timeline_complete` | `boolean \| :unknown` | `:unknown` | G | T02 |
| `parent` | `ref \| :none \| :unknown` | `:unknown` | G | T02, T03 |
| `parent_version` | `String.t() \| non_neg_integer \| :unknown` | `:unknown` | G | T03 (edge deposit `data_version`; opaque here, compared by T03's `Feed`) |
| `blocked_by` | `[ref] \| :unknown` | `:unknown` | G | T02, T03 |
| `blocked_by_complete` | `boolean \| :unknown` | `:unknown` | G | T02 |
| `blocked_by_version` | `String.t() \| non_neg_integer \| :unknown` | `:unknown` | G | T03 |
| `in_progress_at` | `DateTime \| :none \| :unknown` | `:unknown` | earliest | T02, T03, T04 hook (C4-T03 calls it `first_in_progress_seen_at`) |
| `dispatched_at` | `DateTime \| :none \| :unknown` | `:unknown` | earliest | T03 telemetry, T04 hook (C4-T03 calls it `first_dispatch_at`) |
| `start` | `DateTime \| :unknown` | `:unknown` | derived | T04 only |
| `start_source` | `:label \| :dispatch \| :unknown` | `:unknown` | derived | T04 only |
| `end` | `DateTime \| :none \| :unknown` | `:unknown` | derived | T04 only |
| `end_source` | `:merged \| :closed \| :unknown` | `:unknown` | derived | T04 only |
| `clamped` | `boolean` | `false` | derived | T04 only |
| `agent_model` | `String.t() \| :none \| :unknown` | `:unknown` | last write | T03 (telemetry dispatch); see §10 decision 5 |
| `agent_effort` | `String.t() \| :none \| :unknown` | `:unknown` | last write | T03 |
| `observed_at` | `DateTime` | required | max | every event |
| `sources` | `[atom]` (set: `:backfill`, `:resource_store`, `:webhook`, `:poll`, `:write`, `:resync`, `:open_listing`, `:recent_merge`, `:telemetry`, `:catch_up`, `:derive`) | `[]` | union | every event |

C4-T04's draft types these signals as "DateTime or nil". In this store, nil is
`:unknown`; C4-T04's `Timing.derive/2` treats `:unknown` and `:none` as its nil.
C4-T04 owns `Timing.derive/2` and `note_start/3`; in its own PR, `Timing`
replaces this store's start/end merge (R-G4).

`lifecycle` accepts `%Lifecycle{state: :closed, state_reason: :unknown}` (an
absence-close, C4-T03) as a valid stored value.

### 4.2 Event and merge rule

An event is `%{number: n, observed_at: dt, source: atom, fields: %{...}}`.
`fields` is a partial map of the row fields above. A field that is absent from
`fields` means "no information" and leaves the row alone. A derived field
(`start`, `start_source`, `end`, `end_source`, `clamped`) is accepted only from
`source: :derive`; from any other source the event is invalid.

Merge, per field, by class:

1. **G (GitHub-mutable).** The event is *newer* than the row when its
   `fields.updated_at` is later than `row.updated_at`; when either side's
   `updated_at` is `:unknown` or the two are equal, the event is newer when
   `event.observed_at >= row.observed_at`. A newer event replaces every G field
   it carries. An older event (a backfill page fetched before a webhook that
   C4-T03 already applied, C4-T02 N16) writes a G field only where the row
   value is `:unknown`. Comparison is on `DateTime.compare/2`, never strings.
2. **earliest / latest.** Keep the earliest (`in_progress_at`,
   `dispatched_at`) or the latest (`merged_at`, `reopened_at`,
   `close_observed_at`) `DateTime`. A `DateTime` beats `:none`, `:none` beats
   `:unknown`. `pr_number` is taken from the event whose `merged_at` wins. This
   makes the signals order-free (C4-T04 "Earliest/latest makes every write
   idempotent").
3. **union.** `label_events` dedupe on `{label, action, at}` sorted by
   `at`; `sub_issues_added` dedupe on `{ref, at}`; `sources` is a set.
   ponytail: no cap per issue; the 10k measurement test (V-16) bounds the
   total, add a cap if one issue exceeds 500 events.
4. **derived, last write.** `source: :derive` events from C4-T04, and
   `agent_model`/`agent_effort`, replace the stored value when
   `event.observed_at >= row.observed_at`, else fill `:unknown` only.
5. `row.observed_at = max(row.observed_at, event.observed_at)`; it never moves
   back.
6. **Stale delivery (C4-T03).** If `fields.updated_at` and `row.updated_at` are
   both `DateTime` and `fields.updated_at` is earlier, the event is late: it
   fills only `:unknown` fields, in every class. Equal is not late.
   `dispatched_at` keeps the earlier value.
7. If the merged row equals the old row, nothing changes: no generation bump, no
   broadcast, no dirty flag. This makes replays idempotent.

A reopen needs no special case: a newer G event with `lifecycle` open and
`closed_at: :none` replaces the closed values (rule 1). `merged_at` and the
derived `end` are not G fields, so C4-T04 keeps "a reopened ticket keeps its
latest end".

### 4.3 Public API (PROPOSED)

```elixir
# Writes (serialized through the GenServer; synchronous so feeders get backpressure)
@spec apply([event()], keyword()) ::
        {:ok, %{generation: pos_integer(), changed: [pos_integer()]}} | {:error, term()}
#   opts: :server, :checkpoint ({key, json_map}) — stored in the same file write as the rows
@spec mark_complete(keyword()) :: :ok | {:error, term()}   # C4-T02 after its last page
@spec flush(keyword()) :: :ok | {:error, term()}

# Reads
@spec snapshot(keyword()) :: {:ok, %{rows: %{pos_integer() => Row.t()}, health: ProviderHealth.t()}}
                            | {:error, ProviderHealth.t()}     # GenServer.call: one consistent copy
@spec rows([pos_integer()], keyword()) :: {:ok, [Row.t()], ProviderHealth.t()} | {:error, ProviderHealth.t()}  # ETS
@spec health(keyword()) :: ProviderHealth.t()                  # ETS
@spec writable?(ProviderHealth.t()) :: boolean()               # pure; see §4.4
@spec checkpoint(atom(), keyword()) :: {:ok, map() | nil} | {:error, ProviderHealth.t()}

# Signal
@spec subscribe() :: :ok | {:error, term()}                   # as pack_status.ex:79
# topic "build-order-history:changed"
# message {:build_order_history_changed, %{generation: g, changed: [n], health: ProviderHealth.t()}}
```

Allowed checkpoint keys: `:backfill` (C4-T02 cursor and `started_at`, the
catch-up floor) and `:closed_since` (C4-T03's watermark). Both live in this
History file; there is no separate backfill file. Any other key is
`{:error, :unknown_checkpoint}`.

**One commit path.** `handle_call({:apply, …})` validates, merges (§4.2) and
then calls one private `commit/3` (`state, changed_rows, checkpoint`) that bumps
the generation, writes ETS, marks dirty, schedules the flush and broadcasts.
C4-T03 adds its handlers inside this module (C4-T03 "Modules") and C4-T04 adds
`note_start/3`; both must go through `Row.merge/2` and `commit/3`, never write
ETS or the state map directly. One broadcast per committed batch carries every
changed number; that is the "one signal per committed change" C4-T03 and
C8-T04 need (EC-10), and an empty batch broadcasts nothing.

**Names.** Settled 2026-10-08: the public names are `apply/2` (with
`checkpoint:`), `health/1` (opts default `[]`, so `health()` works),
`writable?/1` and `mark_complete/1`. C4-T02, C4-T03 and C4-T05 use them.

### 4.4 Health states

| Situation | `ProviderHealth` | Reads | Writes |
| --- | --- | --- | --- |
| No file (new install, backfill not run) | `:healthy`, `complete?: false`, `failure: :backfill_pending` | `{:ok, …}` | accepted |
| File loaded, backfill not finished | `:healthy`, `complete?: false`, `:backfill_pending` | `{:ok, …}` | accepted |
| File loaded, backfill finished | `:healthy`, `complete?: true`, `failure: nil` | `{:ok, …}` | accepted |
| File corrupt (bad JSON, bad row, bad shape, missing or < 1 version) | `:unavailable`, `:history_corrupt`; file quarantined; status persisted as `rebuilding` | `{:error, health}` | accepted (they rebuild it) |
| Restart while rebuilding | `:unavailable`, `:history_rebuilding` | `{:error, health}` | accepted |
| `version` > 1 (a newer release wrote it) | `:unavailable`, `:version_unsupported`; file untouched | `{:error, health}` | `{:error, :version_unsupported}` |
| `repository` in file differs from configured | `:unavailable`, `:repository_mismatch`; file untouched | `{:error, health}` | `{:error, :repository_mismatch}` |
| State dir cannot resolve, or `File.mkdir_p/1` fails (an error tuple, never `:ok =` as `progress_retention.ex:117` does, so `init/1` cannot crash the application boot) | `:unavailable`, `:state_dir_unavailable` | `{:error, health}` | `{:error, :state_dir_unavailable}` |
| Tracker is not GitHub, or the identity is not `"owner/name"` (memory tracker answers `"memory"`, `memory/tracker.ex:11`; `project_identity/0` raised) | `:unavailable`, `:not_applicable`; no dir created, no file | `{:error, health}` | `{:error, :not_applicable}` |
| Symlink or non-regular file at the path | `:unavailable`, `:history_unsafe_path`; never quarantined or followed (`Fs.quarantine/1` renames the link itself, which would hide the evidence) | `{:error, health}` | `{:error, :history_unsafe_path}` |
| Regular file over the size cap | `:unavailable`, `:history_corrupt`; quarantined like any corrupt file | `{:error, health}` | accepted (they rebuild it) |
| Flush failed (disk full, encode error, over cap) | state unchanged, `failure: :flush_failed`; retried on the next debounce | as before | accepted |

`writable?/1` is true exactly for the rows marked "accepted": `:healthy`, or
`:unavailable` with `failure` in `[:history_corrupt, :history_rebuilding]`.
C4-T02 must gate its pages on `writable?/1`, not on read health: a corrupt store
reads unavailable *and* is waiting for C4-T02 to rebuild it, so gating on reads
would wait forever (C4-T02 N10 draft: "`{:unavailable, :corrupt}` → zero
requests").

`mark_complete/1` moves `:history_rebuilding`/`:history_corrupt` and
`:backfill_pending` to `:healthy, complete?: true`, and persists that on the
next flush. `health.observed_at` is the
newest applied `observed_at`; `last_success_at` is the last successful flush.
`generation` starts at the persisted value (1 on a new file) and increases by 1
on every change. The store never decides fresh against stale (the
`ProgressRetention` rule, `progress_retention.ex:22-26`): rows carry
`observed_at` and the renderer computes and shows the age (EC-07, AGENTS.md
"A computed age is rendered").

**Consumer rule (for C8-T04 and C9):** "No history yet" (EC-02, `J:419`) is
correct only when `health.complete?` is true and no closed row exists. While
`complete?` is false the history section is "loading", not empty.

### 4.5 File

Path: `<build_history_state_dir>/history.json`, mode `0600`.

```json
{"version": 1, "repository": "owner/name", "status": "ok",
 "complete": false, "generation": 42,
 "checkpoints": {"backfill": {"cursor": "Y3Vy…", "page": 7, "started_at": "…"}, "closed_since": null},
 "rows": [{"number": 12, "title": "…", "state": "closed", "state_reason": "completed",
           "node_id": "I_kwDO…", "created_at": "2026-09-01T10:00:00Z",
           "updated_at": "2026-09-02T11:00:05Z", "closed_at": "2026-09-02T11:00:00Z",
           "last_closed_at": "2026-09-02T11:00:00Z", "close_observed_at": "unknown",
           "reopened_at": "none", "merged_at": "unknown", "pr_number": "unknown",
           "labels": ["agent:done"], "labels_complete": true,
           "label_events": [{"label": "feature:pag", "action": "labeled", "at": "…", "actor": "kevin"}],
           "sub_issues_added": [], "timeline_complete": true,
           "dispatched_at": "unknown",
           "parent": "none", "parent_version": "unknown",
           "blocked_by": [{"owner": "acme", "repository": "widgets", "number": 7}],
           "blocked_by_complete": true, "blocked_by_version": "unknown",
           "in_progress_at": "unknown",
           "start": "unknown", "start_source": "unknown", "end": "unknown",
           "end_source": "unknown", "clamped": false,
           "agent_model": "unknown", "agent_effort": "unknown",
           "observed_at": "…", "sources": ["backfill"]}]}
```

`state_reason` is stored as one of `"completed"`, `"not_planned"`,
`"duplicate"`, `"reopened"`, `"none"`, `"unknown"`. `from_json/1` maps these
itself and rejects anything else: `Lifecycle.from_github/2` cannot be used on
load, because it maps the string `"none"` to `:unknown`
(`lifecycle.ex:92-104`: only `nil` becomes `:none`) and maps any unknown string
to `:unknown` instead of failing.

`"status"` is `"ok"` or `"rebuilding"`. The sentinels are the strings
`"none"` and `"unknown"`; JSON `null` in a row field is invalid on load.
Size cap `@max_file_bytes 64_000_000`; the writer replaces it with the measured
10k figure times 4 if that is smaller (V-16).

## 5. Implementation steps

1. `lib/aiur/config/paths.ex`: add `build_history_state_dir/0` next to
   `progress_retention_state_dir/0` (`:99-110`): app-env key
   `:build_history_state_dir`, else `Path.join(decision_state_dir, "build-history")`.
   Its `@doc` follows the `progress_retention_state_dir/0` one (own leaf, never
   replayed as decision state).
2. PROPOSED `lib/aiur/build_order/history/row.ex`:
   - `defstruct` with the §4.1 defaults (every optional field `:unknown`).
   - `validate_event/1` → `{:ok, event} | {:error, reason}`: positive integer
     `number`; `%DateTime{}` `observed_at`; `source` in the allowed atom list;
     each field type-checked against §4.1; unknown field keys rejected; strings
     must be valid UTF-8 (`String.valid?/1`).
   - `merge/2` (§4.2) returning `{:changed, row} | :unchanged`.
   - `to_json/1` and `from_json/1` (strict; any bad field is `{:error, {:invalid_row, number, field}}`).
     Lifecycle encodes to the lowercase strings in §4.5 and decodes through an
     explicit string-to-atom table (never `String.to_atom/1`), then
     `%Lifecycle{}`; see §4.5 for why not `from_github/2`. Refs decode only
     with non-empty `owner`/`repository` strings and a positive `number`.
3. PROPOSED `lib/aiur/build_order/history.ex` (GenServer):
   - `init/1`: `Process.flag(:trap_exit, true)`; create the ETS table
     (`:set, :protected, read_concurrency: true`, named from the server name as
     `progress_retention.ex` `mirror_table/1` does); resolve the dir; resolve the
     configured repository (`opts[:repository]`, default
     `Aiur.Tracker.project_identity/0` inside a `rescue`/`catch` as
     `Paths.safe_project_identity/0` does, `paths.ex:311-317`; anything that is
     not `"owner/name"` is `:not_applicable`, §4.4); `File.mkdir_p/1` and match
     its result (an error is `:state_dir_unavailable`); load per §4.4; insert
     every row plus `{:__health__, health}` in one `:ets.insert/2` list call.
     `init/1` never returns `{:stop, _}`: every failure is a health value, so a
     bad file cannot stop the daemon from booting.
   - `handle_call({:apply, events, checkpoint})`: refuse unless
     `writable?(health)`; validate every event first, and on any failure
     return `{:error, {:invalid_event, index, reason}}` with nothing applied;
     merge; if anything changed, call `commit/3` (§4.3): bump generation,
     store the checkpoint, mark dirty, schedule the flush, insert changed rows
     and the health row in one `:ets.insert/2` (atomic and isolated for a set
     table), broadcast. A checkpoint with no row changes still marks dirty but
     does not bump the generation or broadcast.
   - Debounced flush: `opts[:flush_ms]`, default `2_000` (C4-T02 sets its own
     from the measured event rate). Encode → size check → `ensure_regular_file`
     → `Fs.atomic_write(path, json, fsync: true, mode: 0o600)`; first write also
     `Fs.sync_filesystem/0` (the `ProgressRetention` rule).
   - `terminate/2`: flush; log on failure (`aiur_build_history terminate_flush_failed`).
   - No `handle_info({:EXIT, …})` stop clause. `gen_server` itself handles the
     parent's `{:EXIT, parent, reason}` when trapping (it calls `terminate/2`
     and exits). Any other `{:EXIT, …}` (for example a task C4-T03 links later)
     is logged at debug and ignored, so a dying helper cannot take the store
     down.
   - Child spec `shutdown: 10_000` (default 5 s) so the final flush of a large
     file is not killed half way; V-16 measures the flush time and the PR body
     states it. ponytail: raise the value if the measured flush exceeds 5 s.
   - `snapshot/1` by call; `rows/2`, `health/1`, `checkpoint/2` from ETS. When
     the server or its ETS table is not there (`Process.whereis/1` nil, or
     `:ets.lookup/2` raising `ArgumentError`, which is rescued), reads return
     `{:error, ProviderHealth.new(:unknown, :unavailable, false, failure: :history_not_running)}`,
     never an empty map.
   - `broadcast/2` guarded by `Process.whereis(Aiur.PubSub)` (`pack_status.ex:226-232`).
4. `lib/aiur.ex`: add `Aiur.BuildOrder.History,` just before
   `{Aiur.BuildOrder.TicketHistoryProvider, runtime_config?: true}` (`:452`),
   with a one-line comment: "Durable closed-ticket history (MP-E8). Starts before
   any feed (C4-T02/T03) so their first write lands."
5. `test/support/test_boot_guard.exs`: add `:build_history_state_dir` to the
   `derived_paths` resolver list (`:35-48`), so a suite that resolved the leaf
   under the real `~/.aiur` fails at boot (memory note "mix test clobbers
   agent-token"; AGENTS.md "Reading real state").
6. Tests (§8). No other file changes.

Expected size: `history.ex` about 300 lines, `row.ex` about 300 lines (the
merge classes are one table from field to class, not one clause per field).
Complexity stays 3: the extra fields are data, and the merge rules are four
small functions.

## 6. Non-happy paths

- **Corrupt file (EC-31 side).** Quarantined with `Fs.quarantine/1`, never
  deleted, and the store reads as unavailable until C4-T02 rebuilds and calls
  `mark_complete/1`. The `rebuilding` status and the cleared `backfill`
  checkpoint are persisted on the first flush, so a restart mid-rebuild still
  reads unavailable (V-6) and C4-T02 restarts from page 1. While rebuilding,
  `writable?/1` is true, so C4-T02 can rebuild it (V-21). The `complete` flag
  in this file is what says the history is whole: a corrupt store reset to
  incomplete clears the `:backfill` checkpoint, so C4-T02 runs again.
- **Crash between apply and flush.** Rows and the checkpoint that covers them are
  in the same file write, so a resume never skips a page whose rows were lost
  (V-2). Rows lost this way are re-fetched by C4-T02 (resume) or C4-T03 (boot
  catch-up "closed since the watermark"). C4-T02's cursor is the `:backfill`
  checkpoint in the same write, so it cannot be on disk without its rows.
- **Graceful shutdown inside the debounce window.** `trap_exit` makes the
  supervisor's `:shutdown` run `terminate/2`, which flushes (V-3).
- **Rollback to an older release.** An older release has no History child; the
  file sits unused. A file written by a newer schema is never overwritten or
  quarantined by this version (V-7).
- **Wrong repository.** A copied or shared state dir is refused, not merged (V-8).
- **Disk full or encode failure.** Memory stays authoritative, health shows
  `:flush_failed`, the next debounce retries. No crash, so no loss of the
  in-memory rows.
- **Untrusted input.** Titles and labels come from GitHub. The store validates
  types and UTF-8 only; escaping is the renderer's job (EC-30). The file is
  owner-only (`0600`) under the owner-only decision dir, and a symlink at the
  path is refused before read and before write (V-15).
- **Concurrency.** One writer process. Each row read from ETS is whole (one
  insert of a list is atomic and isolated per object). `rows/2` does one lookup
  per number, so two numbers read in one `rows/2` call can come from two
  different batches; a consumer that needs one consistent cut across rows
  (C8-T04's first window, C4-T05's full edge build) uses `snapshot/1`, which
  goes through the mailbox. `snapshot/1` copies the whole map to the caller;
  V-16 measures that copy, and C8-T04 should use `rows/2` for the `changed`
  numbers of each broadcast.
- **Late and duplicate events.** Older events fill only unknown fields (V-10);
  signals are earliest/latest wins (V-20); a replay changes nothing (V-11).
- **Non-GitHub tracker.** The store reports `:not_applicable` and creates no
  directory (V-22); C4-T04 states History is per GitHub repository.
- **Store not running** (tests, early boot): reads return an unavailable health,
  not `%{}` (V-14).
- **Stale data (EC-07).** Every row carries `observed_at`; health carries the
  newest `observed_at` and `last_success_at`. Nothing in the store labels data
  "current".
- **Budget (EC-32).** This ticket makes no GitHub call.

## 7. Compatibility and rollout

- No config key, no CLI flag, no operator env var: no docs change is required
  (AGENTS.md "Docs ship with the change"). The new state leaf is internal.
- No migration: the file is new. Version 1.
- The child starts in every daemon and stays idle until C4-T02/T03 feed it.
  Memory at idle is one empty ETS table. In the test environment the tracker
  is not GitHub, so the app-booted child is `:not_applicable` and writes
  nothing; tests start their own instance with `repository:` and `state_dir:`.
- Forward compatibility: C4-T04's signal and derived fields and C4-T03's
  `updated_at`, `dispatched_at`, rule 6, `:catch_up` source and closed/`:unknown`
  lifecycle are in version 1 already, so neither C4-T03 nor C4-T04 bumps the
  file version.
- Rollback: remove the child line; delete `build-history/` if wanted. Nothing
  else reads it.

## 8. Verification

PROPOSED test file `src/test/aiur/build_order/history_test.exs`
(`async: false`, store started per test with `state_dir:` from
`Aiur.TestSupport.tmp_root!/1`, `repository: "acme/widgets"`, `flush_ms: 50`).
Tests never touch `~/.aiur` or the real decision dir.

| # | Test | Expected | Fails without |
| --- | --- | --- | --- |
| V-1 | "rows survive a restart" | apply 3 events, `flush`, stop, start on the same dir → `snapshot` rows equal field by field, `generation` equal | persistence and `from_json/1` |
| V-2 | "a checkpoint lands in the same write as its rows" | `flush_ms: 60_000`; `apply(events, checkpoint: {:backfill, %{"page" => 3}})`, `Process.exit(pid, :kill)` before the debounce → restart has neither the rows nor the checkpoint; repeat with `flush` before the kill → both present | the checkpoint being part of the row write (a separate eager write leaves the checkpoint without the rows) |
| V-3 | "supervisor shutdown flushes" | `start_supervised`, apply, `stop_supervised` within the debounce (`flush_ms: 60_000`) → restart has the rows | `Process.flag(:trap_exit, true)` |
| V-4 | "a corrupt file reads unavailable, never empty" | write `"{not json"` → `snapshot` is `{:error, %ProviderHealth{state: :unavailable, failure: :history_corrupt}}`; a `history.json.corrupt-*` file exists | the corrupt branch (mutation: return `{%{}, healthy}` → the test gets `{:ok, %{rows: %{}}}` and fails) |
| V-5 | "a row with null fails the whole file" | valid file except one row with `"closed_at": null` → `:history_corrupt` | strict `from_json/1` (a lenient decoder maps null to `:none` and passes) |
| V-6 | "rebuilding survives restart until mark_complete" | after V-4, apply one event, flush, restart → still `:history_rebuilding`, `checkpoint(:backfill)` is `nil`; `mark_complete` → `:healthy, complete?: true`, reads `{:ok, …}` | the persisted `"rebuilding"` status |
| V-7 | "a newer version is left untouched" | file with `"version": 2` → `:version_unsupported`; `apply` → `{:error, :version_unsupported}`; after `GenServer.stop` the file bytes equal the originals and no `.corrupt-*` exists | the version check (without it the file is quarantined or overwritten) |
| V-8 | "another repository's file is refused" | file with `"repository": "other/repo"` → `:repository_mismatch`; bytes unchanged | the repository check |
| V-9 | "unknown stays unknown" | event with only `title` → `merged_at`, `start`, `pr_number`, `agent_model`, `blocked_by`, `in_progress_at`, `updated_at` (and, by a loop over the struct keys, every optional §4.1 field) are `:unknown`, not `nil`, `:none`, `0` or `[]`; the file has the string `"unknown"`; after restart still `:unknown`, and `:none` round-trips as `:none` | the `:unknown` defaults and sentinel encoding (mutation: default `merged_at` to `:none` or `blocked_by` to `[]` → fails) |
| V-10 | "a late older event only fills unknown fields" | (a) no `updated_at`: apply `{observed_at: t2, labels: ["a"]}`, then `{observed_at: t1 < t2, labels: ["b"], title: "x"}` → labels `["a"]`, title `"x"`, `observed_at == t2`. (b) C4-T02 N16: apply webhook `{updated_at: 12:00, observed_at: 12:01, title: "new"}`, then backfill `{updated_at: 11:00, observed_at: 12:30, title: "old"}` → title `"new"` although the backfill was observed later | rule 1 (a last-write-wins merge gives `["b"]`; an `observed_at`-only order gives `"old"` in (b)) |
| V-11 | "replay is idempotent" | apply a batch twice → second result `changed: []`, generation unchanged, exactly one broadcast received | the equality check (rule 7) |
| V-12 | "a reopen moves the row back to open" | closed event at t1 with `merged_at: m`, then open event at t2 with `closed_at: :none` → lifecycle `:open`, `closed_at == :none`, `merged_at == m` | rule 1 for lifecycle; rule 2 keeps `merged_at` |
| V-13 | "one invalid event rejects the batch" | `[valid, %{number: 0, …}]` → `{:error, {:invalid_event, 1, _}}`; `rows([n])` returns no row for the valid one | validate-all-before-merge |
| V-14 | "reads without a running store are unavailable" | call `rows([1], server: :missing)` → `{:error, %ProviderHealth{state: :unavailable, failure: :history_not_running}}` | the not-running clause (mutation: return `{:ok, [], health}` → fails) |
| V-15 | "a symlinked file is refused" | `history.json` is a symlink to a temp file → `{:error, %ProviderHealth{failure: :history_unsafe_path}}`; `apply` → `{:error, :history_unsafe_path}`; the link still exists (not quarantined) and the target bytes are unchanged | the lstat check at load and `ensure_regular_file` at write |
| V-16 | "10k rows: size, memory and time are measured" | 10,000 rows, each with 8 labels, 3 refs in `blocked_by` and 10 `label_events` → `flush` succeeds, file size < `@max_file_bytes`; print file bytes, `:ets.info(table, :memory) * :erlang.system_info(:wordsize)`, the `flush/1` time and the `snapshot/1` time (`:timer.tc/1`); record all four and the 1.4k figures in the PR body (the plan estimate is about 0.4 MB for 1.4k). This is a measurement, not a guard of this change; the guard part is the size assertion | the size cap and encoder (a cap below the real size fails) |
| V-17 | "file is owner-only" | after flush, `File.stat!(path).mode &&& 0o777 == 0o600` | `mode: 0o600` |
| V-18 | "change broadcast carries numbers and generation" | subscribe, apply events for #3 and #5 → receive `{:build_order_history_changed, %{changed: [3, 5], generation: g}}` with `g` = previous + 1 | the broadcast |
| V-19 | "state dir unavailable refuses writes" | `state_dir:` under a regular file (so `File.mkdir_p/1` returns `{:error, :enotdir}`) → the store starts; health `:state_dir_unavailable`; `apply` → `{:error, :state_dir_unavailable}` | the matched `mkdir_p` result (`:ok = File.mkdir_p(dir)` crashes `init/1`) and the refusal |
| V-20 | "signals are earliest or latest, in any order" | apply `in_progress_at: t2`, then `in_progress_at: t1 < t2` → `t1`; apply `merged_at: m1, pr_number: 10`, then `merged_at: m0 < m1, pr_number: 9` → `m1`, `10`; same two events in the other order give the same row | rule 2 (a G-class merge keeps `t2` in the first order) |
| V-21 | "a corrupt store accepts the rebuild" | after V-4, `writable?(health())` is true and `apply` returns `{:ok, _}`; for `:version_unsupported`, `:repository_mismatch`, `:state_dir_unavailable`, `:history_unsafe_path`, `:not_applicable`, `:history_not_running` it is false | `writable?/1` (gating on read health refuses the rebuild) |
| V-22 | "a non-GitHub tracker is not applicable" | start with `repository: "memory"` and no `state_dir` override → health `failure: :not_applicable`; `apply` → `{:error, :not_applicable}`; no `build-history` directory is created under the test decision dir | the identity check |
| V-23 | "lifecycle round-trips exactly" | rows with `{:open, :none}`, `{:open, :reopened}`, `{:closed, :not_planned}` → flush, restart → the same atoms; a file row with `"state_reason": "bogus"` → `:history_corrupt` | the explicit decode table (`Lifecycle.from_github("open", "none")` gives `:unknown`; it also accepts `"bogus"`) |
| V-24 | "a cross-repository blocker keeps its repository" | `blocked_by: [%{owner: "other", repository: "lib", number: 4}]` → after restart the same ref; a ref with `number: 0` is an invalid event | the ref codec (a number-only list loses `other/lib`) |
| V-25 | "derived fields come only from the derive source" | event with `source: :webhook, fields: %{start: t}` → `{:error, {:invalid_event, 0, _}}`; same with `source: :derive` → applied | the source check in `validate_event/1` |
| V-26 | "an exit from a non-parent does not stop the store" | `send(store, {:EXIT, spawn(fn -> :ok end), :boom})` (gen_server passes a non-parent exit to `handle_info/2`) → store still alive, rows intact | the ignore clause (a `{:stop, reason, state}` clause stops it) |

Add to `src/test/aiur/config_paths_test.exs`:
"build_history_state_dir honours the app-env override, else nests under the
decision dir" — fails without the new function. The `test_boot_guard.exs`
entry (step 5) is a guard against a future regression, not coverage of this
change; say so in the PR body.

**Mutation check (AGENTS.md).** In a worktree, with `git status --porcelain`
showing only the intended revert: (a) replace the corrupt branch with an empty
healthy load → V-4, V-6 fail; (b) default every optional field to `nil` → V-9
fails; (c) remove `trap_exit` → V-3 fails; (d) make the merge last-write-wins →
V-10 fails; (e) remove the version check → V-7 fails; (f) make the not-running
read return `{:ok, [], _}` → V-14 fails; (g) decode lifecycle with
`Lifecycle.from_github/2` → V-23 fails; (h) gate `apply` on read health instead
of `writable?/1` → V-21 fails; (i) treat signals as G fields → V-20 fails;
(j) restore `:ok = File.mkdir_p(dir)` → V-19 fails. Restore; all pass. Record the commands
in the PR body.

Command (isolated HOME and no GitHub tokens, per memory note "mix test clobbers
agent-token"):

```bash
env -C /path/to/checkout/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/build_order/history_test.exs test/aiur/config_paths_test.exs
```

Then the full suite on CI for the head SHA (memory note "Narrow test runs hide
bugs": the new child is in the supervision tree).

**Manual check.** None needed for user-visible behaviour (there is none). After
`aiurdev build` and restart, confirm the child is alive and the dir exists:
`aiurdev status` reports the daemon up, and
`ls -l "$AIUR_BG_STATE_DIR"/*/<repo>/build-history/` shows no file until a feed
writes (an empty store does not flush).

## 9. Pixel parity

This ticket draws nothing, so the C1-T02 side-by-side harness has nothing to
compare for it. Parity depends on it in one way: the C1-T02 screenshots of the
real DataSource (after C8-T04) can match the design's history section only if
every input of the design's history record exists. The row covers
`J:190-191` (`num`, `title`, `created`, `start`, `end`, done or failed through
lifecycle and `merged_at`, `deps` through `blocked_by`, type, epic and feature
through `labels` and `parent`, `agent.model` and `agent.effort` through
`agent_model`/`agent_effort`) and the `children` index at `J:288` (through
`blocked_by`, built by C4-T05). V-9 checks that each of these has an explicit
`:unknown`. `cx`, `pts` come from `complexity:N` labels; `also` and `feature`
from labels and the C6 registry.

## 10. Decisions made without the owner

1. **Health is `Aiur.BuildOrder.ProviderHealth`,** not a new type. Every other
   Build Order source already reports through it, so C8-T04 needs no new branch.
2. **`Fs.atomic_write/3` with `mode: 0o600`, not `JsonStore.write!/2`** (the row
   names `JsonStore.write!`). `write!` is the same call without a file mode, and
   it raises: a raise in the store process would drop every unflushed row. The
   mechanism (temp file, fsync, rename) is the one the row asked for.
3. **No checksum,** unlike `ProgressRetention`. The atomic rename prevents torn
   files, and strict per-row decoding catches every other bad file. A checksum
   would rehash a multi-MB file on every flush for no extra case.
4. **Feature label events and sub-issue join times are stored, not every label
   event.** The row lists "the epic and feature inputs"; C4-T02 keeps only
   `feature:` label events and `SubIssueAddedEvent`s and drops the rest to stay
   near the 0.4 MB estimate. C4-T04 reads "start" from `in_progress_at`, not
   from a label-event list, so the generic list is not needed. The field is
   named `label_events` and each item carries `actor` (C6-T02 reads it).
5. **`agent_model` and `agent_effort` are stored** (not in the row's field list).
   The design draws the model logo on history cards (`J:828`) and filters
   history by model (`J:338`). GitHub has no model, so backfilled rows stay
   `:unknown` unless telemetry (30-day retention) still has the dispatch.
6. **Writes are a synchronous call.** The feeders (C4-T02 pages, C4-T03 bursts)
   then get backpressure and an error they can act on. Fire-and-forget casts
   would hide a refusal (`:version_unsupported`).
7. **Corrupt means unavailable until the rebuild completes,** and this state
   survives restart. A new install with no file is healthy and incomplete
   (`complete?: false`), because it has lost nothing; the consumer rule in §4.4
   keeps it from rendering as "No history yet".
8. **A newer-version or wrong-repository file is never touched.** Refusing writes
   is safer than quarantining a file a newer release will need on roll-forward.
9. **Rows are keyed by issue number** in a store that is already
   repository-scoped by the decision dir, plus a `repository` check in the file.
   This matches the page's `?ticket=` ids (EC-17, EC-29). C4-T03 drafted
   `{repo_full_name_downcased, number}`; it filters other repositories before
   building an event, so the key needs no repository part.
10. **The field set is the union of the four C4 neighbours' drafts** (§4.1),
   with C4-T04's names for the timing signals. One version-1 schema now is
   smaller than three later version bumps. Each feeder keeps its own rules in
   its own pure module (C4-T03 `Feed`, C4-T04 `Timing`); the store's merge
   classes (§4.2) only make the stored result order-free.
11. **G fields are ordered by GitHub `updated_at`, then `observed_at`.** Both
   C4-T02 ("the row with the newer `updated_at` wins") and C4-T03 (`version`)
   need it; `observed_at` alone lets a later-fetched old page overwrite a newer
   webhook (V-10 b).
12. **Refs carry owner and repository** (`%{owner, repository, number}`), the
   `Bounded.same_repository?/2` shape, because C4-T02 keeps cross-repository
   blockers and C4-T05 marks them `missing`. A number-only list would silently
   turn them into same-repository edges.
13. **A non-GitHub tracker gets `:not_applicable`, not an empty store.** C4-T04
   states History is per GitHub repository; an empty healthy store would make
   the page claim "No history yet".

## 11. Completion and handoff

- [ ] `Aiur.BuildOrder.History` and `History.Row` exist with the §4.3 API; the
      child starts in the application tree.
- [ ] `Config.Paths.build_history_state_dir/0` exists and is tested.
- [ ] V-1..V-26 and the Paths test pass; each mutation in §8 fails the named
      tests; the PR body lists the commands and the V-16 measured numbers.
- [ ] No reader path returns an empty map or empty list for an unavailable store.
- [ ] No docs change (internal state only); the PR says so.
- **Dependents:** C4-T02, C4-T03 (feeders and checkpoints), C4-T04 (signals,
  start/end), C4-T05 (edges), C6-T05, C7-T01, C7-T04, C8-T04 (reads,
  topic, the "complete before No history yet" rule).
- **Hand-off notes for neighbours.** Settled 2026-10-08: the names and
  shapes below are final; each neighbour uses them.
  - **C4-T02.** Settled 2026-10-08: `apply/2` with `checkpoint: {:backfill, …}`
    (cursor plus `started_at`), `health/1` and `writable?/1` (gate pages on
    `writable?/1`), `mark_complete/1` after the last page; no separate
    backfill file; `sub_issues_added` items are `%{ref, at}`.
  - **C4-T03.** Settled 2026-10-08: `version` is `updated_at`; checkpoint key
    `:closed_since` (watermark), floor = `:backfill.started_at`; rule 6,
    `:catch_up`, `dispatched_at` and the closed/`:unknown` lifecycle are in
    version 1. It feeds `agent_model`/`agent_effort` from telemetry; handlers
    call `Row.merge/2` and `commit/3` and gate on `writable?/1`.
  - **C4-T04.** Settled 2026-10-08: the signal and derived fields exist in
    version 1 (no bump). `:unknown`/`:none` stand for its nil. C4-T04 owns
    `Timing.derive/2` and `note_start/3` (through `commit/3`, `source:
    :derive`) and replaces the start/end merge in its PR.
  - **C4-T05.** Settled 2026-10-08: `health/1` with default opts; `blocked_by`
    refs are `%{owner, repository, number}`.
  - C8-T04 must treat `complete?: false` as loading, not empty, and map the
    design's history `status` ("done" or "failed", `J:1152`) from lifecycle and
    `merged_at`; no C4 ticket defines "failed" for a closed ticket.
- **Sources:** tickets/README.md C4 rows; chunks.md MP-E8-C4; plan.md §5.1, §8
  (EC-07, EC-31, EC-32), §11; AGENTS.md "Tests must fail without the production
  change they guard"; code paths in §3 at `58854d4c8`; design `J:190-191`,
  `J:288`, `J:338`, `J:419`, `J:828`, `J:1152-1153`.
- **Remaining blocker:** DESIGN-E8 sign-off only.

## Review log

Adversarial review, 2026-10-08, against `runtime/src` at `58854d4c8`, the
design source and the neighbour drafts (C4-T02, C4-T03, C4-T04, C4-T05, C6-T05,
C7-T01, C8-T04).

1. Row field set aligned with the neighbours: added `updated_at`,
   `close_observed_at`, `reopened_at`, `in_progress_at`, `dispatched_at`,
   `start_source`, `end_source`, `clamped`, `labels_complete`,
   `blocked_by_complete`, `timeline_complete`, `sub_issues_added`, the two edge
   versions; renamed `label_events` to `feature_label_events` (decisions 4, 10).
2. `parent` and `blocked_by` became `%{owner, repository, number}` refs; the
   number-only list lost cross-repository blockers that C4-T02 keeps and C4-T05
   marks missing (decision 12, V-24).
3. Merge rule rewritten per field class; G fields ordered by `updated_at` then
   `observed_at` (C4-T02 N16 would fail under the old rule); signals
   earliest/latest (V-10 b, V-20); derived fields only from `:derive` (V-25).
4. Lifecycle decode no longer uses `Lifecycle.from_github/2`: it maps `"none"`
   to `:unknown` (`lifecycle.ex:92-104`) and accepts any string (V-23).
5. Added `writable?/1` and the rule that C4-T02 gates on it; the old design let
   a corrupt store wait forever for a rebuild that waits on read health (V-21).
6. `init/1` now matches the `File.mkdir_p/1` result; the copied
   `:ok = File.mkdir_p(dir)` (`progress_retention.ex:117`) would crash boot and
   V-19 could not pass as written.
7. Removed the `handle_info({:EXIT, _, _}) → {:stop, …}` clause; gen_server
   already handles the parent exit, and the clause would let any linked helper
   stop the store (V-26). Added `shutdown: 10_000` for the final flush.
8. Added the `:not_applicable` state for non-GitHub trackers and the rescued
   identity lookup (`tracker.ex:153-159`, `paths.ex:311-317`) (V-22).
9. Symlink health is now `:history_unsafe_path` for both reads and writes (was
   `:history_corrupt` on reads); an oversized regular file is corrupt and
   quarantined.
10. Corrected the ETS consistency claim: `rows/2` across numbers can span two
    batches; consistent cuts use `snapshot/1`, whose copy cost V-16 measures.
11. Checkpoint key `:closed_since` renamed to `:watermark` (C4-T03's name);
    `subscribe/0` spec matches `pack_status.ex:79`.
12. Added step 5 (`test_boot_guard.exs:35-48` resolver list) and dropped the
    moduledoc "consumers list" edit (that list names log consumers, not
    durable stores).
13. Corrected the design note: `J:828` draws the logo only at detail level
    `"full"`; `J:338` uses `"none"` for no agent.
14. §11 hand-offs now list each neighbour mismatch and its resolution,
    including C4-T02's missing `mark_complete/1` call and its separate
    `backfill.json` checkpoint.
15. V-2 sets a long debounce so the kill lands before the flush; mutation list
    extended (g–j); checklist covers V-1..V-26.

Residual risks: C4-T02 and C4-T03 drafts still use their own names and
C4-T02 owns a separate checkpoint file until their writers adopt §11; the 10k
size, ETS memory, flush and snapshot times are unmeasured until V-16 runs.
- Reconciliation 2026-10-08 (coordinator): absorbed `node_id`, `last_closed_at`, `label_events` with `actor` (renamed from `feature_label_events`), merge rule 6 (stale delivery), closed/`:unknown` lifecycle note; checkpoint keys `:backfill` (with `started_at`) and `:closed_since` (was `:watermark`); removed `backfill.json` paths; `Timing.derive/2` and C4-T04 replacing the start/end merge; §4.3 names and §11 hand-offs marked settled.
