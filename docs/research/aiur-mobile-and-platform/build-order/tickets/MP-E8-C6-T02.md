---
ticket_id: MP-E8-C6-T02
feature_id: MP-E8
chunk_id: MP-E8-C6
bucket: 2-platform
title: feature label projection and reconciliation
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C6-T01, MP-E8-C4-T01, MP-E8-C4-T03, MP-E1-C3-T01, MP-E1-C3-T04]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-13, EC-32]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C6-T02 — `feature:` label projection and reconciliation

> Cites code at `origin/main` `58854d4c8` (runtime checkout
> `aiur-worktrees/runtime/src`). Paths marked PROPOSED do not exist yet.
> C6-T01, C4-T01/T03 (History) and MP-E1-C3-T01/T04 have no merged code at the
> time of writing. §4.1 states the interface this ticket needs from each, as
> their ticket docs define it today. If the
> merged code names it differently, follow the merged code and change only the
> names here. If MP-R1 has moved `build_order/` first, re-resolve the paths
> (CR-E8-6 puts `Features` in `build-orders`).

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C6
  (features), ticket T02.
- **User value.** A person can tag a ticket into a feature from GitHub by adding
  `feature:<slug>`, and a feature join made with `aiur feature add` is visible on
  GitHub. The registry (C6-T01) stays the system of record (options F-C), and
  the two never fight: a label never undoes a CLI change, and a CLI change never
  loses a human's label without a journal entry.
- **Deliverable.**
  1. PROPOSED `src/lib/aiur/build_order/features/label_projection.ex`
     (`Aiur.BuildOrder.Features.LabelProjection`): one GenServer that
     - reads label observations from `Aiur.BuildOrder.History` (C4-T01 rows,
       fed by C4-T03), with no GitHub reads of its own;
     - turns a `feature:<slug>` label with no registry membership into a join;
     - turns a confirmed label removal into a leave;
     - writes the label for a registry join and removes it for a registry leave,
       paced and budget-aware;
     - keeps its per-membership projection state in its own small JSON file
       (§4.2), not in the C6-T01 journal;
     - reports `status/0` and `label_states/1`, and offers `mark_labelled/3`
       (C13-T02 releases a held backfill join through it).
  2. PROPOSED `src/lib/aiur/build_order/features/label_rules.ex`: pure functions
     (label parse, the registry reconcile in §4.2 and the decision table in
     §4.3), so the rules are unit-tested without a process.
  3. One child line in `src/lib/aiur.ex` (`child_specs/1`, `:262`).
  4. aiur-build: `feature` joins the routing label families
     (`validation_github_labels.py:44-49`, `validation_header.py:41-43`) with
     tests (CR-E8-7).
  5. Docs: one row in `website/docs-app/apis/github.md` "Changes Aiur makes
     itself" (§7).
- **Non-goals.**
  - The registry, journal, hue and `--move` rule (C6-T01).
  - Importing Build Order roots (C6-T03). Imported memberships get **no** label
    writes (options §2.8); this ticket only honours that. Unconfirmed `backfill-agent`
    joins start `:held_backfill`: no write here; only C13-T02 releases them
    (C13-T04 item 4).
  - The CLI (C6-T04). It reads `status/0` and `label_states/1` and may call
    `retry/1`.
  - Suggestions from edges or parent links (plan §10 item 14: deferred).
  - Any rendering. The design has no label concept (§9).
  - A timeline read to learn who applied a label (§10 decision 3).

## 2. Dependencies and blockers

- **DESIGN-E8.** Every MP-E8 ticket (tickets/README.md rules). No S-n item
  changes this ticket's behaviour. OQ-E8-6 (hue) is C6-T01's.
- **MP-E8-C6-T01.** The registry API in §4.1 (`add/3`, `remove/3`,
  `snapshot/1`, `journal/2`, `subscribe/0`; C6-T01 §4.4). This ticket asks
  C6-T01 for nothing new.
- **MP-E8-C4-T01 and C4-T03.** Label observations come from History rows
  (`labels`, `labels_complete`, label events, `observed_at`) and its change
  signal. This is an **extra blocker beyond the README row** (§10 decision 1).
  C4-T02 (backfill) adds the `actor` key to label events; it is **not** a
  blocker: without it every label join is `label:unknown`.
- **MP-E1-C3-T01.** Owns the `build_queue.max_writes_per_minute` key (its key
  table, default 20, bounds 1..60). Reused for pacing, so no new config key is
  added. Extra blocker beyond the README row.
- **MP-E1-C3-T04.** Reuses its optional tracker callback `ensure_labels/1`
  (one-time label create per slug, C3-T04 "Ensure label"). Extra blocker beyond
  the README row. MP-E1 is wave 0 and ships before E8 (plan §6, line 182), so
  neither MP-E1 blocker moves E8's start.
- **Read first:** `website/docs-app/apis/github.md` (AGENTS.md rule for any
  change that talks to GitHub), sections "Changes Aiur makes itself" (`:695-719`)
  and "Writes stay on their own identity" (`:457-468`).
- **Contract request:** CR-E8-7 (tickets/CONTRACT-REQUESTS.md). §3 shows that
  its premise is partly stale; see §4.6.
- **Successors.** C6-T04 (`aiur feature` shows `status/0` and per-member label
  state from `label_states/1`; its `add`/`remove` rely on this ticket to write
  and remove labels), C5-T04, C12-T07, C13-T04 (through C6-T04; it also relies
  on the `backfill-agent` rules in §4.2 and R6b).
- **Concurrent with:** C6-T03, C6-T05, C5-T03, C7, the whole client track.

## 3. Verified starting point (`58854d4c8`)

**Label writes.**
- `src/lib/aiur/tracker.ex:26-27` — `add_label/2`, `remove_label/2` callbacks;
  `:110-117` the facade; `:162-168` `adapter/0` (`github`, `memory`, else Linear).
- `src/lib/aiur/github/tracker.ex:194-201` — delegates to the client.
- `src/lib/aiur/github/issue_state.ex:38-61` `add_label/3` — `POST
  /repos/:o/:r/issues/:n/labels` with `{"labels": [label]}`; on 2xx deposits the
  answer through `WriteThrough.issue_labels/2`; other statuses go through
  `Errors.github_status_error/1` (`errors.ex:124-125`), so a 404 or 410 comes
  back as `{:github, :http, %{status: 404 | 410}}` (`classify_status/2`
  `:122`). `:64-89` `remove_label/3` — `DELETE
  .../labels/:name`; **404 counts as success** (`:80-82`), so a removal is
  idempotent.
- `src/lib/aiur/github/write_through.ex:169` `issue_labels/3` — puts the label
  set in ResourceStore, so our own write reaches History through C4-T03 with no
  extra read ("Changes Aiur makes itself", `apis/github.md:697-701`).
- `src/lib/aiur/linear/tracker.ex:139,142` — both answer `{:error, :unsupported}`.
- `src/lib/aiur/memory/tracker.ex:109-119` — both answer `:ok` and send a test
  event (`{:memory_tracker_add_label, id, label}`), which the tests use.
- `src/lib/aiur/github/labels.ex:158-194` `ensure/5` — creates a label; 422
  `already_exists` is success. Its errors are **not** `{:github, kind, _}`:
  `{:github_api_status, status, label}` or `{:github_api_request, reason}`
  (`:178-186`), so §4.4 classifies them separately. Whether `POST .../issues/:n/labels` creates a
  missing label is unverified (MP-E1 findings F11), so the label is ensured
  first.
- `src/lib/aiur/github/errors.ex:26-27` — error kinds include `:auth`,
  `:rate_limited` and `:local_hold`; `:82-83` maps `{:aiur, :locally_held, hold}`
  to `{:github, :local_hold, _}`; `:90-91` broker timeout is also `:local_hold`;
  `:104` 401 is `:auth`; `:106-120` 403 with a rate-limit signal and 429 are
  `:rate_limited`.

**Labels are not states.**
- `src/lib/aiur/github/labels.ex:24` state suffixes, `:34` marker suffixes,
  `:92-97` `marker_suffix?/1`. They apply only to the configured prefix
  (`GitHub.Config.label_prefix/0`, `github/config.ex:310`). `feature:` is
  parsed as a state only if an operator sets `label_prefix: feature` (§6).
- `src/lib/aiur/github/issues.ex:1013` — label names are lowercased at
  ingestion.

**Where labels are observed today.**
- The open-issue poll (`issues.ex:380-391`, `:404-413`, `record_open_issues/3`
  `:437-441`) and webhook deposits (`events/github_webhook/deposit.ex:571-587`
  stores `:issue_labels` versioned by the issue's `updated_at`). Neither carries
  the login of the person who applied a label: the normalizer turns an
  `issues.labeled` delivery into `{:reconcile, %{kind: :issue_state, ...}}`
  without the sender (`events/github_webhook/normalizer.ex:299-321`).
- C4-T03 (ticket doc) already consumes both feeds into History rows with a
  version guard (its deliverable items 1-2 and its "Observation rules" table).
  Its label diff makes `%{label, action: :labeled | :unlabeled, at:
  updated_at}` events and makes **none** on the first sighting of a row. Open
  listing rows carry `observed_at = listed_from` (the listing start time).
  C4-T01 §4.1 keeps `labels`, `labels_complete` and the events
  (`label_events`, each `{label, action, at, actor :: String.t() | :unknown}`)
  per row with `observed_at`. This ticket reads those rows
  instead of adding a third consumer to `record_open_issues/3`.

**aiur-build reconciliation** (repo root `.claude/skills/aiur-build/scripts/`).
- `validation_github_labels.py:44-49` — routing families
  `<lifecycle>, human, model, phase, complexity, build-lane`. `:106-111` — an
  **observed** label is rejected only if it starts with a routing prefix and was
  not expected; a **projected** label is rejected if not expected at all.
- `validation_header.py:41-43` — `RESERVED_ROUTING_PREFIXES`; `:117-175` —
  `required_ticket_labels` may hold any non-lifecycle label, so
  `feature:<slug>` can be projected today.
- `tests/test_github_reconciliation.py:40-55` — "allows unrelated labels" and
  "rejects unprojected routing families" (`agent:queued`, `human:todo`, …).
- These tests do not run in CI: no file under `.github/` or `scripts/` names
  `aiur-build` (grep at `58854d4c8`).

**Supervision.** `src/lib/aiur.ex:125` the tree is `:rest_for_one`, so a crash
restarts every later child (`:85-105`, `:293-298` explain the cost).
`child_specs/1` `:262`; `:274` `recording?`; `:494-499` the last child,
`if(recording?, do: Aiur.AllowedContributors)`, placed last "so a restart of it
can never cascade"; `:500-503` nil children are rejected and `cli_children` are
appended after. `test/aiur/application_test.exs:174-205` asserts children by
calling `AiurApp.child_specs(recording?: …)` and `modules/1`.

**Durable small state.** `src/lib/aiur/fs.ex:19` `Aiur.Fs.atomic_write/3`
(temp file, optional `fsync: true` and `mode:`, rename; returns
`{:error, reason}`); `src/lib/aiur/json_store.ex:44-61` `JsonStore.read/2`
(missing file → default, corrupt → `{:error, _}`).

**History health.** `src/lib/aiur/build_order/lifecycle.ex:1-62`
`Aiur.BuildOrder.ProviderHealth` (`state :healthy | :stale | :unavailable |
:structurally_invalid`, `complete?`, `observed_at`); `usable?/1` `:46-51` also
requires `complete?: true`, which History is not until its backfill ends
(C4-T01 §4.4), so this ticket gates on `state` instead (§4.3 R1).

## 4. Chosen design

### 4.1 Interfaces this ticket needs (owned by predecessors)

| From | Needed (as the predecessor's ticket doc defines it) | Why |
| --- | --- | --- |
| C6-T01 `Aiur.BuildOrder.Features` (§4.4) | `add(slug, [n], source:, actor:, at:, move:)` and `remove(slug, [n], source:, actor:, at:)` → `{:ok, %{generation, changed, slugs}}` or `{:error, {:owned_elsewhere, [{n, other}]}}`, `{:error, {:unknown_feature, slug}}`, `{:error, {:not_member, [n]}}` | Label joins, leaves and the R6b move |
| C6-T01 | `snapshot(opts)` → `{:ok, %{features, owners: %{n => %{feature, source, actor, confirmed, …}}, generation, health}}` or `{:error, ProviderHealth}` | Registry side of every decision; known slugs |
| C6-T01 | `journal(slug, opts)` (oldest first; records carry `source`) | Rebuild of tombstones after a lost state file (§4.2) |
| C6-T01 | `subscribe/0`; `{:build_order_features_changed, %{generation, changed: [n], slugs}}` | Wakes the writer |
| C6-T01 §4.3 | `source` regex `^(cli\|agent\|label\|inherited\|import):[A-Za-z0-9._\-\[\]]{1,64}$\|^backfill-agent$`; `actor` 1..100 chars, required | `label:<login>` and `label:unknown` both pass |
| C4-T01 `History` (§4.3) | `subscribe/0`, `{:build_order_history_changed, %{generation, changed: [n], health}}`; `rows/2` → `{:ok, rows, health}`; `snapshot/1`; `health/1` (`ProviderHealth`) | Observations |
| C4-T01/T02 | row `labels`, `labels_complete`, `label_events` `%{label, action, at, actor :: String.t() \| :unknown}` (C4-T01 row spec; C4-T02 fills `actor`), `observed_at` | R1–R11 |
| MP-E1-C3-T04 | optional callback `ensure_labels([label])` on the tracker adapter → `:ok \| {:error, _}` (GitHub delegates to `Labels.ensure/5`) | Create the label once |
| MP-E1-C3-T01 | `Config.settings!().build_queue.max_writes_per_minute` (default 20, 1..60) | Pacing |

C6-T01 stores no projection state and keeps no "recently left" members. This
ticket does not ask it to (§10 decision 7).

### 4.2 Projection state (this ticket's own file)

File: `<Config.Paths.build_features_state_dir/0>/label-projection.json`
(C6-T01's directory), written with `Aiur.Fs.atomic_write(path, json, fsync:
true, mode: 0o600)` and read with `JsonStore.read/2`. One entry per
`{slug, number}`:

```elixir
%{state: :pending_label | :labelled | :exempt | :held_backfill | :pending_unlabel | :unlabelled | :failed,
  written_at: DateTime.t() | nil,     # our last successful write
  seen_at: DateTime.t() | nil,        # last observation that had the label
  attempts: non_neg_integer(),
  last_error: String.t() | nil}       # inspect/1 of the error, truncated to 200 chars
```

`seen_at` is kept in memory and saved only with the next state change, so an
echo on every poll does not rewrite the file.

**Registry reconcile** (`LabelRules.reconcile_registry(entries, owners)`, pure),
run on boot and for the `changed` numbers of every registry signal:

| Registry owner of `n` | Entry for `{s, n}` | New entry |
| --- | --- | --- |
| `s`, source `cli:*`, `agent:*` or `inherited:parent`, `confirmed: true` | none | `:pending_label` |
| `s`, source `label:*` | none | `:labelled` (the label is already there) |
| `s`, source `import:*`, or `confirmed: false` with a source other than `backfill-agent` | none | `:exempt` — no label write, ever (options §2.8) |
| `s`, source `backfill-agent` | none | `:held_backfill` — no write by this ticket; only C13-T02's `mark_labelled/3` releases it (C13-T04 item 4) |
| not `s` (removed, or moved to another slug) | `:labelled`, `:pending_label` or `:failed` | `:pending_unlabel`; if the remove's source was `label:*`, `:unlabelled` |
| not `s` | `:exempt` or `:held_backfill` | dropped |
| not `s` | `:unlabelled` | dropped after 24 h (the tombstone is no longer needed) |

The writer knows when it made the `label:*` remove itself, so it sets
`:unlabelled` directly. After a crash between the remove and the save, the row
reads `:pending_unlabel`, and the `DELETE` answers 404, which is `:ok`
(`issue_state.ex:80-82`): one extra call, no wrong state.

**Lost or corrupt file.** `JsonStore.read/2` → `{:error, _}`: rename the file to
`label-projection.json.corrupt-<unix>`, log once, and rebuild. Entries for
current owners come from the table above, then any `:pending_label` or
`:held_backfill` whose History row already has the label becomes `:labelled`
(so a join C13-T02 already released is not held again). Tombstones come from
`journal/2`: the newest `member.removed` per number with a non-`label:` source,
when History still shows `feature:<slug>` on that row, becomes
`:pending_unlabel`. A missing file (new install) is the same rebuild with no
log line.

### 4.3 Decision table (pure, `LabelRules.decide/4`)

Input: one History row, the registry owner of that number, the entries for that
number, and `now`. Labels are already lowercased (C4-T03); a slug must pass
C6-T01's slug rule `^[a-z0-9][a-z0-9-]{0,41}$`. Each `feature:` label on the row
is checked against the tombstones first (R7), then the other rules.

| # | Observation | Registry / entry | Action |
| --- | --- | --- | --- |
| R1 | `row.labels == :unknown`, or History `health.state != :healthy` | any | nothing (unknown is not absent) |
| R1b | label absent, but `row.labels_complete == false` | any | no absence rule (R8, R9, R10) fires: the label may be past the first 100 |
| R2 | has `feature:s`, `s` not in `snapshot.features` | — | no join; record `{n, s}` in `status.unregistered` |
| R3 | has `feature:s`, no owner, no other registered `feature:` label | none | `add(s, [n], source: "label:" <> actor_or_unknown, actor: actor_or_unknown, at: t)`; `t` = the newest `:labeled` event `at` for that label, else `row.observed_at` |
| R4 | has two or more registered `feature:` labels and no owner | none | no join; `status.conflicts` |
| R5 | has `feature:s`, owner is `s` | entry `:pending_label`, `:labelled` or `:failed` | `:labelled`, `seen_at = observed_at` (covers our own write echo and a human adding it first). An `:exempt` entry stays `:exempt`; a `:held_backfill` entry stays held until `mark_labelled/3` |
| R6 | has `feature:t`, owner is `s ≠ t`, owner `confirmed: true` | — | no change, never remove the human's label; `status.conflicts` |
| R6b | has exactly one registered `feature:t`, owner is `s ≠ t`, owner source `backfill-agent` and `confirmed: false` | — | `add(t, [n], move: true, source: "label:" <> actor_or_unknown, …)`: a human label replaces an unconfirmed guess (C13-T04 item 4) |
| R7 | has `feature:s`, entry `{s, n}` is `:pending_unlabel` | tombstone | nothing; the unlabel is still due |
| R8 | lacks `feature:s`, owner `s`, entry `:labelled`, `row.observed_at > (written_at \|\| seen_at) + settle` and `row.observed_at > seen_at` | — | `remove(s, [n], source: "label:" <> actor_or_unknown, …)`; the entry becomes `:unlabelled` |
| R9 | as R8 but inside the settle window | — | re-check at `(written_at \|\| seen_at) + settle` with `History.rows/2` |
| R10 | lacks `feature:s`, entry `:pending_unlabel` | tombstone | `:unlabelled` (someone removed it first) |
| R11 | lacks `feature:s`, entry `:pending_label`, `:exempt` or `:held_backfill` | — | nothing (absence is expected) |

`settle` is 120 s (ponytail constant: a webhook or body that was read before our
write can arrive after it; C4-T01's version rule and C4-T03's `listed_from`
stop most of these, the settle window stops the rest). `actor_or_unknown` is
the label event's `actor`, or the literal `unknown` when the event has none or
there is no event; it is never the daemon login or `executor`. A
`{:error, {:owned_elsewhere, _}}` from `add/3` (a CLI write raced the decision)
is recorded as an R6 conflict, not retried.

### 4.4 Writer

- On a registry change signal, on boot, and every 60 s: take entries in
  `:pending_label` or `:pending_unlabel`, oldest first.
- Pacing: two token buckets refilled from an injected clock:
  `max_writes_per_minute` per minute, and 200 per hour (ponytail constant:
  GitHub's secondary limit is also 500 content-generating requests per hour,
  MP-E1 findings F11, and the build queue and the daemon's other writes share
  it). Extra writes wait.
- Before the first write for a slug in this boot: `adapter.ensure_labels/1`
  when `function_exported?(adapter, :ensure_labels, 1)`, else skip. The adapter
  is `Aiur.Tracker.adapter/0` (`tracker.ex:162-168`), injected as `:tracker` in
  tests. A failed ensure leaves the item pending and is classified as below.
  The ensure call counts against the bucket.
- `:pending_label` → `adapter.add_label(to_string(n), "feature:" <> slug)`;
  `:pending_unlabel` → `adapter.remove_label/2`.
- Save the file **after** every outcome. A crash between the write and the save
  repeats the write on restart; both calls are idempotent (a repeated `POST` of
  a present label leaves the set unchanged; `DELETE` 404 is `:ok`,
  `issue_state.ex:80-82`).

| Result | Effect |
| --- | --- |
| `:ok` | `:labelled` (with `written_at`) or `:unlabelled` |
| `{:error, {:github, kind, _}}` with `kind in [:rate_limited, :local_hold, :auth]`; from ensure: `{:github_api_status, s, _}` with `s` in `[401, 403, 429]`, or `{:github_api_request, {:aiur, :locally_held, _}}` / `:github_budget_broker_timeout` | `status.writes = :paused`; no more writes until the next 60 s tick; attempts unchanged |
| `{:error, :unsupported}` | `status.tracker = :unsupported`; stop the writer; items stay pending |
| `{:error, {:github, :http, %{status: s}}}` with `s in [404, 410]` on add (issue gone or transferred) | `:failed`, not retried |
| any other error | attempts + 1; retry on later ticks; at 5 → `:failed` with `last_error` |

`retry(pairs)` resets `:failed` items to `:pending_label` or `:pending_unlabel`
(C6-T04 may call it). Failed items are also retried once per daemon boot.

### 4.5 `status/0`, `label_states/1` and `mark_labelled/3`

```elixir
%{tracker: :ok | :unsupported | :prefix_collision,
  observation: ProviderHealth.state() | :not_running,   # History.health/1
  observed_at: DateTime.t() | :unknown,                 # health.observed_at; the CLI shows its age
  writes: :running | :paused,
  pending: non_neg_integer(), failed: [{slug, n, reason}],
  unregistered: [{n, slug}], conflicts: [{n, [slug]}]}
```

`pending` is a count of known entries. When the registry snapshot cannot be
read, or the state file was not loaded, the call answers
`{:error, :registry_unavailable}` or `{:error, :projection_state_unavailable}`,
never `pending: 0`.

`label_states([n])` → `{:ok, %{n => state}}` for owned numbers (a number with
no entry is absent, which C6-T04 shows as "unknown"), or the same errors. This
replaces C6-T04's assumption that the state is on the C6-T01 owner record
(§11 return note).

`mark_labelled(slug, n, %{written_at: DateTime.t() | nil, seen_at: DateTime.t()})`
(for C13-T02) → `:ok` when the entry is `:held_backfill` and `n` is still owned
by `slug`: the entry becomes `:labelled` with those times and is saved before
the reply. Otherwise `{:error, :not_held}` or `{:error, {:not_member, [n]}}`,
with no change. `seen_at` is required so R8's `written_at || seen_at` is never
nil. Nothing else moves an entry out of `:held_backfill`.

### 4.6 aiur-build

- Add `"feature"` to `routing_prefixes` (`validation_github_labels.py:44-49`)
  and to `RESERVED_ROUTING_PREFIXES` (`validation_header.py:41-43`).
- Effect: a member projected with `feature:<slug>` through
  `required_ticket_labels` passes (as it already does); an **observed**
  `feature:` label that the document did not project is now drift, as
  `build-lane:` is, because a ticket has one owning feature (E8-D11); and
  `feature:todo` can never be read as the lifecycle todo label.
- The CR-E8-7 premise ("the test rejects `feature:`") is false at `58854d4c8`:
  `feature:` is ignored as an unrelated label. The change above makes it a
  known family, which is what the projection needs.

## 5. Implementation steps

1. `label_rules.ex` (PROPOSED): `parse/1` (`"feature:" <> slug`, downcased,
   C6-T01 slug rule), `reconcile_registry/2` (§4.2), `decide/4` (§4.3),
   `settle_ms/0`. Pure; returns a list of actions (`{:add, …}`, `{:remove, …}`,
   `{:put, key, entry}`, `{:recheck, at, n}`, `{:conflict, …}`,
   `{:unregistered, …}`).
2. `label_projection.ex` (PROPOSED): `start_link(opts)` with injectable
   `:tracker` (defaults to calling `Aiur.Tracker.adapter/0` per write),
   `:features`, `:history`, `:clock`, `:state_path`, `:name`. Defaults are the
   real modules. `init/1`: prefix check (§6), load or rebuild the state file
   (§4.2), subscribe to both signals, schedule the boot pass.
3. Boot pass: `Features.snapshot/1` → `reconcile_registry/2`; then
   `History.snapshot/1` → `decide/4` per row with a `feature:` label or an
   entry. This catches label and registry changes made while the projection
   was down, at zero API cost.
4. `handle_info({:build_order_features_changed, %{changed: ns}})` →
   `snapshot/1` → `reconcile_registry/2` for `ns` → wake the writer.
   `handle_info({:build_order_history_changed, %{changed: ns}})` → `rows/2` for
   `ns` → `decide/4`.
5. Writer (§4.4), `status/0`, `label_states/1`, `mark_labelled/3`, `retry/1`.
6. `src/lib/aiur.ex` `child_specs/1`: add
   `if(recording?, do: Aiur.BuildOrder.Features.LabelProjection)` as the last
   entry of the list, after `if(recording?, do: Aiur.AllowedContributors)`
   (`:499`). It is a leaf: nothing calls it at boot, C6-T04 handles "not
   running", and under `:rest_for_one` its crash then restarts no other child.
   It starts after C6-T01's `Features` and C4-T01's `History`, which sit
   earlier in the list.
7. aiur-build: §4.6 plus the tests in §8.
8. `apis/github.md` paragraph (§7).

## 6. Non-happy paths

- **Capability absence.** Linear answers `:unsupported`: the registry still
  works, `status.tracker = :unsupported`, no writes. Label joins still need
  History rows, which are GitHub-only, so none happen. Memory tracker: writes
  succeed (test double; `memory/tracker.ex:109-119` sends
  `{:memory_tracker_add_label, id, label}`).
- **Prefix collision.** `GitHub.Config.label_prefix() == "feature"`: the
  projection does nothing and reports `:prefix_collision`, because `feature:*`
  would then be state labels.
- **History unavailable or stale (EC-07).** R1: no join, no leave. Writes still
  run, because they do not depend on observation. `status.observation` names the
  state and `observed_at` gives its age. History that is healthy but not
  `complete?` (backfill running) is used: presence is positive evidence, and
  absence is checked per row against `written_at`.
- **Truncated label list.** A backfill row with more than 100 labels has
  `labels_complete: false`; R1b stops absence rules on it.
- **Unknown actor.** The poll and webhook paths do not carry the label
  applier (`normalizer.ex:299-321` drops the sender), so a steady-state label
  join is `label:unknown` with actor `unknown`. It is shown as unknown, never
  as the Executor or the daemon.
- **Concurrent writers (EC-13).**
  - CLI join and a human adding the same label: R5, one write at most (the
    write is idempotent).
  - CLI join to `s` while a human adds `feature:t`: registry wins (owner `s`),
    both labels stay, conflict listed (R6). R3 racing a CLI `add`:
    `{:owned_elsewhere, _}` → conflict, no retry.
  - CLI remove or `--move` while the label is still on GitHub: the
    `:pending_unlabel` tombstone (R7) stops the label from re-joining the
    ticket before the unlabel lands.
  - Human removes the label right after our write: R9 then R8.
  - A human label on a ticket the backfill agent guessed: R6b moves it.
  - Two daemons on one repo are not supported anywhere in Aiur; not handled.
- **Rename** of a GitHub label `feature:a` → `feature:b`: every member of `a`
  loses `feature:a` → R8 leaves (journaled, row rule "removal leaves the
  feature"); `feature:b` is unregistered (R2). Recovery: `aiur feature create b`,
  then R3 joins them with source `label:*`. Listed in `status.unregistered`.
- **Budget (EC-32).** No reads. Writes: one `ensure` per new slug per boot, one
  `POST` per join, one `DELETE` per leave, at most `max_writes_per_minute` per
  minute and 200 per hour. GitHub's secondary limit is 80 content-generating
  requests per minute and 500 per hour (MP-E1 findings F11, docs accessed
  2026-10-06). Worst case with the build queue also writing at 20/min: 40/min,
  under 80/min. The build queue has no hourly cap of its own (MP-E1-C3-T04), so
  the hourly sum is not bounded by this ticket alone (§11 residual). A 60-ticket
  feature takes about 3 minutes; a 1,000-ticket CLI batch about 5 hours.
  Imported and backfill-agent members write nothing.
- **Restart (EC-31).** State is in the file; the boot pass re-derives the rest
  from the registry and History. The buckets restart full; that is at most one
  extra window.
- **Lost or corrupt state file.** Quarantined and rebuilt (§4.2); `status/0`
  answers `{:error, :projection_state_unavailable}` until the rebuild ends.
- **Untrusted text.** A label name is data. Only `feature:` + a slug that
  passes C6-T01's rule is acted on; anything else is ignored. A login from a
  label event that fails C6-T01's source regex is replaced by `unknown`.
- **Security.** Writes use the daemon's own write identity, never a pooled
  read credential (`apis/github.md:457-468`). No new token handling. The state
  file is mode `0600`.

## 7. Compatibility and rollout

- No new config key (pacing reuses `build_queue.max_writes_per_minute`). No
  migration: the state file is new, and the first boot builds it from the
  registry, so CLI joins made before this ships start `:pending_label`.
- Rollback: remove the child and delete `label-projection.json`. Labels already
  written stay on GitHub and are harmless.
- Docs: one short paragraph in `website/docs-app/apis/github.md` "Changes Aiur
  makes itself" (`:695`), after its opening paragraphs (`:697-701`; the table
  there lists situations, not writers): "Feature labels: Aiur writes
  `feature:<slug>` when a ticket joins a feature through the CLI or an agent,
  and removes it when the ticket leaves. Paced at
  `build_queue.max_writes_per_minute` and at most 200 an hour. A label a person
  adds or removes is read from the normal poll and webhook data and recorded as
  a join or a leave; Aiur makes no extra read for it." The CLI page is C6-T04's;
  the concept page is C12-T07's.

## 8. Verification

Test files (PROPOSED): `src/test/aiur/build_order/features/label_rules_test.exs`
and `label_projection_test.exs`. The projection test uses an in-test fake
tracker (records calls, returns scripted results), fake `:features` and
`:history` modules, an injected clock and a `:state_path` under
`System.tmp_dir!/0` per test. No real HOME, ledger or token.

| Test | Expected | Fails without |
| --- | --- | --- |
| R1 "unknown labels decide nothing" — row `labels: :unknown`, entry `:labelled` | `decide/4` returns `[]` | the R1 clause (treating `:unknown` as `[]` gives a remove) |
| R1b "truncated labels never leave" — `labels: ["agent:done"]`, `labels_complete: false`, entry `:labelled`, clock past settle | `[]` | R1b (without it, R8 removes) |
| R3 "label joins with label source" — event `%{label: "feature:auth", action: :labeled, at: t0, actor: "kev"}` | `{:add, "auth", [12], source: "label:kev", actor: "kev", at: t0}` | R3 |
| R3 "unknown actor stays unknown" — no event | `source: "label:unknown"`, `actor: "unknown"`, `at: row.observed_at` | the unknown branch (mutation: replace with `"label:executor"` must fail) |
| R2 "unknown slug never creates a feature" | no add; `{12, "zzz"}` in unregistered | R2 |
| R6 "label for another feature is a conflict" — owner `s` confirmed | no add, no remove | R6 |
| R6b "human label replaces a backfill guess" — owner `s`, `backfill-agent`, `confirmed: false`, label `feature:t` | `{:add, "t", [12], move: true, source: "label:…"}` | R6b (without it, R6 gives a conflict) |
| R7 "tombstone blocks a re-join" — no owner, entry `:pending_unlabel`, label present | `[]` | R7 (without it, R3 re-joins) |
| R9/R8 "absence inside settle waits, after settle leaves" — row `observed_at` at `written_at+30 s`, then `+130 s` | first `[{:recheck, …}]`, then `{:remove, …}` | the settle guard |
| R8 "label-joined member leaves when the label goes" — entry `:labelled`, `written_at: nil`, `seen_at: t0`, row at `t0+130 s` lacks the label | `{:remove, …}` | the `written_at \|\| seen_at` fallback (nil arithmetic raises) |
| R5 "exempt stays exempt" — entry `:exempt`, label present | entry still `:exempt` | the exempt clause in R5 |
| `reconcile_registry` "sources pick the start state" — owners from `cli:x`, `label:y`, `import:build-order`, `backfill-agent` | `:pending_label`, `:labelled`, `:exempt`, `:held_backfill` | each source clause (mutation: map `backfill-agent` to `:pending_label` → a write is planned and fails) |
| "held backfill join is released only by mark_labelled" — owner `backfill-agent`, entry `:held_backfill`, label present on the row | writer makes no call; entry still `:held_backfill`; `mark_labelled("s", 12, %{written_at: nil, seen_at: t})` → `:ok`, entry `:labelled`; a second call → `{:error, :not_held}`; for a non-member → `{:error, {:not_member, [12]}}` | the held clause in R5 and `mark_labelled/3` |
| `reconcile_registry` "remove and move leave a tombstone" — entry `{a, 12}` `:labelled`, owner now `b` | `{a, 12}` → `:pending_unlabel`; `{b, 12}` → `:pending_label` | the "not `s`" clause |
| "registry join writes the label once, then echo marks labelled" | one `add_label("12", "feature:auth")`; after the History echo, entry `:labelled`, no second call | the writer; R5 |
| "ensure runs once per slug per boot" | one `ensure_labels(["feature:auth"])` for two joins | the per-boot set |
| "pacing: 30 pending at 20/min" | 20 calls, then 10 after the clock passes 60 s | the minute bucket |
| "pacing: 250 pending stop at 200 in an hour" — `max_writes_per_minute` 60, clock advanced 1 min at a time | 200 calls by minute 4, none more until the hour passes | the hour bucket |
| "local_hold pauses writes" — fake returns `{:error, {:github, :local_hold, %{}}}` | `status.writes == :paused`; no further calls until the tick; attempts unchanged | the pause branch |
| "a held ensure pauses, not fails" — ensure returns `{:error, {:github_api_status, 429, "feature:auth"}}` five times | `:paused`; attempts 0; entry not `:failed` | the ensure clause of the pause row |
| "five failures → failed; retry resets" — `{:error, {:github, :http, %{status: 500}}}` | `:failed` after 5; `retry/1` → `:pending_label` | the counter |
| "404 on add fails at once" | `:failed` after one call | the 404/410 row |
| "import source is exempt" (C6-T03 V-15 reuses it) | no tracker call for an `import:build-order` owner | the exempt state |
| "Linear: unsupported stops the writer" | `status.tracker == :unsupported`; entries stay pending | the unsupported branch |
| "prefix collision" — prefix `feature` | no subscription, `:prefix_collision` | the init check |
| "state survives restart" — write `:labelled`, stop, start with the same `:state_path` | entry `:labelled`, no tracker call | the save after outcome |
| "corrupt state is rebuilt, not empty" — file `"{not json"`, owner `cli:x`, History row with the label | file quarantined as `*.corrupt-*`; entry `:labelled`; no tracker call | the rebuild (mutation: start with `%{}` → a `POST` is made) |
| "lost tombstone rebuilt from the journal" — no file, no owner, journal `member.removed` source `cli:x`, History row still has the label | entry `:pending_unlabel`; one `remove_label` | the journal step |
| "status with unreadable registry is an error, not zero" | `{:error, :registry_unavailable}` | the error branch (mutation: return `pending: 0` must fail) |
| `test/aiur/application_test.exs` "label projection follows recording and comes after its sources" | in `modules(AiurApp.child_specs(recording?: true, …))` after `Aiur.BuildOrder.Features` and `Aiur.BuildOrder.History`; absent with `recording?: false` | the gate and the placement |

aiur-build:

| Test | Expected | Fails without |
| --- | --- | --- |
| `tests/test_github_reconciliation.py` "rejects unprojected feature labels" — append `feature:other` to observed BO-001 | error "unexpected observed labels for BO-001" | `"feature"` in `routing_prefixes` |
| same file, "accepts a projected feature label" — `feature:auth` in `required_ticket_labels` and in both label maps for every runnable ticket | clean | regression guard only; passes on main, named so |
| `tests/test_github_projection.py` "feature:todo is not a second lifecycle todo label" — `example()`, append `feature:todo` to `required_ticket_labels` | no "exactly one lifecycle todo label" error (main reports it, because `lifecycle_todo_prefix/1`, `validation_header.py:181-193`, sees two `*:todo` prefixes) | `"feature"` in `RESERVED_ROUTING_PREFIXES` |

Mutation check (AGENTS.md): in a worktree, with `git status --porcelain`
showing only the revert, remove each production hunk named in "Fails without"
and confirm its test fails; restore and confirm all pass. Record the commands in
the PR body.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/build_order/features/label_rules_test.exs \
  test/aiur/build_order/features/label_projection_test.exs \
  test/aiur/application_test.exs
python3 -m unittest discover -s .claude/skills/aiur-build/scripts/tests \
  -p 'test_github_reconciliation.py'
python3 -m unittest discover -s .claude/skills/aiur-build/scripts/tests \
  -p 'test_github_projection.py'
```

Then the full suite on CI for the head SHA (a new supervised child).

Manual check (not UI, so the AGENTS.md TUI recipe does not apply; run by the
Executor from the repo root, not from an agent workspace, because `--test` is
blocked there): on the sandbox repository under `scripts/aiurdev --test`, run
`aiur feature add` (once C6-T04 exists) and confirm the label on GitHub with
`gh issue view`; add `feature:<slug>` by hand to another sandbox issue and
confirm the join after one poll in `aiur feature show <slug> --json`. Record
the API calls with `aiur github-cost` before and after; the PR states the count
and claims no saving.

## 9. Pixel parity

Not applicable. This ticket renders nothing, and the design has no label
concept: `features`/`addF` (`build.js:117-121`) hold `key, label, hue, epics,
from, to` only. The values it produces reach the screen through C6-T05
(feature figures) and C10-T03 (feature header), which carry the C1-T02
side-by-side screenshot checks. No C1-T02 or C1-T03 script is added here.

## 10. Decisions made without the owner

1. **Observe through History, not a new poll consumer.** C4-T03 already merges
   the poll, webhook deposits and our own write-through into version-guarded
   rows, including closed issues. A third consumer in `record_open_issues/3`
   would repeat that and miss closed issues. Cost: C4-T01 and C4-T03 become
   blockers, which the README row does not list.
2. **This ticket also removes labels** for registry leaves and moves. Without
   it, a CLI remove is undone at the next poll by R3. The row names only the
   write.
3. **No timeline read for the label applier.** The source is `label:<login>`
   when History knows the actor (C4-T02 backfill), else `label:unknown`. A read
   per join would be a new read path with its own cache rules
   (`DispatchAuthorization` keeps a private timeline cache for this,
   `github/dispatch_authorization.ex:9-46`). Revisit if Kevin wants the login.
   C6-T01 has no field for "join time is approximate"; a label join with no
   event uses `row.observed_at` as `at`, and the journal's `recorded_at` stays
   the record time.
4. **A label never creates a feature and never moves a confirmed member**
   (R2, R4, R6). Plan §10 item 14: no silent tagging. The Executor resolves
   conflicts with C6-T04. The one exception is R6b, which C13-T04 item 4
   assigns to this ticket: a human label replaces an unconfirmed backfill
   guess.
5. **Pacing reuses MP-E1's `max_writes_per_minute`** with a separate bucket,
   instead of a new config key, plus a fixed 200/hour cap so this writer alone
   stays well under GitHub's 500/hour.
6. **Settle window 120 s** before a confirmed absence leaves a member.
7. **Projection state lives in this ticket's own JSON file, not on the C6-T01
   record.** C6-T01's API (§4.4 there) has no projection field and keeps no left
   members, and its journal is strict and fsynced per call; writing attempts and
   `seen_at` there would churn it. A crash cannot make the two disagree for
   long: `reconcile_registry/2` re-derives every entry from the registry on
   boot, and both GitHub calls are idempotent. C6-T04 reads `label_states/1`
   instead (return note in §11).
8. **aiur-build treats `feature:` as a routing family** (strict), instead of
   leaving it ignored. One owning feature per ticket makes an unprojected
   feature label real drift.
9. **`backfill-agent` joins are held (`:held_backfill`) and other unconfirmed
   joins are exempt** (C13-T04 item 4); only C13-T02 releases a held join;
   `inherited:parent` joins (options §2.4 table, a live join from now on) get a
   label.
10. **`:auth` errors pause writes** instead of counting attempts, so a bad token
    does not mark every pending item `:failed` after five ticks.

## 11. Completion and handoff

- [ ] R1–R11 (with R1b, R6b) and `reconcile_registry/2` implemented in
      `LabelRules` with the tests in §8.
- [ ] Projection supervised last and gated; writes paced (minute and hour),
      ensured, budget-paused; state file saved after every outcome.
- [ ] Every "Fails without" test fails with its hunk reverted (PR body lists
      each, with the command).
- [ ] `status/0` and `label_states/1` never report 0 or `:ok` for something
      they could not read; `mark_labelled/3` is the only exit from
      `:held_backfill`.
- [ ] aiur-build family change and tests; note in the PR that these tests are
      not in CI (no file under `.github/` or `scripts/` names `aiur-build`).
- [ ] `apis/github.md` paragraph.
- [ ] PR body: request counts per join and per leave, no saving claimed.
- Dependents: C6-T04 (shows `status/0` and `label_states/1`, calls `retry/1`),
  C13-T02 (`label_states/1`, `mark_labelled/3`), then C5-T04, C12-T07,
  C13-T04; C6-T03 V-15 reuses "import source is exempt".
- C6-T04 label state: Settled 2026-10-08: C6-T04 reads
  `LabelProjection.label_states/1` (`{:error, _}` or not running → `"unknown"`).
- C4-T01 event name: Settled 2026-10-08: `label_events` with `actor`.
- Sources: options.md §2.2, §2.4, §2.8; plan.md §6, §8 (EC-07, EC-13, EC-31,
  EC-32), §10 item 14; MP-E1 findings F10, F11; MP-E1-C3-T01 (key table),
  MP-E1-C3-T04 (write protocol, ensure); C13-T04 item 4; decisions E8-D11.

## Review log (adversarial review, 2026-10-08)

Checked against `runtime/src` at `58854d4c8`, the C6-T01, C6-T03, C6-T04,
C4-T01, C4-T02, C4-T03, C13-T04, MP-E1-C3-T01 and MP-E1-C3-T04 ticket docs,
tickets/README.md, chunks.md and `build.js`.

1. **Wrong blocker.** `max_writes_per_minute` is defined by MP-E1-C3-T01, not
   C3-T07 (restart recovery). Front matter and §2 changed.
2. **Interface did not match C6-T01.** C6-T01 has `add/3`/`remove/3` with
   number lists, `{:owned_elsewhere, _}` errors, a
   `{:build_order_features_changed, _}` message, no `put_projection/3`, no
   `feature?/1` and no left members. §4.1 now cites C6-T01 §4.4 as written,
   and the projection state moved to this ticket's own file (§4.2, decision 7)
   with a registry reconcile and a rebuild path (corrupt file, lost
   tombstones from `journal/2`).
3. **C13-T04 contract missed.** `backfill-agent`/unconfirmed joins now start
   `:exempt` (was `:pending_label`), and R6b lets a human label replace an
   unconfirmed guess, as C13-T04 item 4 assigns to this ticket.
4. **Health type.** History health is `ProviderHealth` (`:healthy`, …), not
   `:ok`. R1 gates on `state`, not `usable?/1`, which would block until the
   backfill completes. `status.observation` carries the real state.
5. **Truncated labels.** Added R1b: no absence rule on `labels_complete: false`.
6. **R8 with `written_at: nil`** (label-joined members) was undefined; now uses
   `written_at || seen_at`, with a test.
7. **R5 on `:exempt`** would have made imported members leave on label
   removal; exempt now stays exempt.
8. **Hourly limit.** GitHub's secondary limit is also 500/hour (MP-E1 F11);
   added a 200/hour bucket, a test and a residual note.
9. **Ensure errors.** `Labels.ensure/5` returns `{:github_api_status, …}` /
   `{:github_api_request, …}`, not `{:github, kind, _}`; a rate-limited ensure
   would have burned attempts. Pause row extended; `:auth` pauses too.
10. **404/410 shape** stated (`{:github, :http, %{status: _}}`).
11. **Supervision placement.** "Directly after C6-T01's child" under
    `:rest_for_one` would restart unrelated children on a crash; now last in
    the list. Application test now uses `child_specs/1` (the file's pattern)
    and checks order, instead of `which_children` on a test singleton where
    recording is off.
12. **aiur-build test.** The `feature:todo` test was in the wrong file
    (`test_schema.py` has no lifecycle tests) and its "only `feature:todo`"
    fixture was not the behaviour the change adds; moved to
    `test_github_projection.py` with `agent:todo` + `feature:todo`.
13. **Docs target.** The "Changes Aiur makes itself" table lists situations,
    not writers; the doc change is now a paragraph.
14. **Citations corrected:** `issue_state.ex:38-61`, `labels.ex:24/:34/:92-97/
    :158-194`, `errors.ex:26-27/:90-91/:104-125`; added `aiur.ex:125`,
    `fs.ex:19`, `json_store.ex:44-61`, `lifecycle.ex:46-51`,
    `application_test.exs:174-205`. Label event field name difference
    (C4-T01 vs C4-T02) noted with a return note.
15. Added the C6-T04 return note (`label_states/1`), more tests (R1b, R6b, R8
    nil, exempt R5, reconcile sources and tombstones, hour bucket, ensure
    pause, 404, restart, corrupt rebuild, journal tombstone), and the manual
    check's "Executor from repo root" rule.

Residual risks: the build queue and this writer share GitHub's 500/hour limit
with no joint cap; C6-T04 must switch to `label_states/1`; the History label
event field name is not settled between C4-T01 and C4-T02; whether `POST
.../issues/:n/labels` creates a missing label is still unverified (ensure is
kept).
- Reconciliation 2026-10-08 (coordinator): `backfill-agent` joins start `:held_backfill` (not `:exempt`), released only by the new `mark_labelled/3` for C13-T02 (§4.2, R5, R11, rebuild, §4.5, tests); History field is `label_events` with `actor`; C4-T01 and C6-T04 return notes marked settled.
