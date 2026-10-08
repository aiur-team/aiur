---
ticket_id: MP-E8-C6-T01
feature_id: MP-E8
chunk_id: MP-E8-C6
bucket: 2-platform
title: Feature registry and membership journal
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C5-T01]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-24, EC-13]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C6-T01 — Feature registry and membership journal

> Cites code at `origin/main` `58854d4c8` (runtime worktree
> `aiur-worktrees/runtime/src`). Paths marked PROPOSED do not exist yet. If MP-R1
> has moved `build_order/` before this starts, re-resolve the symbols below
> (CR-E8-6 places this store in `build-orders`). `J` = `design-source/assets/build.js`,
> `C` = `design-source/assets/build.css`.

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C6
  (features), ticket T01. The first C6 ticket; T02–T05 build on its API.
- **User value.** A feature is a named package of tickets that grows over time
  (E8-D2). Today the only feature-like thing is a Build Order root (baseline §5:
  8 roots, 116 members), and nothing records when a ticket joined or whether it
  was original or added scope. This store is the system of record (options F-C)
  for features, their epics, one owning feature per ticket (E8-D11), "also
  affects" links, the original-scope baseline, and who changed what and when.
- **Deliverable.**
  - PROPOSED `src/lib/aiur/build_order/features.ex`: a GenServer that keeps an
    append-only, fsynced journal (one NDJSON file) and a folded in-memory
    projection, with a validated write API, a snapshot read and a PubSub change
    signal. It stores no label projection state: C6-T02 keeps that in its own
    file (§2 note 2).
  - PROPOSED `src/lib/aiur/build_order/features/journal.ex`: record encode,
    strict decode/validate (the replay validator), and the fold.
  - `Aiur.Config.Paths.build_features_state_dir/0` (one new function).
  - One child line in the application tree; one line in the test boot guard.
- **Non-goals.**
  - No `feature:` labels, no GitHub calls (C6-T02).
  - No Build Order import (C6-T03), no CLI (C6-T04), no statistics (C6-T05).
  - No epic resolution (C5-T02 owns the rule; this store only supplies the
    owning feature's epic).
  - No feature suggestions (plan §10 item 14, options §2.4): membership changes
    only through explicit calls.
  - No delete-feature operation, no feature-epic removal (see §10).
  - No UI and no config key.

## 2. Dependencies and blockers

- **Blocked by DESIGN-E8.** The only design input is the feature hue: the design
  assigns hues by hand (`addF`, `J:118`). OQ-E8-6's written default (a stable
  hash of the slug into the hues the general epics leave free, overridable) is
  followed; it is not a blocker (tickets/README.md rules). Kevin's answer may
  reopen §4.5.
- **Predecessor: C5-T01** (see interface note 1). This ticket needs only one
  thing from C5: the configured general
  epics' **keys and hues**, which C5-T01 gives as `settings.build_order.epics`
  (in `Aiur.Config.Schema.BuildOrder`), a
  list of `%Aiur.Config.Schema.BuildOrderEpic{key, label, labels, hue, icon}` read
  from `Aiur.Config.settings/0` (C5-T01 §4.4; C5-T01 adds no accessor function).
  This store uses them to refuse a feature-epic key that collides with a general
  epic and to keep auto hues away from general hues. C5-T02's resolver takes this
  store's owner answer as a plain-map argument and does not call this store
  (C5-T02 §2 "Input producers", lines 68-80, already agrees).
- **Successors that consume this interface:** C6-T02 (label projection:
  `add/3`, `remove/3` with `label:<login>` sources, `snapshot/1`, `journal/2`,
  `subscribe/0`), C6-T03 (import: `create/3` with
  `from:`/`to:` (dates or `:unknown`), `add/3` with historical or `:unknown`
  `at:`, `update_feature/3` with epic relabels, `journal/2`), C6-T04 (CLI: every
  write, `snapshot/1`, `journal/2`),
  C6-T05 (stats: `snapshot/1` owners, `added?`, also links, `journal/2` for the
  daily scope series), C8-T04 (subscribes; reads `snapshot/1`), C13-T04 (batch
  writes with `source: "backfill-agent"`, `confirmed: false`), C13-T03 (adds
  `Features.confirm/3` to this module in its own PR).
- **Contracts:** none shared. CR-E8-6 (placement in `build-orders`) is filed by
  C3-T01.
- **Concurrent with:** C5-T03, C4-T02..T05, C7, all client tickets (different files).

### Interface notes for neighbour rows

Checked against the neighbour ticket files as written on 2026-10-08.

1. **C5-T02 ↔ C6-T01 order.** Settled 2026-10-08: `blocked_by` is relaxed to
   C5-T01; C5-T02 takes this store's owner record as a plain input, so C5-T02
   and C6-T01 run in parallel.
2. **C6-T02 projection state.** Settled 2026-10-08: C6-T02 owns it in its own
   file (`label_states/1`, `mark_labelled/3`); this store keeps none and has no
   `put_projection`. It gives C6-T02 `memberships/1` (current owners),
   `{slug, n}` pairs in the change signal and an optional `at_basis` on
   `add/3` (§4.4). Name mapping for C6-T02: `join` =
   `add/3`, `leave` = `remove/3`, `feature?(slug)` = `Map.has_key?(snapshot.features,
   slug)`; `{:error, :owned_by_other, s}` = `{:error, {:owned_elsewhere, [{n, s}]}}`.
3. **C6-T03 requests 1-4** (C6-T03 §2 lines 89-104). Settled 2026-10-08: all
   four are in this ticket: `at: :unknown`, `from`/`to: :unknown`; epic
   relabels through `update_feature/3`; `journal/2` events that carry their
   record's `source`, `actor`, `recorded_at` and `seq`; and the explicit
   epic-update rule (an `add/3` on a ticket the same feature owns with a
   different `epic:` updates the epic and keeps `joined_at`, §4.4).
4. **C6-T04 names.** C6-T04 §2 says it adapts to this store's names. Mapping:
   `Features.create/2` = `create/3`; `Features.apply(slug, op, ids, meta)` =
   `add/3` / `remove/3` / `also/3` (each all-or-nothing); `set_baseline(slug,
   actor, replace?)` = `set_baseline/2` with `replace:` in meta; `get/1`, `list/0`
   = `snapshot/1`; C6-T04's `{:error, :unavailable}` = this store's `{:error,
   %ProviderHealth{}}`. C6-T04 decision 8 declines a rename verb, so EC-24
   "renamed" is reachable through `update_feature/3` from C6-T03 (a root title
   change) and the API only. Settled 2026-10-08: C6-T04 keeps its `edit` verb.
5. **C13-T04 G-3** (C13-T04 lines 578-579: a backfill re-add would downgrade a
   human-confirmed member). Fixed here, at the data owner: an unconfirmed write
   never replaces a confirmed membership (§4.3). C13-T04 needs no extra guard in
   `add/3` for this case.
6. **Also-links and backfill.** Settled 2026-10-08: also-links carry no
   `confirmed` flag, and a backfill also-link is refused (C6-T04 refuses `also`
   with `backfill: true`; this store also refuses `also/3` with
   `source: "backfill-agent"`, §4.4).

## 3. Verified starting point (`58854d4c8`)

Current behaviour: no module named `Aiur.BuildOrder.Features` exists; `grep -rn
"feature:" lib/aiur/build_order/` finds nothing. `Aiur.BuildOrder.Member`
(`lib/aiur/build_order/member.ex:1-40`) is a Build Order *root member* record
and is unrelated; the new module must not reuse that name.

| What | Where | Use here |
| --- | --- | --- |
| Append + fsync before ack, owner-only file, symlink refusal | `lib/aiur/decision_log.ex:127` `append/2` (raw fd, `:file.sync`, `chmod 0600` on first create), `:209` `reject_symlink/1` | Every journal write |
| Directory and file preparation with one filesystem barrier | `lib/aiur/decision_log.ex:46` `prepare/3` | Boot |
| Replay with torn-tail truncation and a strict validator | `lib/aiur/decision_log.ex:162-166` `replay/2,3` (`max_file_bytes`, `max_record_bytes`; returns the validated prefix plus `{:corrupt, line, reason}`) | Boot |
| Replay result shapes (map each one, §4.6) | `lib/aiur/decision_log.ex`: a symlinked file → `{:error, {:symlink_rejected, path}}` (`:209-214`; `prepare/3` returns the same for a symlinked dir, `:67-70`); file over `max_file_bytes` → `{:error, :recovery_file_too_large}` (`:198-205`); a record over `max_record_bytes` and any validator `{:error, reason}` → `{:ok, prefix, {:corrupt, line, reason}}` (`:266-278`, reason `:record_too_large` or the validator's reason); a torn tail is truncated and fsynced before decoding (`:189-194`) | The store tells these apart by the returned reason, not by a separate API |
| Test injection precedent | `lib/aiur/recent_merge_store.ex:65-72` `persistence_options/1`: `append_fun` (default `&DecisionLog.append/2`), `filesystem_sync_fun`, `alert_fun` (default `&Alerts.emit_custom/3`); `start_link/1` `:24-26` takes `name:` (nil allowed) | Same option names here, plus `clock:` |
| Journal-store precedent | `lib/aiur/recent_merge_store.ex`: `state_dir/1` `:89`, `boot/2` `:96`, `replay/2` `:105`, `apply_corruption/2` `:158-170` (read-only on interior corruption, alert), `unavailable_state/3` `:172`, `emit_alert/3` `:359` (`Alerts.emit_custom/3`, `lib/aiur/alerts.ex:114`) | Copied shape. One difference: this store does not serve the validated prefix as if it were current (§4.6) |
| State dir resolution | `lib/aiur/config/paths.ex:61` `decision_state_dir/0` (instance- and project-scoped, fails closed); `:99-110` `progress_retention_state_dir/0` (app-env override, then a leaf) | `build_features_state_dir/0` copies `:99-110`, leaf `build-features` |
| Health struct | `lib/aiur/build_order/lifecycle.ex:1-63` `Aiur.BuildOrder.ProviderHealth` (`state`, `complete?`, `generation`, `observed_at`, `last_success_at`, `failure`); `new/4` `:31`; `usable?/1` `:46-51` is `true` only for `:healthy`, `complete?: true` **and an integer generation > 0**; `normalize_generation/1` `:53-54` turns `0` into `:unknown` | The store's health, as C4-T01 does, so C8-T04 handles it like other Build Order sources. Because of `:46-51`, an empty store reports generation 1, not `:unknown` (§4.2) |
| PubSub signal | `lib/aiur/build_order/pack_status.ex:51` `@topic`, `:79` `subscribe/0`, `:226-228` `broadcast_changed/1` (guards on `Process.whereis(Aiur.PubSub)`) | Same shape |
| Application tree | `lib/aiur.ex:429` `Aiur.RecentMergeStore`, `:447` `Aiur.ProgressRetention`, `:452` `{Aiur.BuildOrder.TicketHistoryProvider, runtime_config?: true}` | New child just before `:452` (after C4-T01's `Aiur.BuildOrder.History` if that has landed) |
| Test isolation | `test/support/test_support.exs:167` `tmp_root!/1`; `test/support/test_boot_guard.exs:36-45` (every derived state-dir resolver must resolve under the test root; `:39` `:progress_retention_state_dir`); `test/aiur/recent_merge_store_test.exs:9,375` (`state_dir:`, `filesystem_sync_fun: fn -> :ok end`) | Test setup; add the new resolver to the guard list |
| Paths tests | `test/aiur/config_paths_test.exs` | One new test |

Design data this store must be able to feed (no pixels, but the fields must exist):

- `J:117-121` `features[k] = {key, label, hue, epics: [epic keys], from, to}`;
  each feature epic is `{key, label, hue: <feature hue>, icon: "layers", feature: k, temp: true}`.
- `J:124` and `J:131-132`: the design's feature hues
  `175, 55, 285, 128, 232, 18, 330, 80, 250, 150` (dense set) and `150`, `272`
  (Khala, Events pagination). `J:95-96`: general epics on hues `38, 312, 200, 100`,
  with the comment "general epics on 4 well-separated hues; features take the rest".
- `J:186-187`: every ticket has `feature` (owning feature key or null), `epic`
  (a feature-epic key when owned), `also` (list of feature keys); planned rows
  carry `added` (`J:260`, `J:276`).
- `J:291`: feature-epic columns are ordered by feature `from` (start time).
- `J:343-352` `featStats`: needs owners, `added`, and also-links (C6-T05 ports it).
- Hue consumers: `--h` (`J:786`, `J:822`), `--ft` (`J:823`), `--fh` (`J:875`),
  the sparkline stroke and chips `oklch(.68 .14 <hue>)`, `oklch(.7 .13 <hue>)`
  (`J:1084-1086`), and `C:102-108, 238, 271-273, 756` `oklch(.66 .14 var(--fh|--ft))`.
  A hue is a unitless number of degrees.

## 4. Chosen design

### 4.1 Model

```elixir
# PROPOSED Aiur.BuildOrder.Features.Feature
%{slug: "events-pagination",          # immutable key; ^[a-z0-9][a-z0-9-]{0,41}$
  label: "Events pagination",          # 1..80 chars, valid UTF-8, no control chars
  hue: 272,                            # integer 0..359
  hue_source: :auto | :explicit,
  epics: [%{key: "f-pag-api", label: "Pagination · API"}, ...],  # >= 1, ordered
  from: ~U[...] | :unknown,            # start; default created_at; C6-T03 passes root createdAt or :unknown
  to: :none | :unknown | ~U[...],      # end; :none = open; :unknown = closed at an unknown time
  baseline: :none | %{at: ~U[...], members: MapSet.t(pos_integer())},
  public_ref: :none | "MP-E8",         # E8-R1; ^MP-(E|N)[0-9]+$
  created_at: ~U[...], updated_at: ~U[...]}

# Owner membership, keyed by issue number (one per ticket, E8-D11)
%{feature: slug, epic: epic_key, joined_at: ~U[...] | :unknown,
  at_basis: :claimed | :first_observed,   # C6-T02 R3; default :claimed
  source: "cli:executor", actor: "its-everdred", confirmed: true}

# Also-affects links: %{issue_number => MapSet.t(slug)}   (no confirmed flag)
```

No label projection state is stored here; C6-T02 owns it in its own file.

`:unknown` times are stored as unknown and never replaced by "now" (options §2.5
"It must never guess"; C6-T03 request 1). Readers order a feature with
`from: :unknown` after the dated ones (C8-T04 decides the column order, `J:291`).

Derived (not stored): `added?(number)` is `true` only when the owning feature has
a baseline and the number is **not** in `baseline.members`. With
`baseline: :none` it is `false`, and the snapshot carries `baseline: :none` so
the header can say "no baseline" (C6-T05/C10-T03). A ticket that was in the
baseline, left, and came back is still original. This rule needs no join-time
comparison, so historical `at:` values from C6-T03 cannot misclassify it.

Invariants (checked by property test V-12):
1. A ticket has at most one owner.
2. An owner's `epic` is one of its feature's `epics` keys.
3. A ticket never has an also-link to its own owning feature.
4. Feature-epic keys are unique across all features and never equal
   `unsorted`.
5. (Write time only.) A new feature-epic key never equals a general epic key in
   the **current** config. This is not checked on replay: config can change after
   the write (an operator adds a general epic `api`), and a config change must not
   turn a valid journal into a corrupt one. A later collision is resolved by the
   C5-T02 precedence (feature epic first) and is not this store's error.

### 4.2 Journal

File: `<build_features_state_dir>/features.ndjson`, mode `0600` (set by
`DecisionLog.append/2`). One record per accepted **call**, so a batch is atomic:
the crash barrier is the single fsynced line.

```json
{"v":1,"seq":42,"recorded_at":"2026-10-08T10:00:00Z","source":"cli:executor",
 "actor":"its-everdred","events":[
   {"type":"member.removed","feature":"auth-v2","number":2750,"at":"2026-10-08T10:00:00Z","reason":"move"},
   {"type":"member.added","feature":"events-pagination","number":2750,"epic":"f-pag-api",
    "at":"2026-10-08T10:00:00Z","confirmed":true}]}
```

Event types: `feature.created`, `feature.updated` (label, hue, from, to,
public_ref, epic relabels), `feature.epic_added`, `member.added`,
`member.removed` (`reason`: `"remove"` or `"move"`), `also.added`,
`also.removed`, `baseline.set`. `member.added` on a
ticket the same feature already owns with a different `epic` or `confirmed` is an
update of that membership (it keeps the original `joined_at`). Unknown times are
the JSON string `"unknown"`; the strict validator accepts that string and an
ISO-8601 UTC time, nothing else.

`seq` starts at 1 and increases by 1 per record. Replay checks that `seq` is
contiguous; a gap or a repeat is corruption. The **generation** is `seq + 1` of
the last record, so an empty store is generation 1 and the first write makes it
2. Reason: `ProviderHealth.usable?/1` (`lifecycle.ex:46-51`) is false for a
generation of `:unknown` or 0, so a fresh install would otherwise read as
unusable, and C8-T04 would show "features unavailable" instead of the truthful
"no features".

### 4.3 Sources and actors

`source` is required on every write and is one of:
`cli:<who>`, `agent:<ticket-number>`, `label:<login>`, `inherited:parent`,
`import:build-order`, `backfill-agent`
(`^(cli|agent|label|inherited|import):[A-Za-z0-9._\-\[\]]{1,64}$|^backfill-agent$`).
`actor` is a required string of 1..100 valid UTF-8 characters. `confirmed`
defaults to `true`, except `source: "backfill-agent"` defaults to `false`
(C13-T04, S-8); a caller may pass it explicitly. The store never invents an
actor; C6-T04 decides what string a CLI call records. `label:unknown` is valid
(C6-T02 uses it when History has no label actor).

**An unconfirmed write never replaces a confirmed membership** (C13-T04 G-3). A
re-add with `confirmed: false` on a ticket the same feature owns with
`confirmed: true` keeps `true` (and is a no-op if nothing else changed). A
`move: true` with `confirmed: false` on a ticket whose current owner is
confirmed is refused as `{:error, {:owned_elsewhere, [{n, slug}]}}`, as if
`move` were not given. Confirming (`false` → `true`) is always allowed.

### 4.4 Public API (PROPOSED)

All writes are `GenServer.call` with a 60 s timeout, validate everything before
appending anything, and return the new generation plus what changed. A call
that changes nothing appends nothing.

```elixir
@type meta :: [source: String.t(), actor: String.t(), at: DateTime.t() | :unknown,
               at_basis: :claimed | :first_observed, confirmed: boolean(),
               server: GenServer.server()]
@type result :: {:ok, %{generation: pos_integer(), changed: [pos_integer()], slugs: [String.t()],
                        pairs: [{String.t(), pos_integer()}]}}
              | {:error, reason :: term()}

create(slug, %{label: _, hue: _ | nil, epics: [%{key, label}] | nil,
               from: DateTime | :unknown | nil, to: DateTime | :unknown | nil,
               public_ref: _ | nil}, meta) :: result
#   epics nil -> [%{key: "f-" <> slug, label: label}]   (design single-epic form, J:128)
#   hue nil   -> auto hue (4.5); from nil -> created_at; to nil -> :none
#   general epics unreadable (Config.settings/0 error) -> {:error, :epic_config_unavailable}
update_feature(slug, %{optional label, hue, from, to, public_ref,
                       epics: [%{key, label}]}, meta) :: result   # EC-24 rename
#   epics here relabels existing keys only; an unknown key -> {:error, {:unknown_epic, key}}
add_epic(slug, %{key, label}, meta) :: result      # same config check as create
add(slug, [pos_integer()], meta ++ [epic: key, move: boolean()]) :: result
#   epic default: the feature's first epic
#   a number owned by another feature -> {:error, {:owned_elsewhere, [{n, other_slug}]}}
#   unless move: true (one record: member.removed reason "move" + member.added),
#   and never over a confirmed owner when this write is unconfirmed (4.3)
#   an also-link from n to slug is dropped in the same record (invariant 3)
#   n already owned by slug with a different epic: an epic update; joined_at kept
#   (the explicit epic-update rule, C6-T03 request 4)
remove(slug, [pos_integer()], meta) :: result          # numbers not owned by slug -> {:error, {:not_member, [n]}}
also(slug, [pos_integer()], meta ++ [remove: boolean()]) :: result
#   n owned by slug -> {:error, {:owner_cannot_also, [n]}}
#   source "backfill-agent" -> {:error, :backfill_also_refused} (C6-T04, C13-T04)
set_baseline(slug, meta ++ [replace: boolean()]) :: result   # snapshot of current owners
#   an existing baseline without replace: true -> {:error, {:baseline_exists, at}}
# confirm/3 is added by C13-T03 in its own PR (R-G4)

# Reads
snapshot(opts) :: {:ok, %{features: %{slug => feature}, owners: %{n => owner},
                          also: %{n => [slug]}, generation: g, health: ProviderHealth.t()}}
                | {:error, ProviderHealth.t()}
owner(n, opts) :: {:ok, %{feature: slug, epic: key, added?: boolean(), confirmed: boolean()}}
                | :none | {:error, ProviderHealth.t()}
memberships(opts) :: {:ok, [%{slug, number, source, joined_at, confirmed}]}
                   | {:error, ProviderHealth.t()}
#   current owners only
journal(slug, opts) :: {:ok, [event]} | {:error, ProviderHealth.t()}
#   oldest first; each event carries its record's seq, recorded_at, source, actor
#   (C6-T03 request 3); C6-T05 scope series
health(opts) :: ProviderHealth.t()

# Signal: topic "build-order-features:changed"
# {:build_order_features_changed, %{generation: g, changed: [n], slugs: [slug], pairs: [{slug, n}]}}
subscribe() :: :ok
```

Limits: at most 1,000 numbers per call (`{:error, :batch_too_large}`); a number
is a positive integer below 2^31; an unknown slug is `{:error, {:unknown_feature,
slug}}`; an unknown epic key is `{:error, {:unknown_epic, key}}`; `at` more than
5 minutes in the future (by the injected `clock:`) is `{:error, :at_in_future}`.
A record whose encoded line is over `@max_record_bytes` is `{:error,
:record_too_large}`, and one that would take the file over `@max_file_bytes` is
`{:error, :features_too_large}`; both are checked **before** the append, because
`DecisionLog.replay/3` would reject either one at the next boot and make the
whole store unreadable. A 1,000-number call is about 300 KB, under the 1 MB cap.
The store does not check that an issue number exists on GitHub (no GitHub call);
C6-T04 may.

### 4.5 Hue (OQ-E8-6 default)

```elixir
@design_feature_hues [175, 55, 285, 128, 232, 18, 330, 80, 250, 150, 272]  # J:124, J:131-132
@general_gap 15   # degrees kept clear of each configured general epic hue

auto_hue(slug, general_hues, open_feature_hues):
  candidates = @design_feature_hues |> reject(within @general_gap of any general hue)
  candidates = if candidates == [], do: @design_feature_hues, else: candidates
  start = :binary.decode_unsigned(binary_part(:crypto.hash(:sha256, slug), 0, 4)) |> rem(length(candidates))
  first candidate from start (wrapping) not in open_feature_hues, else candidates[start]
```

The hue is computed once at `create/3` and stored, so it never changes when other
features open or close. "Open" means `to == :none`. An explicit `hue:` is any
integer 0..359 and is stored with `hue_source: :explicit`. Every listed design
feature hue is at least 17° from each default general hue (`38, 312, 200, 100`;
the closest pair is 55 and 38), so with default config all 11 candidates stay
available. General hues come from `settings.build_order.epics` (C5-T01, read
through `Aiur.Config.settings/0` at each `create/3`; passed as
`opts[:general_epics]` in tests). If the settings cannot be read, `create/3`
and `add_epic/3` return `{:error, :epic_config_unavailable}`: they never fall
back to the default general epics (C5-T01 handoff 4; C8-T04 applies the same
rule).

### 4.6 Health states

| Situation | `ProviderHealth` | Reads | Writes |
| --- | --- | --- | --- |
| No file, or an empty file (new install) | `:healthy`, `complete?: true`, generation 1, `observed_at` = boot replay time (`usable?/1` is true) | `{:ok, …}` with empty maps (a truthful "no features registered") | accepted |
| File replayed cleanly | `:healthy`, `complete?: true`, generation = last `seq` + 1 | `{:ok, …}` | accepted |
| Torn tail (crash mid-append) | truncated by `DecisionLog.replay/3`, then as above | `{:ok, …}` | accepted |
| Corruption at any complete line (`{:corrupt, line, reason}` with a reason other than the two below: bad JSON, invalid record, `seq` gap, invariant broken on fold) | `:structurally_invalid`, `failure: :features_corrupt`; alert `build_features.corrupted` | `{:error, health}` | `{:error, :features_corrupt}` |
| Record with `v` > 1 (`{:corrupt, line, :version_unsupported}`) | `:unavailable`, `failure: :version_unsupported`; file untouched (a newline-terminated file; a torn tail is still truncated first, `decision_log.ex:189-194`) | `{:error, health}` | `{:error, :version_unsupported}` |
| State dir unresolved or not preparable; symlinked file or dir (`{:error, {:symlink_rejected, _}}` from `prepare/3` or `replay/3` → `:unsafe_path`) | `:unavailable`, `failure: :state_dir_unavailable` / `:unsafe_path`; alert `build_features.unavailable` | `{:error, health}` | refused with the same atom |
| File over `@max_file_bytes` (16 MB, `{:error, :recovery_file_too_large}`) or a record over `@max_record_bytes` (1 MB, `{:corrupt, line, :record_too_large}`) | `:structurally_invalid`, `:features_too_large` | `{:error, health}` | refused |
| Append failed (disk full, EIO, fsync error) | the call returns `{:error, {:journal_append_failed, reason}}`; projection is **not** changed; health turns `:stale`, `failure: :journal_append_failed`, alert `build_features.unavailable` | `{:ok, …}` with the last acknowledged state and that `:stale` health (`usable?/1` false, so C8-T04 marks it) until restart | `{:error, :journal_append_failed}` until restart |
| Store not running | `:unavailable`, `failure: :features_not_running` | `{:error, health}` | `{:error, :features_not_running}` |

Unlike `RecentMergeStore`, a corrupt journal does not serve its validated
prefix: a prefix silently drops later moves and removals, so it would show a
ticket in the wrong feature as if current. The file is never rewritten or
quarantined automatically; it is the only record of provenance. Recovery is an
operator step (§7).

Why an append failure stops writes until restart: `DecisionLog.append/2`
(`decision_log.ex:127-145`) can fail **after** bytes reached the file (a short
write, or `:file.sync` failing after `:file.write` succeeded). The file may then
hold a partial line or a complete record the caller was told failed. A retry
would append after a partial line (one corrupt line on the next boot) or reuse
the same `seq` (a repeat, also corruption). Replay at the next start is the only
safe judge of what the file holds, so the store refuses writes until then
(a supervisor restart is enough; C6-T04 tells the operator).

`health.observed_at` is the `recorded_at` of the last record;
the renderer shows its age (AGENTS.md "A computed age is rendered").

## 5. Implementation steps

1. `lib/aiur/config/paths.ex`: add `build_features_state_dir/0` after
   `progress_retention_state_dir/0` (`:99-110`): app-env key
   `:build_features_state_dir`, else `Path.join(decision_state_dir, "build-features")`.
2. `test/support/test_boot_guard.exs`: add `:build_features_state_dir` to the
   derived resolver list (`:36-45`, next to `:progress_retention_state_dir` at
   `:39`). The resolver nests under `decision_state_dir`, which the guard already
   requires inside the test root, so no other test setup changes; the guard entry
   makes the suite fail if the store ever resolves outside it.
3. PROPOSED `lib/aiur/build_order/features/journal.ex`:
   - `encode/1` (record map → JSON map, `DateTime.to_iso8601/1`, `MapSet` → sorted list).
   - `validate/1`: the replay validator. Strict: unknown keys, `null`, wrong
     types, invalid UTF-8, an unknown event `type`, a bad slug/epic/source, or
     `v` ≠ 1 → `{:error, reason}` (`v` > 1 → `{:error, :version_unsupported}`).
     `null` is never accepted; a time is an ISO-8601 UTC string or
     `"unknown"`.
   - `fold/2` (projection, record → `{:ok, projection} | {:error, {:invariant, which}}`).
     The write path and replay use the **same** fold, so a record that would
     break an invariant can never be written, and one written by a buggy older
     build is caught on replay. Invariant 5 (general-key collision) is a
     write-handler check only, never part of `fold/2` (§4.1).
4. PROPOSED `lib/aiur/build_order/features.ex` (GenServer):
   - `init/1`: resolve the dir (`opts[:state_dir]` else
     `Paths.build_features_state_dir/0`); `DecisionLog.prepare/3`;
     `DecisionLog.replay(path, &Journal.validate/1, max_file_bytes: @max_file_bytes,
     max_record_bytes: @max_record_bytes)`; fold every record and check `seq`;
     set health per §4.6; on corruption or unavailability emit the alert with
     `Alerts.emit_custom/3` as `recent_merge_store.ex:359` does.
   - Write handlers: refuse in a non-writable state; validate arguments; build
     the event list from the current projection; return `{:ok, unchanged}` with
     no append when the list is empty; else fold into a candidate projection
     (invariant check), `DecisionLog.append/2` the record, and only on `:ok`
     replace the projection, bump the generation and broadcast.
   - `general_epics` come from `opts[:general_epics]` or, in production,
     `Aiur.Config.settings/0` → `settings.build_order.epics` (C5-T01 §4.4; keys
     and hues only). An `{:error, _}` from settings → `{:error,
     :epic_config_unavailable}` for `create/3` and `add_epic/3` (§4.5).
   - Options, named as in `recent_merge_store.ex:65-72`: `state_dir:`, `name:`,
     `append_fun:` (default `&DecisionLog.append/2`), `filesystem_sync_fun:`,
     `alert_fun:` (default `&Alerts.emit_custom/3`), plus `clock:` (default
     `&DateTime.utc_now/0`) for `recorded_at`, defaults and the future-`at`
     check, and `general_epics:` (a 0-arity fun returning `{:ok, [%{key, hue}]} |
     {:error, _}`; default reads `Aiur.Config.settings/0`; tests pass a fun).
   - Before the append, check the encoded line size and the resulting file size
     against the caps (§4.4 limits). After a failed append, set the store
     unwritable (§4.6).
   - Reads go through the mailbox (one consistent copy). Client functions catch
     `:exit` for a missing server and return the not-running health.
     ponytail: no ETS mirror; reads are rare (CLI, C8-T04 on a change signal).
     Add one if C12-T06 measures call latency above 5 ms.
   - `broadcast/1` guarded by `Process.whereis(Aiur.PubSub)` (`pack_status.ex:226-228`).
5. `lib/aiur.ex`: add `Aiur.BuildOrder.Features,` before
   `{Aiur.BuildOrder.TicketHistoryProvider, runtime_config?: true}` (`:452`),
   with one comment line: "Durable feature registry and membership journal (MP-E8)."
6. Tests (§8). No other file changes.

Expected size: `features.ex` about 300 lines, `journal.ex` about 300 lines
(unknown times and relabels add about 100 lines over the row's scope;
complexity stays 3).
ponytail: no journal compaction. At about 300 bytes per membership event, 16 MB
holds about 50,000 events; the backfill of 1,300 tickets (C13) uses about 3 %.
Add compaction to a snapshot file if a census shows the file above 4 MB.

## 6. Non-happy paths

- **Concurrent writers (EC-13).** One GenServer serializes every write. Two
  agents adding the same ticket to two features: the first wins; the second gets
  `{:error, {:owned_elsewhere, [{n, slug}]}}` and nothing is written, unless it
  passed `move: true`, in which case the last write wins and both are in the
  journal with their source and actor (V-5). A label added on GitHub during a
  registry join reaches this store as an ordinary `add/3` from C6-T02, so it is
  serialized the same way.
- **Idempotency.** Re-adding an owner with the same epic and `confirmed`, removing
  a non-owner also-link, or creating a feature that exists with identical fields
  appends nothing and does not bump the generation (V-6). Creating a slug that
  exists with different fields is `{:error, {:feature_exists, slug}}`.
- **Partial batch.** A batch with one bad number (`0`, owned elsewhere, too many)
  writes nothing (V-4).
- **Crash during a write.** The record is fsynced before the projection changes
  and before the caller is answered; a crash before the fsync leaves at most a
  torn tail, which replay truncates, and the caller saw no `:ok` (V-9).
- **Disk full.** `append` returns an error; the projection stays as it was, so
  memory never claims a change the disk lacks, and the store refuses further
  writes until restart, so a partial line is never followed by another record
  (V-10). Restart replays and truncates a torn tail (V-9).
- **Corrupt or newer file.** Reads are errors, never empty maps (V-7, V-8).
  An unknown is never shown as "no features" or "not in a feature".
- **Untrusted text.** Labels and actors come from CLI arguments, agents and
  GitHub logins. The store validates UTF-8, length and control characters only;
  escaping is the renderer's job (EC-30). The file is owner-only under the
  owner-only decision dir, and `DecisionLog` refuses symlinks (V-11).
- **Historical times.** C6-T03 passes `at:` from `SubIssueAddedEvent.createdAt`.
  The journal keeps `recorded_at` (now) and `at` (claimed) apart, so provenance
  is not rewritten.
- **EC-24 cases owned here:** added scope after the baseline (`added?` true, V-3);
  no baseline (`baseline: :none`, `added?` false, V-3); renamed (`update_feature/3`
  changes the label, the slug and every membership stay, V-13); only also-affects
  members (a feature with zero owners is valid, V-14); more than six features
  (no limit; auto hues still assigned, V-2). "Focus with no loaded tickets" is
  C10-T03's.
- **Budget (EC-32).** This ticket makes no GitHub call.

## 7. Compatibility and rollout

- No config key, no CLI flag, no operator env var: no docs change is required in
  this ticket (AGENTS.md "Docs ship with the change"). C6-T04 documents the CLI.
- No migration: the file is new, version 1.
- The child starts in every daemon and stays idle (one empty map) until C6-T02,
  T03 or T04 writes.
- **Recovery from a corrupt journal** (written into the C6-T04 docs, not here):
  stop the daemon, move `features.ndjson` aside, restart, re-run the C6-T03
  import and the C6-T02 label reconciliation. Provenance after the corrupt line
  is lost; the moved file keeps it for inspection.
- Rollback: remove the child line. Nothing else reads the file.

## 8. Verification

PROPOSED test file `src/test/aiur/build_order/features_test.exs` (`async: false`,
store started per test with `state_dir:` from `Aiur.TestSupport.tmp_root!/1`,
`filesystem_sync_fun: fn -> :ok end`, `general_epics:` the C5 defaults, `name: nil`,
a fixed `clock:`, and `alert_fun:` that sends to the test process).
No test touches `~/.aiur` or the real decision dir.

| # | Test | Expected | Fails without |
| --- | --- | --- | --- |
| V-1 | "state survives a restart" | create 2 features, add 5 tickets, also-link 1, baseline; stop; start on the same dir → `snapshot` equal field by field, same generation | replay and fold |
| V-2 | "auto hue is a design feature hue, stable, and avoids open features" | `create("a", %{label: "A"})` hue ∈ `[175, 55, 285, 128, 232, 18, 330, 80, 250, 150, 272]`; the same slug in a fresh dir gets the same hue; 11 features get 11 distinct hues; a 12th gets its hashed hue; `hue: 7` is stored as 7 with `:explicit` | `auto_hue/3` (mutation: return `0` → fails; drop the open-hue skip → the distinct check fails) |
| V-3 | "added scope is relative to the baseline set" | add #1 #2, baseline, add #3 → `owner(3).added? == true`, `owner(1).added? == false`; remove #1 and add it again → still `false`; a second feature with no baseline → all `false` and `snapshot.features[slug].baseline == :none` (not `%{members: []}`) | the `added?` rule (mutation: `added?` = `joined_at > baseline.at` makes the rejoin case fail; defaulting a missing baseline to an empty set makes every member `added?` and fails) |
| V-4 | "one owner per ticket; a batch is atomic" | #5 owned by `a`; `add("b", [4, 5])` → `{:error, {:owned_elsewhere, [{5, "a"}]}}`; #4 has no owner; journal line count unchanged | validate-all-before-append and invariant 1 |
| V-5 | "move journals the leave and the join with provenance" | `add("b", [5], move: true, source: "agent:2750", actor: "its-applekid")` → owner `b`; `journal("a")` ends with `member.removed` reason `move`, `journal("b")` with `member.added`, both carrying source and actor | the move path |
| V-6 | "a no-op write appends nothing" | repeat V-5's call → `changed: []`, same generation, file bytes unchanged, no broadcast received | the empty-event short circuit |
| V-7 | "a corrupt journal reads as an error, not as empty" | write two valid lines then `{"v":1,"seq":3,"bogus":1}` → `snapshot` is `{:error, %ProviderHealth{state: :structurally_invalid, failure: :features_corrupt}}`; `owner(1)` is `{:error, _}`, not `:none`; `add/3` is refused; file bytes unchanged; alert fun called once | the corruption branch (mutation: serve the prefix as healthy → `owner(1)` returns a value and fails) |
| V-8 | "a newer version is left untouched" | a newline-terminated file whose second record has `"v": 2` → `:version_unsupported`; after stop the file bytes equal the originals | the version check |
| V-9 | "a torn tail is dropped, earlier records kept" | valid lines plus a partial line with no newline → healthy, earlier state present, partial line gone | `DecisionLog.replay/3` use (a custom reader that treats the tail as corruption fails) |
| V-10 | "append failure leaves the projection unchanged and stops writes" | `append_fun: fn _, _ -> {:error, :enospc} end` → `add/3` returns `{:error, {:journal_append_failed, :enospc}}`; then `owner(n)` is `:none` and `health().state == :stale`, `failure: :journal_append_failed`; a second `add/3` is `{:error, :journal_append_failed}` and `append_fun` was called once; restart on the same dir with the real append → `:healthy` | ordering of append before projection swap (mutation (d): swap first → `owner(n)` returns the owner and fails); the stop-on-failure rule (mutation: stay writable → `append_fun` is called twice and fails) |
| V-11 | "a symlinked journal or state dir is refused" | `features.ndjson` symlinked to a temp file → unavailable `:unsafe_path`; target unchanged after a write attempt; and `state_dir` itself a symlink to a temp dir → unavailable `:unsafe_path`, nothing created in the target | symlink refusal and the `{:symlink_rejected, _}` mapping |
| V-12 | "invariants hold under random operation sequences" (StreamData, 200 runs of 1–40 ops over 3 features and 10 tickets) | after every op: ≤ 1 owner per ticket; owner epic ∈ feature epics; no also-link to the owning feature; replaying the file reproduces the same snapshot | the shared fold + invariant check |
| V-13 | "rename keeps slug and members" | `update_feature("a", %{label: "Auth v3"})` → label changed, slug `a`, owners unchanged, `feature.updated` in the journal | `update_feature/3` |
| V-14 | "a feature with only also-affects members is valid" | create `c`, `also("c", [7, 8])` → `snapshot.also[7] == ["c"]`, no owner for 7; `also("a", [1])` where `a` owns #1 → `{:error, {:owner_cannot_also, [1]}}` | also handling and invariant 3 |
| V-15 | "epic key collisions are refused" | `create("x", %{epics: [%{key: "bugs", label: "B"}]})` → `{:error, {:epic_key_taken, "bugs"}}`; `"unsorted"` too; a key used by another feature too | invariant 4 |
| V-16 | "input validation" | slug `"Bad Slug"`, a 43-char slug, label with `\n`, `hue: 360`, `public_ref: "X-1"`, `source: "web"`, number `0`, 1,001 numbers, `at` 10 min ahead, `also/3` with `source: "backfill-agent"` (`:backfill_also_refused`) → each its specific error; nothing appended | the validators |
| V-17 | "backfill-agent defaults to unconfirmed and never downgrades" | `add(..., source: "backfill-agent")` → `owner.confirmed == false`; re-add with `confirmed: true` → `true`, `joined_at` unchanged, one `member.added` update record; then a `backfill-agent` re-add → still `true`, `changed: []`, no record; a `backfill-agent` `add("b", [n], move: true)` → `{:error, {:owned_elsewhere, [{n, "a"}]}}` | the `confirmed` default, update rule and no-downgrade rule (mutation: let the re-add write `confirmed: false` → the third step fails) |
| V-18 | "reads without a running store are unavailable" | `owner(1, server: :missing)` → `{:error, %ProviderHealth{failure: :features_not_running}}` | the not-running clause (mutation: return `:none` → fails) |
| V-19 | "change broadcast" | subscribe; `add("a", [3, 9])` → `{:build_order_features_changed, %{changed: [3, 9], slugs: ["a"], pairs: [{"a", 3}, {"a", 9}], generation: g}}` with `g` = previous + 1 | the broadcast |
| V-20 | "a write the next boot could not replay is refused" | start with `max_record_bytes: 2_000` (test override); a `create` whose label makes the line longer → `{:error, :record_too_large}`, file bytes unchanged; with `max_file_bytes:` set to the current size + 10 → `{:error, :features_too_large}`; restart → healthy | the pre-append size checks (mutation: drop them → the restart is `:features_too_large`/corrupt and fails) |
| V-21 | "unknown times stay unknown" | `create("bo-1", %{label: "R", from: :unknown, to: :unknown})`, `add("bo-1", [4], at: :unknown, source: "import:build-order", actor: "import")`; restart → `features["bo-1"].from == :unknown`, `.to == :unknown`, `owners[4].joined_at == :unknown`; the file holds `"unknown"`, not a time | unknown handling (mutation: default `:unknown` to `clock.()` → fails) |
| V-22 | "memberships lists current owners after a leave and a restart" | `add("a", [6, 7])`; `remove("a", [6])`; restart → `memberships/1` is exactly `[%{slug: "a", number: 7, …}]`; `add("a", [7], epic: "f-a2")` (second epic) → epic updated, `joined_at` unchanged | `memberships/1` and the epic-update rule (mutation: keep left members in `memberships/1` → fails; reset `joined_at` on an epic update → fails) |
| V-23 | "journal events carry provenance; epic relabel keeps keys" | after V-5's calls, every `journal("b")` event has `seq`, `recorded_at`, `source: "agent:2750"`, `actor: "its-applekid"`; `update_feature("a", %{epics: [%{key: "f-a", label: "A · core"}]})` → epic label changed, key and owners unchanged; an unknown key → `{:error, {:unknown_epic, "f-x"}}` | provenance on events; relabel |
| V-24 | "a baseline is not replaced by accident" | `set_baseline("a")` twice → second `{:error, {:baseline_exists, at}}`, one `baseline.set` record; with `replace: true` → new baseline | the `replace:` guard |
| V-25 | "a later general epic does not corrupt the journal" | create feature with epic `f-api`; restart with `general_epics:` that now includes key `f-api` → healthy, feature intact; a new `create` with epic `f-api` elsewhere is still `{:error, {:epic_key_taken, "f-api"}}` | invariant 5 is write-time only (mutation: check it in `fold/2` → restart is `:features_corrupt` and fails) |
| V-26 | "a fresh store is usable and empty, not unknown" | fresh dir → `ProviderHealth.usable?(health())` is `true`, generation 1, `snapshot` `{:ok, %{features: %{}, owners: %{}}}`; `create` with `general_epics` reader returning `{:error, :invalid}` → `{:error, :epic_config_unavailable}`, nothing appended | generation 1 for an empty store (mutation: `:unknown` → `usable?` false, fails); no default-epic fallback |

Add to `test/aiur/config_paths_test.exs`: "build_features_state_dir honours the
app-env override, else nests under the decision dir" — fails without the new
function.

**Mutation check (AGENTS.md).** In a worktree, with `git status --porcelain`
showing only the intended revert: (a) serve the corrupt prefix as healthy → V-7
fails; (b) compute `added?` from `joined_at > baseline.at` → V-3 fails; (c) skip
the owner check in `add/3` → V-4, V-12 fail; (d) swap the projection before the
append → V-10 fails; (e) make the not-running read return `:none` → V-18 fails;
(f) make `auto_hue` return `0` → V-2 fails; (g) check invariant 5 inside `fold/2`
→ V-25 fails; (h) report generation `:unknown` for an empty store → V-26 fails;
(i) keep left members in `memberships/1` → V-22 fails; (j) let an
unconfirmed re-add write `confirmed: false` → V-17 fails; (k) remove the
pre-append size checks → V-20 fails. Restore; all pass. Record each command
in the PR body.

Command (isolated HOME and no GitHub tokens, memory note "mix test clobbers
agent-token"):

```bash
env -C /path/to/checkout/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/build_order/features_test.exs test/aiur/config_paths_test.exs
```

Then the full suite on CI for the head SHA (the new child is in the
supervision tree and the boot guard list changes).

**Manual check.** No user-visible behaviour. After `aiurdev build` and restart:
`aiurdev status` shows the daemon up, and the `build-features/` directory exists
under the decision state dir with an empty `features.ndjson` (mode `0600`).

## 9. Pixel parity

This ticket draws nothing, so the C1-T02 side-by-side harness has nothing to
compare for it directly. Parity depends on it in two ways, both checked here
rather than by screenshot:

- **Hue values.** Every feature colour in the design is `oklch(L C <hue>)` with
  the feature hue as a bare number (`C:102-108, 238, 271-273, 756`; `J:786, 822,
  823, 875, 1084-1086`). A stored hue is always an integer 0..359 (V-16), and an
  auto hue is one of the design's own feature hues (`J:124, 131-132`, V-2), so a
  real feature renders in a colour the design already uses. Feature epics take
  the feature's hue (`J:120`); C8-T04 maps it.
- **Field coverage.** C8-T04 maps this snapshot to the design's
  `features[k] = {key: slug, label, hue, epics, from, to}` (`J:119`; `to: :none`
  becomes the design's open end) and to each ticket's `feature`, `epic`, `also`
  and `added` (`J:186-187, 260, 276`). Once C8-T04 lands, the C1-T02 run against
  the real DataSource with a registry seeded from the `live` fixture's two
  features (Khala chat 150, Events pagination 272, created with explicit hues)
  must match the design's feature header, chips and outlines exactly.
- **Epic labels.** The feature header chips print each feature epic's label
  (`J:1086`, `D.epics[k].label`), so epic labels are stored and can be relabelled
  (`update_feature/3`, `epics:`), and the design's single-epic form uses the
  feature label (`J:128`).

Interface notes for neighbour rows are in §2.

## 10. Decisions made without the owner

1. **The journal is the store** (one fsynced NDJSON line per call, folded at
   boot), reusing `DecisionLog` and the `RecentMergeStore` shape, instead of a
   state file plus a separate journal. One file means the state and its
   provenance cannot disagree, and the row's "membership journal" is the same
   data.
2. **One record per call,** so a batch or a move is atomic.
3. **`added?` = not in the baseline set,** not a join-time comparison. A rejoin
   stays original, and historical `at:` values cannot change the answer.
4. **A membership carries its feature epic.** Default: the feature's first epic.
   A feature created without epics gets one, `f-<slug>`, labelled with the
   feature label (the design's single-epic form, `J:128`).
5. **Auto hue** is picked from the design's own feature hues, hashed by
   SHA-256 of the slug, skipping hues within 15° of a configured general epic and
   hues of open features, then stored. This is OQ-E8-6's default made concrete;
   a free hash over 0..359 would produce colours the design never shows.
6. **Slug rule** `^[a-z0-9][a-z0-9-]{0,41}$`: lowercase so `feature:<slug>` labels
   are unambiguous, 42 characters so `feature:<slug>` fits GitHub's label-name
   limit (50 characters; to re-check against GitHub docs in C6-T02). It is a
   subset of C3-T03's URL rule `[A-Za-z0-9._-]{1,64}`. Feature-epic keys use
   `^[a-z0-9][a-z0-9-]{0,63}$`, also a subset.
7. **A corrupt journal makes the store unavailable, not read-only-with-prefix,**
   and is never auto-quarantined. A prefix would show wrong memberships as
   current; the file is the only provenance record.
8. **No delete-feature and no feature-epic removal** in this ticket. Neither is
   in the row, and removal with members raises questions (where do members go)
   that no decision answers. A feature ends by setting `to`.
9. **`confirmed` is stored on owner memberships,** default `false` only for
   `backfill-agent` (C13-T04, S-8 default).
10. **No event-bus publication.** options §2.5 suggested publishing join events on
    the bus; the row does not, and no consumer exists. PubSub signals C8-T04;
    the journal is the record.
11. **No ETS mirror and no compaction** (ponytail comments name the triggers).
12. **The store does not check that an issue number exists.** That needs a GitHub
    read; C6-T04 may check before calling.
13. **Neighbour requests adopted here, not pushed back** (§2 notes 3, 5):
    C6-T03's unknown times, epic relabels, epic-update rule and event
    provenance, and C13-T04's no-downgrade rule. Each is a property of the data
    this store owns. Label projection state is C6-T02's own file (note 2). This
    adds about 100 lines over the row.
14. **Generation = last `seq` + 1** so an empty store passes
    `ProviderHealth.usable?/1` and reads as "no features", not "unknown".
15. **An append failure stops writes until restart**, and reads keep serving the
    last acknowledged state marked `:stale`. A retry after a partial write could
    corrupt the journal or repeat a `seq`.
16. **`set_baseline` refuses to replace an existing baseline without
    `replace: true`.** Replacing silently would turn added scope into original
    scope (C6-T04 already passes `replace?`).
17. **`blocked_by` is C5-T01, not C5-T02** (relaxed 2026-10-08, §2 note 1):
    the only real input is C5-T01's config.

## Completion and handoff

- [ ] `Aiur.BuildOrder.Features` and `Features.Journal` exist; the child is in the
      tree; `build_features_state_dir/0` exists and is in the boot guard list.
- [ ] V-1..V-26 and the paths test pass; mutations (a)–(k) each fail the named
      test; commands recorded in the PR body.
- [ ] Interface notes 1–6 (§2) are settled (2026-10-08); nothing is pending.
- Dependents: C6-T02, C6-T03, C6-T04, C6-T05, C8-T04 (reads `Features.snapshot/1`
  directly, C8-T04 §4 "features" part), C13-T04.
- Docs: none in this ticket (no operator surface); C6-T04 documents the CLI and
  the corrupt-journal recovery.
- Sources: tickets/README.md C6 rows; chunks.md C6; plan.md §3 (E8-Q6, E8-Q14),
  §8 (EC-13, EC-24), §10 items 14 and 22; decisions.md E8-D2, E8-D11, E8-R1;
  questions.md OQ-E8-6, PQ-6, PQ-11; options.md §2.1–2.7; DESIGN-E8 S-8.

## Review log

Adversarial review, 2026-10-08, against the runtime code at `58854d4c8`, the
design source and the neighbour ticket files.

1. §2: corrected the C5-T01 input. `Aiur.Config.Schema.BuildHistory` does not
   exist in C5-T01; it is `settings.build_order.epics`
   (`%Aiur.Config.Schema.BuildOrderEpic{}`) from `Aiur.Config.settings/0`, with no
   accessor function. Fixed the same in §4.5 and step 4.
2. Moved the interface notes from §9 (pixel parity) to §2 and rewrote them
   against the neighbour files: C5-T02 already takes the owner answer as an
   argument; added notes for C6-T02, C6-T03, C6-T04 name mapping and C13-T04 G-3.
3. Adopted C6-T02's needs (projection state per `{slug, n}` that survives a
   leave, `put_projection/4`, `memberships/1`, `pairs` in the signal,
   `at_basis`). C6-T02 §4.1 depended on them and the ticket did not offer them.
4. Adopted C6-T03 requests 1-4 (`:unknown` times; epic relabels through
   `update_feature/3`; `seq`, `recorded_at`, `source`, `actor` on each
   `journal/2` event).
5. Added the no-downgrade rule for unconfirmed writes (C13-T04 G-3) and the
   `replace:` guard on `set_baseline`.
6. Generation: an empty store had generation `:unknown`, which makes
   `ProviderHealth.usable?/1` (`lifecycle.ex:46-51`) false, so a new install
   would read as unavailable. The generation is now `seq + 1`.
7. Invariant 4 checked general-epic keys on replay. A later config change would
   then make a valid journal "corrupt". Split it into invariant 4 (replay) and a
   write-time-only invariant 5.
8. An append failure allowed a retry, which can follow a partial line or repeat
   a `seq` (`decision_log.ex:127-145` can fail after bytes reach the file). Writes
   now stop until restart, and reads serve the last acknowledged state as
   `:stale`.
9. Added pre-append size checks. Without them one large write could pass and
   then make the whole store unreadable at the next boot
   (`decision_log.ex:198-205`, `:276-278`).
10. §3 and §4.6: mapped each real `DecisionLog` result shape
    (`{:symlink_rejected, _}`, `:recovery_file_too_large`,
    `{:corrupt, line, :record_too_large | :version_unsupported | _}`) to a health
    state; added the `RecentMergeStore` option names (`:65-72`) and `clock:`;
    corrected the ProviderHealth range to `:1-63`.
11. `null` in the strict validator was rejected outright, which would reject a
    cleared projection; it is now allowed only where §4.1 allows `nil`.
12. `create/2` → `create/3` (arity typo in §2 and §4.5).
13. Tests: V-8 fixture made newline-terminated (a torn tail is truncated even for
    `v: 2`); V-10 rewritten so mutation (d) can be seen; V-11 adds a symlinked
    dir; V-17 adds no-downgrade; V-19 adds `pairs`; added V-20..V-26 and
    mutations (g)-(k).
14. §10 decisions 13-17 added; dependents line corrected (C8-T04 reads the
    snapshot directly, not through C6-T05).

Checked and correct as written: every other cited line (`decision_log.ex:46,
127, 162-166, 209`; `recent_merge_store.ex:89, 96, 105, 158-170, 172, 359`;
`alerts.ex:114`; `paths.ex:61, 99-110`; `pack_status.ex:51, 79, 226-228`;
`aiur.ex:429, 447, 452`; `test_support.exs:167`; `test_boot_guard.exs:36-45, 39`;
`recent_merge_store_test.exs:9, 375`; `member.ex` is the Build Order member), the
`stream_data` test dependency (`mix.exs:160`), and design lines `J:95-96, 116-132,
186-187, 260, 276, 291, 343-352, 786, 822-823, 875, 1084-1086` and
`C:102-108, 238, 271-273, 756`. Every design feature hue is at least 17° from
each default general hue, as stated.

Residual risks: the projection-state shape is owned by C6-T02 and is copied here
for validation, so the two tickets must change together; the README edge
C5-T02 → C6-T01 still serializes the critical path until the Executor relaxes it.
- Reconciliation 2026-10-08 (coordinator): predecessor C5-T02 -> C5-T01 in §2, note 1 and decision 17; removed stored projection state, `projection.set` and `put_projection/4` (C6-T02 owns it); `memberships/1` is current owners only and V-22/mutation (i) rewritten; explicit epic-update rule in `add/3`; also-links have no `confirmed` flag and backfill also-links are refused (V-16); `Features.confirm/3` noted as C13-T03's; config named in `Aiur.Config.Schema.BuildOrder`; interface notes marked settled.
