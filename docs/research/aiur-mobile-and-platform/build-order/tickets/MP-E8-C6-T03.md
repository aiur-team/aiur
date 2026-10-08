---
ticket_id: MP-E8-C6-T03
feature_id: MP-E8
chunk_id: MP-E8-C6
bucket: 2-platform
title: Build Order roots imported as features
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C6-T01, MP-E8-C4-T01, MP-E8-C4-T02]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-24]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C6-T03 — Build Order roots imported as features

> Cites code at `origin/main` `58854d4c8` (runtime worktree
> `aiur-worktrees/runtime/src`). Paths marked PROPOSED do not exist yet. If MP-R1
> has moved `build_order/` before this starts, re-resolve the symbols below
> (CR-E8-6 places `Aiur.BuildOrder.Features` in `build-orders`). `J` =
> `design-source/assets/build.js`.

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C6
  (features), ticket T03.
- **User value.** Today the only named packages of tickets are the 8 Build Order
  roots (3 open) with 116 direct sub-issues (baseline §5 line 371, census of
  1,344 issues). Without this ticket the feature filter, focus and compact modes
  (C10-T03) open on an empty feature list, and `/build-orders/:root_number` has
  nowhere to redirect (C12-T02). With it, every past and future Build Order shows
  as a feature with its members, its lanes as feature epics, and real join times.
- **Deliverable.**
  - PROPOSED `src/lib/aiur/build_order/features/root_import.ex`
    (`Aiur.BuildOrder.Features.RootImport`): a pure planner `plan/3`, a pure
    `slug/1`, and a small GenServer that runs the plan on boot and on each
    History change signal.
  - `Aiur.BuildOrder.Metadata.lane_label/1` (moved from
    `AiurWeb.OperatorControlCenter.BuildOrderEpicIcon.label/1`, which delegates).
  - `Aiur.BuildOrder.CatalogStore.root_label/0` (one public accessor for the
    existing `@root_label`).
  - Tests in PROPOSED `src/test/aiur/build_order/features/root_import_test.exs`
    and additions to the existing `src/test/aiur/build_order/metadata_test.exs`.
- **Scope (README row).** Root → feature (slug, label, from/to, feature epics);
  members from current sub-issue parents; join times from
  `SubIssueAddedEvent.createdAt` (C4-T02 backfill); `build-lane:` slugs become
  feature epics; idempotent re-runs; zero GitHub reads and **zero label writes**.
  Needed for a correct idempotent import, and so in scope: members leave when a
  sub-issue leaves the root, and an operator's removal is not undone.
- **Non-goals.**
  - No `feature:` label writes for imported members (options §2.8
    "Recommended: … no label writes"). C6-T02 already exempts `import:*` sources
    (C6-T02 §4 lines 181-182); this ticket uses such a source.
  - No baseline. Imported features have none (`baseline: :none`), so all members
    count as original and the header says "no baseline" (C6-T01 §4.1, options
    §2.5 "It must never guess").
  - No hue choice: C6-T01's auto hue (OQ-E8-6 default, C6-T01 §4.5) applies.
  - No `build-lane:adhoc` non-members: they are not sub-issues of a root
    (`ad_hoc_source.ex:2-9`), so they are not imported.
  - No grandchildren: Build Order depth is one level below the root (baseline
    line 371, "maximum depth is 1").
  - No feature or epic deletion (C6-T01 §10 item 8 has none).
  - No UI. The route change is C12-T02; the header is C10-T03.

## 2. Dependencies and blockers

- **DESIGN-E8** (the feature shape in `addF`, J:118–121; feature hues, OQ-E8-6,
  default followed).
- **MP-E8-C6-T01** (registry and journal). This ticket uses the API in C6-T01
  §4.4 as written:

  ```elixir
  # C6-T01 §4.4 (PROPOSED), the calls this ticket makes
  create(slug, %{label:, hue: nil, epics: [%{key, label}], from:, to:}, meta) :: result
  update_feature(slug, %{label?, from?, to?}, meta) :: result
  add_epic(slug, %{key, label}, meta) :: result
  add(slug, [n], meta ++ [epic: key, move: boolean()]) :: result   # one epic and one `at` per call
  remove(slug, [n], meta) :: result
  also(slug, [n], meta ++ [remove: boolean()]) :: result
  snapshot(opts) :: {:ok, %{features: %{slug => feature}, owners: %{n => owner},
                            also: %{n => [slug]}, generation: g, health: ProviderHealth.t()}}
                  | {:error, ProviderHealth.t()}
  journal(slug, opts) :: {:ok, [event]} | {:error, ProviderHealth.t()}
  # meta: source: "import:build-order", actor: "import", at: DateTime | :unknown
  # owner: %{feature, epic, joined_at, source, actor, confirmed}
  ```

  **Four things this ticket needs from C6-T01.** Settled 2026-10-08: C6-T01
  provides all four (§11 "Interface mismatches" item 1):
  1. `at: :unknown` on `add/3`, and `from: :unknown`, `to: :unknown` on
     `create/3`/`update_feature/3`. Today `joined_at` and `from` are required
     dates and `from` defaults to `created_at` (the registry write time). Without
     this, an unknown join time or start would be stored as "now", which is the
     guess options §2.5 forbids.
  2. `update_feature/3` accepts `epics: [%{key, label}]` to relabel existing
     epic keys (EC-24 rename). Today only the feature label can change.
  3. Each event from `journal/2` carries its record's `source` and `actor`.
     Today they are on the record, not the event (C6-T01 §4.2). The import needs
     them for the `slug_taken` and "operator removed" rules (§4.3).
  4. `member.added` with a different `epic` is an update (C6-T01 §4.2 already
     says so) and keeps `joined_at`. The import relies on this to move a member
     between epics of the same feature without a new join time.
- **MP-E8-C4-T01** (History store, C4-T01 §4.1–4.4): `snapshot/1`,
  `subscribe/0` with `{:build_order_history_changed, %{generation, changed,
  health}}`, rows with `labels`, `title`, `created_at`, `closed_at`, `parent`
  (`%{owner, repository, number} | :none | :unknown`), `sub_issues_added`
  (`[%{ref, at}] | :unknown`), `timeline_complete`.
- **MP-E8-C4-T02** (backfill: it adds `SUB_ISSUE_ADDED_EVENT` to the timeline
  query and fills `sub_issues_added` on root rows; C4-T02 "Interface
  mismatches" item 5 asks this ticket to list it).
- **Contract with C6-T02 (parallel, not a blocker).** C6-T02 §4 puts a join with
  an `import:*` source in state `:exempt` ("no label write, ever"), test
  "import source is exempt". This ticket's source is `import:build-order`
  (one of C6-T01 §4.3's listed sources), so no extra rule is needed in C6-T02.
- Unresolved research: none. OQ-E8-6 (hue) follows its default.
- **May run concurrently with** C6-T02, C6-T04, C6-T05 (all build on C6-T01;
  separate files).
- **Successor:** C12-T02 (`/build-orders/:root_number` → `/?feature=bo-<n>`,
  which calls `RootImport.slug/1`; C12-T02 §2 lines 65-68).

## 3. Verified starting point (`58854d4c8`)

- **Root rule.** A root is an issue with the `build-order` label:
  `src/lib/aiur/build_order/catalog_store.ex:27` `@root_label "build-order"`;
  `:57-60` filters roots by it (`@root_label in issue_labels`, `:59`). The same
  literal is duplicated in `src/lib/aiur/build_order/github_graph/normalizer.ex:8`
  and the GraphQL filter `github_graph/queries.ex:56`. There is no public
  accessor.
- **Members.** Direct sub-issues. `CatalogStore.member_numbers/1`
  (`catalog_store.ex:235-250`) maps parent → sorted sub numbers from `present`
  `:sub_issue` edges in `Aiur.GitHub.ResourceStore`. That store expires
  (C4-T01 line 30: 72 h), so it cannot give closed history. This ticket reads
  History rows (`parent`), which C4-T02 backfills and C4-T03 keeps live from the
  same `:sub_issue` deposits (C4-T03 line 216, "`:sub_issue` edge → set or clear
  `parent`").
- **Lanes.** `Aiur.BuildOrder.Metadata.parse/1` (`metadata.ex:21-64`) returns
  `lane` from one `build-lane:<slug>` label, else `:unassigned` (also on two
  lanes, `:ambiguous_lane`, via `parse_dimension/7` `:86-96`). Any slug matching
  `^[a-z0-9][a-z0-9-]{0,63}$` is accepted (`:113-119`). Labels are trimmed and
  lower-cased (`:73`). A non-list input (for example `:unknown`) gives
  `:unassigned` (`:76`). `Metadata.lanes/0` (`:66-67`) orders the built-ins.
- **Lane display names.** `AiurWeb.OperatorControlCenter.BuildOrderEpicIcon`
  (`lib/aiur_web/components/operator_control_center/build_order_epic_icon.ex`)
  `@lane_labels` (`:67-79`), `label/1` (`:106-111`; humanises unknown slugs with
  `capitalize_words/1`, `:124-128`; non-binary → `"Unassigned"`, `:111`).
  Callers: the component itself (`:90`) and `build_order_grid_model.ex:218`. A
  module under `lib/aiur/` must not call `AiurWeb` (plan §5 seam; C3-T01 source
  scan).
- **Design feature shape** (J:118–121):

  ```js
  const addF = (k, label, hue, eps, a, b) => {
    features[k] = { key: k, label, hue, epics: eps.map((e) => e[0]), from: a, to: b };
    eps.forEach((e) => epics[e[0]] = { key: e[0], label: e[1], hue, icon: "layers", feature: k, temp: true });
  };
  ```

  Epic keys are global (one `epics` map) and namespaced by feature
  (`"f-khala-srv"`, J:131). Two-part epic labels are `"<name> · <part>"`
  (`"Khala · server"`, J:131; `n + " · API"`, J:128); a single-epic feature's
  epic label is the feature name alone (`[["f-" + k + "a", n]]`, J:128). An open
  feature has `to: Infinity` (J:132).
- **Supervision.** BuildOrder children start in `src/lib/aiur.ex:452-454`
  (`TicketHistoryProvider`, `AdHocSource`, `PackStatus`); C4-T02 adds
  `History.Backfill` after C4-T01's `History` child. The supervisor is
  `:rest_for_one` (`aiur.ex:123-125`, `start_supervisor/2`).
- **Test-env switches.** `config/config.exs:66`
  `config :aiur, :build_order_adhoc_poll?, false` and `:81`
  `:build_order_pack_status_poll?` disable BuildOrder children under `:test`,
  read at `aiur.ex:453-454`; the same pattern is used here.
- **Population (item 5 of "A claimed saving", stated for scale, no saving
  claimed).** 8 roots, 3 open, 116 members, max depth 1 (baseline line 371).

## 4. Chosen design

### 4.1 Mapping

| Feature field | Value | Unknown handling |
| --- | --- | --- |
| `slug` | `"bo-#{root}"` (`RootImport.slug/1`, integer → string) | always known |
| `label` | root `title`, cleaned (§4.2) | `:unknown` or empty after cleaning → `"Build Order ##{root}"` (a name that states only what is known) |
| `from` | root `created_at` | `:unknown` stays `:unknown` (C6-T01 request 1) |
| `to` | root `closed_at`; `:none` (open) → `:none` (C6-T01's open value) | `:unknown` stays `:unknown`, never `:none` |
| lane epics | one per distinct lane of current members, ordered by `Metadata.lanes/0` then alphabetically: `%{key: "f-bo-#{root}-#{lane}", label: "#{label} · #{Metadata.lane_label(lane)}"}` (§4.2 bounds) | `:unassigned` adds no lane epic |
| catch-all epic | `%{key: "f-bo-#{root}", label: label}` (the design's single-epic form, J:128; equal to C6-T01's default `"f-" <> slug`) | holds members with no lane, unknown labels, or a key that does not fit (§4.2) |
| `hue` | `nil` (C6-T01 auto hue) | — |
| member `epic` | its lane epic key, else the catch-all key | C6-T01 invariant 2 needs every owner to have one of its feature's epics, and C5-T02 (lines 208-210) reads the owner epic first, so there is no `nil` epic |
| member `at` | the **latest** `sub_issues_added` entry whose `ref` is this sub in the configured repository | no entry, `sub_issues_added: :unknown`, or `timeline_complete != true` with no entry → `:unknown`; never `created_at`, never now |
| `source` / `actor` | `"import:build-order"` / `"import"` | — |

Why `bo-<n>`: stable across title edits (EC-24 "renamed"), unique per repository,
C12-T02 builds the redirect without a lookup, and it matches C6-T01's slug rule
`^[a-z0-9][a-z0-9-]{0,41}$` (`bo-` plus at most 10 digits for a number below
2^31).

The catch-all epic is created only when a member needs it, or when the root has
no members (C6-T01 `create/3` needs at least one epic). Epics are only ever added
(`add_epic/3`); an epic whose members all left stays (C6-T01 has no epic
removal). A later lane epic is appended, so the order is the creation order, and
the planner compares epic **key sets and labels**, not order (keeps I-1 true).

### 4.2 Bounds on text and keys

C6-T01 refuses a label longer than 80 characters or with control characters
(§4.1) and an epic key outside `^[a-z0-9][a-z0-9-]{0,63}$` (§10 item 6). A GitHub
title can be 256 characters. Without these rules one long root title would make
every run fail on that root.

- `clean(title)`: replace each control character (`\p{Cc}`) with a space,
  collapse runs of whitespace, trim. If longer than 80 graphemes, keep 79 and
  append `…`.
- Epic label: `"#{short} · #{lane_label}"` where `short` is the cleaned title cut
  (same rule) so the whole label is at most 80 graphemes. The lane part is
  never cut.
- Epic key longer than 64 bytes (long lane slug): no lane epic; the member goes
  to the catch-all epic, and the lane is counted in `skipped_lanes`.

### 4.3 Members and plan (pure)

`members(root) = {n | row(n).parent is %{owner, repository} of the configured
repository and number == root}`. A row with `parent: :unknown` is not evidence
either way. A `sub_issues_added` entry for another repository is ignored and
counted in `skipped_cross_repo` (History has rows only for the configured
repository).

```elixir
@spec plan(history :: %{rows: map(), health: ProviderHealth.t()},
           features :: %{features: map(), owners: map(), also: map()},
           journals :: %{slug => [event]}) ::
        %{creates: [map()], updates: [map()], new_epics: [{slug, epic}],
          moves: [{slug, [n], epic, at}], removes: [{slug, [n]}],
          adds: [{slug, [n], epic, at}], also: [{slug, [n]}], also_removes: [{slug, [n]}],
          conflicts: [map()], deferred: [n], skipped_cross_repo: non_neg_integer(),
          skipped_lanes: non_neg_integer()}
```

`journals` holds `journal/2` for each `bo-*` slug in the snapshot (at most one
per root). `adds` and `moves` are grouped by `(slug, epic, at)` because C6-T01
takes one `epic` and one `at` per call.

For each root row (`CatalogStore.root_label() in row.labels`), with
`slug = slug(root)`:

1. **Slug taken.** If `slug` exists and its first journal event
   (`feature.created`) has a source other than `import:build-order`, the import
   does not touch it and records `%{slug, reason: :slug_taken}`.
2. **Feature.** Absent → `creates`. Present with a different label, `from`, `to`
   or epic label → `updates`. A missing epic key → `new_epics`.
3. **Each member `n`**, by its current owner in `features.owners`:
   - none → `adds` (C6-T01 drops an also-link from `n` to `slug` in the same
     record);
   - `slug` with the same epic → nothing (`at` is not compared: C6-T01 keeps the
     first `joined_at`);
   - `slug` with another epic → `adds` (an epic update, C6-T01 request 4);
   - another `bo-m` feature whose owner `source` is `import:build-order` (the
     sub-issue moved between roots) → `moves` when
     `history.health.complete? == true`, else `deferred`;
   - any other feature (CLI, label or agent join, C6-T02/T04, E8-D11) → **not
     moved**: `also` for `slug` unless already linked, and
     `conflicts` gets `%{number, owner, feature: slug}`.
4. **Operator removal wins.** A member is skipped (no add, no also) when the
   latest `member.removed` or `also.removed` event for `n` in `journals[slug]`
   has a source other than `import:build-order`. Without this rule an
   `aiur feature remove` (C6-T04) would be undone on the next History signal.
   A later re-add by the operator clears the skip (the latest event wins).
5. **Leaves.** Only when `history.health.complete? == true` (an incomplete
   History never proves a member left): owners of `slug` with source
   `import:build-order` that are no longer members and are not in `moves` →
   `removes`; also-links to `slug` from numbers that are no longer members →
   `also_removes`. Members with another source are never removed by the import.

A root that loses the `build-order` label is no longer planned: its feature and
members stay as they are, and nothing is journaled (same rule as C6-T02 label
removal: "removal leaves the feature").

### 4.4 Runner (PROPOSED GenServer)

```text
init ─┬─ enabled? false ───────────► :disabled (no subscription)
      └─ subscribe History; schedule :run after 0 ms
:run ─┬─ History {:error, health} ──► {:unavailable, health.failure}; wait for next signal
      ├─ Features or journal {:error, health} ─► {:unavailable, health.failure}; retry in @retry_ms
      └─ ok ─► plan → apply creates, updates, new_epics, moves, removes, adds,
               also, also_removes (in that order)
               ├─ all {:ok, _} ─► {:ok, %{at, roots, added, removed, moved, conflicts,
               │                         deferred, skipped_cross_repo, skipped_lanes, health}}
               └─ first {:error, reason} ─► stop applying; {:partial, reason}; retry in @retry_ms
signal {:build_order_history_changed, _} ─► debounce @debounce_ms → :run
```

- Order: `moves` and `removes` run before `adds`, so a member that left one
  imported feature is not reported as owned elsewhere when the new one adds it.
- A write error (for example `{:owned_elsewhere, _}` or `{:not_member, _}`
  because a CLI write landed between the snapshot and the write, EC-13) stops
  the run. C6-T01 writes nothing for a refused call (C6-T01 §6 "Partial batch"),
  and the next run plans from a fresh snapshot, so a retry is safe (I-1).
- `@debounce_ms 2_000`, `@retry_ms 60_000`. `ponytail:` comment: a full
  snapshot per run is fine for about 10k rows and 8 roots; switch to the changed
  numbers in the signal if C12-T06 measures a cost. First boot makes about one
  `add/3` call per distinct join time (about 116 calls, 116 journal records);
  that is accepted for a one-time import.
- `status/0` returns the last state, including the History `health` it planned
  from, so a stale History shows as stale (EC-07). `slug/1` is public and pure.
- Started in `lib/aiur.ex` after the C6-T01 `Features` child, as
  `{Aiur.BuildOrder.Features.RootImport, enabled?: Application.get_env(:aiur,
  :build_order_root_import_enabled?, true)}`, with
  `config :aiur, :build_order_root_import_enabled?, false` next to
  `config/config.exs:66`. Tests inject `:history`, `:features` and
  `:debounce_ms`.
- Writes go only through C6-T01. Its GenServer serialises them, so the import
  and a CLI call cannot interleave inside one write (EC-13).

### 4.5 Invariants

- I-1 Applying `plan/3` and planning again on the result gives an empty plan
  (idempotent).
- I-2 No GitHub call: the module reads only History and Features. It has no
  `Aiur.GitHub` alias.
- I-3 No label write: every imported join has source `import:build-order`,
  which C6-T02 treats as `:exempt`.
- I-4 An unknown input is stored as `:unknown`, never as a date, `0`, `:none`
  or now.
- I-5 One owner per ticket: the import moves a ticket only between two
  imported features, and only on a complete History.
- I-6 An operator's removal is never undone by the import.

## 5. Implementation steps

1. **Lane label.** Move `@lane_labels` and `label/1`
   (`build_order_epic_icon.ex:67-79`, `:106-111`, `capitalize_words/1`
   `:124-128`) into `Aiur.BuildOrder.Metadata` as `lane_label/1`.
   `BuildOrderEpicIcon.label/1` becomes
   `defdelegate label(lane), to: Aiur.BuildOrder.Metadata, as: :lane_label`. The
   internal call at `:90` keeps working. No output change.
2. **Root label.** Add `def root_label, do: @root_label` to `CatalogStore`.
3. **Planner.** Write `RootImport.slug/1`, `clean/1` (§4.2) and `plan/3`
   (§4.1–4.3). Pure; reads lanes with `Metadata.parse/1`.
4. **Runner.** Write the GenServer (§4.4) and its child spec; add the child to
   `lib/aiur.ex` after `Features`; add the `:test` switch.
5. **C6-T01 items.** Confirm the four items in §2 are in the merged C6-T01
   (they are in its ticket; R-G4 applies if a small gap remains).
6. **Docs.** One paragraph in `website/docs-app/concepts/` (the page C12-T07
   writes for features; until it exists, `concepts/build-orders.md`): "Build
   Order roots appear as features named `bo-<number>`; membership follows
   sub-issues; no labels are written; `aiur feature remove` on an imported
   member is kept." This adds a user-facing behaviour, so it ships with the
   change (AGENTS.md "Docs ship with the change").

## 6. Non-happy paths

| Case (EC) | Input | Behaviour | Test |
| --- | --- | --- | --- |
| History unavailable (EC-07) | `snapshot` → `{:error, %{failure: :history_corrupt}}` | no writes; `status` `{:unavailable, :history_corrupt}` | V-9 |
| History incomplete (EC-24, EC-31) | `complete?: false`, a member's row now `parent: :none`, another moved to root #2600 | no remove, no move (the moved one is `deferred`); adds still applied | V-6 |
| Join time unknown (EC-08) | root row has no `sub_issues_added` entry for #12 | `add` with `at: :unknown` | V-4 (mutation) |
| `sub_issues_added: :unknown` | root row before backfill | every member `at: :unknown` | V-4 |
| Root title unknown or blank | `title: :unknown` or `"  \n"` | label `"Build Order #2573"` | V-2 |
| Long or control-char title (EC-30) | 200-char title with `\t` | label ≤ 80 graphemes ending `…`; epic labels ≤ 80 with the lane part intact; C6-T01 accepts it | V-16 |
| Root open / closed / closed unknown | `closed_at` `:none` / dt / `:unknown` | `to` `:none` / dt / `:unknown` | V-3 (mutation) |
| Renamed root (EC-24) | title changes between runs | same slug; `update_feature` with the new label and epic labels; members untouched | V-7 |
| Only also-affects members (EC-24) | every sub already owned by other features | feature exists with 0 owners, `also` links, conflicts listed | V-8 |
| Owner conflict (EC-13) | #10 owned by `auth` (label join) | #10 stays in `auth`; `bo-2573` gets an also link; conflict reported | V-8 |
| Stale plan (EC-13) | CLI removes #10 from `bo-2573` between snapshot and `remove` | `{:error, {:not_member, _}}`; run stops with `{:partial, _}`; next run is clean | V-17 |
| Operator removed an imported member | journal: `member.removed` #11 source `cli:kevin` | #11 not re-added, not also-linked | V-18 |
| Sub-issue removed | #12 parent 2573 → `:none`, History complete | `remove` from `bo-2573`, journaled once | V-5 |
| Sub-issue moved to another root | #12 parent 2573 → 2600, History complete | one `add(bo-2600, [12], move: true)` (C6-T01 journals the leave and the join) | V-5 |
| Member with no lane | labels `["agent:done"]` | catch-all epic `f-bo-2573` | V-1 |
| Member with two lanes | `:ambiguous_lane` → `:unassigned` | catch-all epic | V-1 |
| Lane slug too long for an epic key | `build-lane:` + 60 chars | catch-all epic; `skipped_lanes` +1 | V-16 |
| Cross-repo sub-issue | `sub_issues_added` ref in another repo | ignored, `skipped_cross_repo` +1 | V-1 |
| `bo-n` slug taken | a CLI feature named `bo-2573` | untouched; conflict `:slug_taken` | V-10 |
| Root label removed | `build-order` gone from root labels | feature unchanged, no journal | V-11 |
| Re-run (idempotent) | same inputs twice | second run: zero state-changing registry calls; journal length unchanged | V-12 |
| Daemon restart (EC-31) | runner restarts | re-plans from stores; no checkpoint needed (I-1) | V-12 |
| Untrusted text (EC-30) | title with `<script>` | stored as data after §4.2 cleaning; escaping is the renderer's job (C8/C9) | V-16 |
| Budget (EC-32) | any run | zero GitHub calls (I-2) | V-13 |

Privacy and permissions: the import is daemon-internal, reads local stores, and
exposes nothing new. Actor `import` is recorded on every journal record.

## 7. Compatibility and rollout

- No config key (the enable switch is an application env for tests, like
  `:build_order_adhoc_poll?`, not an operator setting). No migration: the
  registry is new (C6-T01).
- First boot after release: 8 features and about 116 joins are journaled once.
  Joins before the C4-T02 backfill finishes get `at: :unknown` and keep it
  (C6-T01 keeps the first `joined_at`). To avoid that, the runner treats
  `health.failure == :backfill_pending` like an unavailable History (no writes)
  and waits for the next signal.
- Rollback: drop the child. Imported features stay in the registry, harmless;
  `aiur feature remove` (C6-T04) can clean up members. No GitHub state to undo.
- MP-R1 moves the module with `Features` (CR-E8-6); no interface change.

## 8. Verification

Tests in PROPOSED `src/test/aiur/build_order/features/root_import_test.exs`
(pure `plan/3` unless noted) and `src/test/aiur/build_order/metadata_test.exs`.
Fixture: one root #2573 (`build-order`, title "Paseo pack", created
2026-09-01, open), subs #10 (`build-lane:runtime`, added 2026-09-01T10:00Z),
#11 (`build-lane:dashboard-ui`, added twice: 09-01 and 09-03), #12 (no lane, no
add event), and a `sub_issues_added` entry for #13 in another repository;
closed root #2000 with sub #20 (`build-lane:runtime`); History
`complete?: true`; frozen clock.

| # | Test | Expected | Fails without (mutation) |
| --- | --- | --- | --- |
| V-1 | maps a root to a feature | `creates` has `bo-2573` with epics `f-bo-2573-runtime` "Paseo pack · Runtime", `f-bo-2573-dashboard-ui` "Paseo pack · Dashboard UI", `f-bo-2573` "Paseo pack"; #12 epic `f-bo-2573`; `bo-2000` has `f-bo-2000-runtime`; `skipped_cross_repo: 1` | use the bare lane as key → `runtime` appears in both features and the key assertion fails |
| V-2 | unknown or blank title | label `"Build Order #2573"` for `:unknown` and for `"  \n"` | replace the fallback with `""` or the raw title → fails |
| V-3 | `to` mapping | open → `:none`; #2000 → its `closed_at`; `closed_at: :unknown` → `:unknown` | replace the `:unknown` branch with `:none` → fails |
| V-4 | join time | #10 `at` 09-01T10:00Z; #11 `at` 09-03 (latest); #12 `at: :unknown`; with `sub_issues_added: :unknown` all `:unknown` | replace `:unknown` with root `created_at` or `DateTime.utc_now()` → fails; pick the first entry → #11 fails |
| V-5 | removal and move | #12 parent → `:none` gives `removes: [{"bo-2573", [12]}]`; #12 parent → 2600 (root, owner `bo-2573` source `import:build-order`) gives `moves: [{"bo-2600", [12], "f-bo-2600", _}]` and no remove for #12 | delete step 5 → first case fails; plan a plain add → second case fails |
| V-6 | incomplete History never removes or moves | V-5 inputs with `complete?: false` → no `removes`, no `moves`, `deferred: [12]` | drop the `complete?` guard → fails |
| V-7 | rename | new title → `updates` with the new label and new epic labels, same slug, no member ops | derive the slug from the title → fails; skip epic labels → fails |
| V-8 | owner conflict | #10 owned by `auth` (source `label:kev`) → not in `adds` or `moves`, in `also`, conflict `%{number: 10, owner: "auth", feature: "bo-2573"}` | drop the owner check → #10 in `adds` → fails |
| V-9 | runner, History unavailable | (GenServer, injected fns) no Features call; `status/0` `{:unavailable, :history_corrupt}`; same with `:backfill_pending` | remove the error branch → crash or writes |
| V-10 | slug taken | `bo-2573` exists, first journal event source `cli:kevin` → no ops for it; conflict `:slug_taken` | remove the check → `updates` overwrites the label |
| V-11 | root label removed | no ops for that feature | treat "not a root" as "remove all" → fails |
| V-12 | idempotent | with a real C6-T01 store in a temp dir: run, then `plan/3` on the new snapshot is empty (every list empty); runner run twice → journal length same | remove the "same epic → nothing" comparison → second run journals again |
| V-13 | no GitHub | runner completes with `Aiur.GitHub.ResourceStore` not started; `rg -n "Aiur.GitHub" lib/aiur/build_order/features/root_import.ex` prints nothing | — (guard against a future regression; not counted as coverage) |
| V-14 | `Metadata.lane_label/1` | `"dashboard-ui"` → "Dashboard UI"; `"my-lane"` → "My Lane"; non-binary → "Unassigned"; `BuildOrderEpicIcon.label/1` gives the same | — (guard for moved code; not counted as coverage) |
| V-15 | no label writes | imported owner in a C6-T01 store with source `import:build-order` → C6-T02's projection makes zero label writes (in C6-T02's suite, reusing its "import source is exempt" test) | — (C6-T02 owns the rule) |
| V-16 | text and key bounds | 200-char title with `\t` → label length 80, ends `…`, no `\t`; epic label ≤ 80 ends " · Runtime"; a real C6-T01 `create/3` accepts it; a 60-char lane slug → member in `f-bo-2573`, `skipped_lanes: 1`; title `<script>` stored unchanged | remove `clean/1` → `create/3` returns a validation error → fails |
| V-17 | stale plan | (GenServer, real C6-T01 store) remove #10 via the store after `plan`, before apply → `status/0` `{:partial, {:not_member, [10]}}`; after `@retry_ms` (injected 0) the next run ends `{:ok, _}` | swallow the error and continue → status `{:ok, _}` on the first run → fails |
| V-18 | operator removal wins | `journals["bo-2573"]` ends with `member.removed` #11 source `cli:kevin` → #11 not in `adds`/`also`; with a later `member.added` by `cli:kevin` the skip is cleared | drop step 4 → #11 in `adds` → fails |

Mutation runs follow AGENTS.md: in a worktree, `git status --porcelain` shows
only the reverted hunk, then restore.

Command (isolated HOME, memory note "mix test clobbers agent-token"):

```bash
env -C /path/to/worktree/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/build_order/features/root_import_test.exs \
  test/aiur/build_order/metadata_test.exs
```

Then the CI gate in `CONTRIBUTING.md`. Live check after merge and rebuild:
`aiur feature show --json` (C6-T04) lists 8 `bo-*` features with 116 owned or
also-linked members in total; `RootImport.status/0` conflicts match the
also-linked ones; `aiur github-cost` shows no new caller.

## 9. Pixel parity

This ticket renders nothing. Parity is about **data shape**: the feature and
epics it writes must reach the hook in the shape `addF` builds (J:118–121):
`{key, label, hue, epics:[keys], from, to}` and epics
`{key, label, hue, icon: "layers", feature, temp: true}`, with two-part epic
labels `"<name> · <part>"` and a single-epic label equal to the name (J:128,
J:131). `to: :none` maps to the design's `Infinity` (J:132) in the payload
(C8-T04 maps the C6-T01 snapshot). `from`/`to` `:unknown` must reach C8-T04 as
unknown, not as a date. C1-T02's side-by-side harness checks the result when
C10-T03 renders an imported feature's header and focus columns; that check
belongs to C10-T03. No design element is restyled or invented here.

## 10. Decisions made without the owner

1. **Slug `bo-<root number>`**, not a slug of the title. Stable under renames;
   C12-T02 builds the redirect from it.
2. **Feature label = cleaned root title; lane epic label =
   `"<title> · <Lane label>"`; catch-all epic label = the title**, the design's
   `addF` forms (J:128, J:131). The design shortens the name in two-part epic
   labels ("Khala chat" → "Khala"); the import cannot shorten a title safely, so
   it uses the full cleaned title, cut to fit 80 characters.
3. **No baseline for imported features.** All members are original; the header
   says "no baseline". Guessing a publish moment would invent data.
4. **Join time is the latest `SubIssueAddedEvent` for that sub;** none gives
   `:unknown`. Live additions after the backfill get a real time: C4-T03
   appends each live `:sub_issue` add to the root row's `sub_issues_added`
   (`%{ref, at}`). The
   runner waits for the backfill so first-boot joins are not stuck at
   `:unknown`.
5. **A ticket owned by a non-import feature is not moved;** the root gets an
   also-affects link. Explicit CLI or label joins win over a parent link.
6. **Moves and removals only on a complete History, and only for
   import-sourced members.**
7. **An operator's removal is final for the import** (step 4). The operator can
   re-add the member by hand.
8. **A root that loses its label keeps its feature.**
9. **Members with no lane go to a catch-all epic `f-bo-<n>`,** because C6-T01
   requires every owner to have one of its feature's epics.
10. **Source `import:build-order`, one for all roots.** It is a C6-T01 listed
    source and C6-T02 already exempts `import:*`. The slug names the root, so a
    per-root source adds nothing.
11. **Lane names move to `Metadata.lane_label/1`** so the store side does not
    call `AiurWeb`. The web module delegates; output is unchanged.
12. **Complexity 3, not the row's 2:** a supervised runner, the move and
    operator-removal rules, text bounds and the conflict cases add work beyond a
    one-shot import.
13. **Future Build Orders are imported the same way,** with no label writes. Options
    §2.8 says labels are written "for joins from now on"; a sub-issue join is a
    GitHub-side membership, so writing a `feature:` label for it would duplicate
    the parent link.

## 11. Completion and handoff

- [ ] `slug/1`, `clean/1`, `plan/3`, runner, child and test switch merged.
- [ ] The four C6-T01 items in §2 are in the merged C6-T01.
- [ ] V-1..V-12, V-16..V-18 pass; each fails under its listed mutation. V-13,
      V-14 pass as guards.
- [ ] Concepts paragraph shipped in the same PR.
- [ ] After rebuild: 8 `bo-*` features, about 116 members (owned or also),
      zero GitHub calls, zero label writes on this caller.
- **Dependents:** C12-T02 (`slug/1`), C6-T05 and C10-T03 (read imported
  features), C13-T04 (its runbook skips imported `bo-*` members).
- **Sources:** tickets/README.md C6 rows; chunks.md C6; plan §8 EC-24; options
  §2.5, §2.8; baseline line 371; decisions E8-D2, E8-D11; C6-T01 §4.1–4.4, §6,
  §10; C6-T02 §4; C4-T01 §4.1–4.4; C4-T02 rows table and "Interface
  mismatches"; C4-T03 line 216; C5-T02 lines 208-210; C12-T02 §2; the files
  cited in §3.

### Interface mismatches found with neighbour rows

1. **C6-T01.** Settled 2026-10-08: C6-T01 adds `:unknown` for `at`, `from`,
   `to`; epic relabel in `update_feature/3`; `source`/`actor` on each
   `journal/2` event; and the explicit epic-update rule (§2 items 1-4).
2. **C6-T02 vs this row.** Resolved: C6-T02 exempts `import:*` sources, and this
   ticket uses `import:build-order`. The earlier `build-order:<root>` source
   would have failed C6-T01's source regex.
3. **C4-T01 vs C4-T02.** Settled 2026-10-08: refs are `%{ref, at}` per C4-T01
   (`ref` = `%{owner, repository, number}`); C4-T02 writes that shape.
4. **Row predecessors.** The row lists only C6-T01. This ticket also needs
   C4-T01 (History reads) and C4-T02 (`sub_issues_added`), as C4-T02 asked.
5. **C4-T03.** Settled 2026-10-08: C4-T03 appends live `:sub_issue` adds to
   the root row's `sub_issues_added` with a real time.
6. **C13-T04.** Settled 2026-10-08: its runbook skips imported `bo-*` members
   (already classified).

## Review log

Adversarial review 2026-10-08 against the sources, C6-T01/T02, C4-T01/T02/T03,
C5-T02 and C12-T02 as written.

1. Replaced the assumed C6-T01 API (`upsert/2`, per-member `add`) with C6-T01
   §4.4 as written (`create`, `update_feature`, `add_epic`, `add` with one
   `epic`/`at` per call, `move:`); `snapshot` owners are owner records, not
   slugs; added `also` to the snapshot.
2. Source `build-order:<root>` → `import:build-order`: the old value fails
   C6-T01's source regex, and C6-T02 already exempts `import:*`. Resolved the
   writer's C6-T02 mismatch; V-15 is now a C6-T02 guard.
3. Open `to` is `:none` (C6-T01), not `:open`.
4. Member `epic: nil` is impossible under C6-T01 invariant 2 and C5-T02;
   added the catch-all epic `f-bo-<n>`.
5. Runner order fixed: moves and removes now run before adds (the old order
   contradicted the move row); moves between imported features use
   `add(move: true)` and wait for a complete History.
6. `at` changes are no longer planned as adds (C6-T01 keeps the first
   `joined_at`), which kept I-1 false.
7. Added text and key bounds (§4.2, V-16): C6-T01 refuses labels over 80
   characters or with control characters, and long lane slugs exceed the epic
   key rule.
8. Added stale-plan handling (V-17) and the operator-removal rule (V-18);
   added also-link removal on leave.
9. `slug_taken` now uses `journal/2` (features have no creator field);
   recorded the C6-T01 requests (unknown dates, epic relabel, event source).
10. History interface updated to C4-T01's current `parent` ref and
    `sub_issues_added` `%{ref, at}` shapes; runner waits for
    `:backfill_pending`; status carries health (EC-07).
11. Line fixes: `label/1` `:106-111`, internal caller `:90`, `capitalize_words/1` `:124-128`,
    `:rest_for_one` `:123-125`, `addF` J:118–121; test switch now cites
    `config.exs:66`/`:81` (BuildOrder children) instead of `:71`.
12. V-1 fixture gains #20 under #2000 so the bare-lane mutation can fail;
    V-14 marked as a guard, not coverage; V-2/V-4/V-5/V-7 mutations widened.
- Reconciliation 2026-10-08 (coordinator): C6-T01 requests, C4-T01/C4-T02 `%{ref, at}` shape, C4-T03 live `sub_issues_added` and C13-T04 skip of `bo-*` marked settled; decision 4 now says live joins get a real time; `at` may be `:unknown` in the meta comment; source stays `import:build-order`.
