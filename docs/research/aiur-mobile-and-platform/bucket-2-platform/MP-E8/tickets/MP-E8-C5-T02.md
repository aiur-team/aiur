---
ticket_id: MP-E8-C5-T02
feature_id: MP-E8
chunk_id: MP-E8-C5
bucket: 2-platform
title: Epic resolver
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C5-T01]
complexity: 2
design_gate: DESIGN-E8
owns_edge_cases: [EC-21]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C5-T02 — Epic resolver

> Cites code at `origin/main` `58854d4c8` (runtime worktree
> `aiur-worktrees/runtime/src`). Paths marked PROPOSED do not exist yet. If MP-R1
> has moved `build_order/` before this starts, re-resolve the symbols below
> (CR-E8-6 places Build Order code in `build-orders`).

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C5
  (epics), ticket T02.
- **User value.** Every card on the home page sits in exactly one epic column
  (E8-D1). Much of history has no epic signal: 659 of 1,344 issues (49 %) carry
  none of `bug`, `enhancement`, `refactor`, `documentation` (baseline.md:376),
  and the baseline estimates about 90 % carry no epic signal (baseline.md:386).
  So the column must come from one fixed rule that gives the same answer every
  time and says where the answer came from (E8-D9, options.md:38 E-C).
- **Deliverable.** PROPOSED pure module `Aiur.BuildOrder.Epic`
  (`src/lib/aiur/build_order/epic.ex`) with:
  - `resolve/2`: returns exactly one epic key for a ticket, with its source;
  - `unsorted/0`: the Unsorted epic descriptor, copied from the design.
- **Precedence (row, fixed):** (1) feature epic from the owning feature,
  (2) override, (3) first general epic in config order whose label is on the
  ticket, (4) `unsorted`.
- **Sources (row):** `"feature"`, `"override:<actor>"`, `"label:<name>"`,
  `"default"`. This ticket adds `"unknown"` for "no signal because an input was
  unavailable" (§10 decision 1).
- **Non-goals.**
  - No store, no process, no I/O, no config read. The override store and CLI are
    C5-T03. The feature registry is C6-T01. The config section is C5-T01. The
    caller passes all three as plain data.
  - No epic catalogue order (`order`, J:289–292) and no counts (J:293). They
    are part of the snapshot that C8-T04 assembles (payload schema C3-T02).
  - No epic catalogue function (C5-T03 reads the configured keys itself;
    see §11 hand-off).
  - No rendering. The resolver only returns keys.
  - No GitHub writes and no label projection.

## 2. Dependencies and blockers

- **Blocked by DESIGN-E8.** The general epic keys, hues and icons are the
  design's `GENERAL` (J:96) and the Unsorted descriptor is `epics.unsorted`
  (J:116). If the owner changes them in DESIGN-E8 sign-off, C5-T01 changes the
  config defaults and `unsorted/0` follows J:116.
- **Blocked by MP-E8-C5-T01** (epics config section). C5-T01 §4.4 gives
  `settings.build_order.epics`, an ordered list of
  `%Aiur.Config.Schema.BuildOrderEpic{key, label, labels, hue, icon}` with
  `labels` already trimmed and lowercase. C5-T01 also refuses `epic:` labels
  (IssueSync parks `epic:*`, `src/lib/aiur/orchestrator/issue_sync.ex:479-494`),
  a label in two epics, and the key `unsorted`. The resolver does not check
  these again.
- **Shared contracts.** None. The resolver is an internal function.
- **Input producers (not predecessors; the resolver takes plain maps).**
  - C6-T01 owner answer `%{feature: slug, epic: key, ...} | :none` (C6-T01 §4.1
    and its interface note 1) and the features' ordered epic keys.
  - C5-T03 override `%{epic: key, actor: login, ...}` (C5-T03 §4); C5-T03 stores
    general keys only and refuses `unsorted` (C5-T03 §10 decisions 3, 4).
- **Successors that call it.**
  - C5-T03 (override registry and `aiur epic set`) reports the source shape
    `override:<actor>` from this ticket.
  - C8-T04 (ticket index assembler) calls `resolve/2` for every ticket row
    (history, now, planned, not-queued).
  - C6-T01 lists C5-T02 as predecessor (row). Data flows from C6-T01 into the
    resolver, not back (C6-T01 interface note 1); C6-T01 needs nothing from
    this module.
- **Concurrency.** It can be built in parallel with C5-T03 and C6-T01 once
  C5-T01 is merged: its inputs are plain maps, so it needs neither store.
- **Open questions.** None block it. S-8 default (DESIGN-E8.md:108): the source
  is not drawn on the board or the modal; it is shown by `aiur epic … --json`
  (C5-T03). This ticket only has to produce it.

## 3. Verified starting point (`58854d4c8`)

- **No module for this kind of epic exists.** There is no
  `defmodule Aiur.BuildOrder do` in `lib/`; the namespace is a directory of
  modules (`src/lib/aiur/build_order/`) and there is no `epic.ex` in it.
- **Name collision: Build Order already uses "epic" for a lane.** Today a Build
  Order "epic" is a `build-lane:<slug>` label:
  - `Aiur.BuildOrder.Metadata.parse_lane/1` reads `build-lane:`
    (metadata.ex:113-115), and its comment says "a build order may define its
    own epics" (metadata.ex:109-112);
  - `RootSummary.epic_count` (root_summary.ex:19) is counted from lanes
    (`metric_count(metadata, & &1.lane)`, catalog_store.ex:143);
  - the Ad Hoc epic is `build-lane:adhoc` (ad_hoc_source.ex:3-6).

  The new general/feature epics are a different concept (E8-D1). The resolver
  does not read `build-lane:` labels unless an operator lists one in C5-T01's
  `labels`. The moduledoc must say this, so readers do not confuse
  `Epic.resolve/2` with `epic_count` (§10 decision 10).
- **The closest model is `Aiur.BuildOrder.Metadata`**
  (`src/lib/aiur/build_order/metadata.ex`), a pure label parser for
  `complexity:`, `phase:` and `build-lane:`:
  - `parse/1` (metadata.ex:22) reads labels and returns a struct with a value
    and warnings for every dimension;
  - `bounded_labels/1` (metadata.ex:69-76) normalises with
    `String.trim/1 |> String.downcase/1` and drops invalid labels
    (`valid_label?/1`, metadata.ex:78-79: binary, valid UTF-8, 1..256 bytes);
  - `parse_dimension/7` (metadata.ex:86-96) is the "exactly one or a named
    warning" pattern. The resolver uses the same idea: one answer plus named
    reasons, never a silent fallback.
- **Labels on a live issue.** `%Aiur.Issue{labels: [String.t()]}`
  (`src/lib/aiur/issue.ex:52`, type at :89). GitHub ingestion already
  downcases them (`src/lib/aiur/github/issues.ex:1013`) but does not trim.
  Other tracker backends do not promise either, so the resolver normalises the
  ticket's labels again (one call).
- **Labels on a history row.** C4-T01 §4.1 defines
  `labels :: [String.t()] | :unknown` (default `:unknown`) and
  `labels_complete :: boolean | :unknown` (false when the issue has more than
  100 labels). The resolver must accept both.
- **IssueSync parking.** `parked_marker_label?/1`
  (`src/lib/aiur/orchestrator/issue_sync.ex:489-494`) uses the same
  trim-and-downcase rule, and treats `epic:*` as parking. That is why no epic
  is ever a label with the `epic:` prefix.
- **Test tooling.** `stream_data ~> 1.2` is a test dependency
  (`src/mix.exs:160`). Property tests use `use ExUnitProperties` and
  `check all(...)` (for example `src/test/aiur/provider_meters_test.exs:3`,
  :76). Build Order unit tests live in `src/test/aiur/build_order/`
  (for example `metadata_test.exs`).
- **Design facts (read in `design-source/assets/build.js`).**
  - `colKey = (t) => t.epic || "unsorted"` (J:332): every ticket maps to one
    key, and a missing epic is the string `"unsorted"`.
  - `epics.unsorted = { key: "unsorted", label: "Unsorted", hue: 0, icon:
    "unsorted", unsorted: true }` (J:116).
  - `GENERAL` (J:96): keys `bugs`, `design`, `infra`, `docs`.
  - Feature epics are keys such as `f-pag-api`, and each one names its feature
    (`addF`, J:117-121, `feature: k, temp: true`). A ticket in a feature epic
    has that feature as its feature (J:186, first branch:
    `feature = e && e.feature ? e.feature : …`).
  - **The mock also gives a feature to some tickets in general epics** (J:186,
    second branch: `fs.length && r() < 0.22 ? pick(r, fs).key : null`). Such a
    card keeps its general column and shows a feature dot (`bd-fd`, J:829;
    `--ft`, J:823). E8-D11 instead says "the owning feature sets the ticket's
    feature-epic column", and C6-T01 stores an owner epic that is always one of
    the feature's epics. This ticket follows E8-D11 (§10 decision 2); the
    parity effect is in §9.
  - A feature can have more than one epic (`Pagination · API`,
    `Pagination · UI`, J:132).
  - The Unsorted lane and card use the muted colour:
    `.bd-card.unsorted, .bd-lane.unsorted { --ec: var(--muted); }` (C:230), set
    when `e.unsorted` is true (J:785).

## 4. Chosen design

### 4.1 Inputs (plain data, no structs from other tickets)

```elixir
# ticket facts
%{
  labels: [String.t()] | :unknown,                     # C4-T01 row or Issue.labels
  labels_complete: boolean() | :unknown,               # optional, default true
  owning_feature: %{feature: String.t(), epic: String.t()} | :none | :unknown,  # C6-T01 owner
  override: %{epic: String.t(), actor: String.t()} | :none | :unknown           # C5-T03
}

# context, built once per snapshot
%{
  general: [%{key: String.t(), labels: [String.t()]}],  # C5-T01 build_order.epics, config order
  features: %{String.t() => [String.t()]} | :unknown    # slug => ordered feature epic keys (C6-T01)
}
```

Extra keys in either map are ignored, so C5-T01's `%BuildOrderEpic{}` structs,
C6-T01's full owner record (`joined_at`, `source`, …) and C5-T03's full
override record pass through unchanged. `general` labels are trusted as
normalised (C5-T01 §4.4); only ticket labels are normalised here.

### 4.2 Output

```elixir
defmodule Aiur.BuildOrder.Epic.Resolution do
  @enforce_keys [:key, :source]
  defstruct [:key, :source, ignored: [], gaps: []]
  # key     :: String.t()                 never nil
  # source  :: "feature" | "override:" <> actor | "label:" <> label | "default" | "unknown"
  # ignored :: [:override_outside_feature | :override_unknown_epic
  #             | :owner_epic_missing | :feature_missing | :feature_without_epics]
  # gaps    :: [:labels | :feature | :override]   inputs that were :unknown or incomplete
end
```

- `ignored` names an input that was present but did not decide the answer.
  C5-T03 `show` and C8-T04 can report it, so an override never fails silently
  (§6).
- `gaps` names inputs that were unavailable. If `gaps != []`, the source is
  never `"default"`: it is `"unknown"` when the fallback is reached, and the
  decided source otherwise (with `gaps` still set).

### 4.3 Rule

1. **Feature.** `owning_feature` is a map and `features` is a map:
   - slug not in `features` → `ignored: :feature_missing`, go to step 2;
   - slug maps to `[]` → `ignored: :feature_without_epics`, go to step 2;
   - owner `epic` is one of the feature's epics → that epic, `"feature"`;
   - otherwise (stale owner epic) → the feature's **first** epic, `"feature"`,
     `ignored: :owner_epic_missing`.

   If the step decides and `override` is a map, add `:override_outside_feature`
   (the override did not decide). If `owning_feature` or `features` is
   `:unknown`, add gap `:feature` and go to step 2. `:none` goes to step 2.
2. **Override.** `override` is a map:
   - epic is a `general` key → that epic, `"override:<actor>"`;
   - any other key (dropped from config, `"unsorted"`, a feature epic) →
     `ignored: :override_unknown_epic`, go to step 3.

   `:unknown` adds gap `:override`. `:none` goes to step 3.
3. **Labels.** If `labels` is a list: keep valid labels as
   `Metadata.valid_label?/1` does, normalise with
   `String.trim |> String.downcase`, and walk `general` in config order. For
   each epic, walk its `labels` in order; the first one in the ticket's label
   set decides: that epic, `"label:<label>"`. `:unknown` adds gap `:labels`.
   If nothing matched and `labels_complete` is not `true`, add gap `:labels`
   (a matching label may be among the ones not read).
4. **Fallback.** `"unsorted"`, source `"default"` when `gaps == []`, else
   `"unknown"`.

**Invariants** (property-tested, §8):

- I-1 the key is never nil and is always one of: a `general` key, `"unsorted"`,
  or an epic of the ticket's owning feature;
- I-2 the result does not depend on label order or duplicates (labels are a set);
- I-3 `gaps != []` implies `source != "default"`;
- I-4 if the owning feature is found in `features` with epics, the key is one of
  that feature's epics (E8-D11: the owning feature sets the column).

### 4.4 `unsorted/0`

```elixir
@spec unsorted() :: map()
def unsorted, do: %{key: "unsorted", label: "Unsorted", hue: 0, icon: "unsorted", unsorted: true}
```

This is J:116 exactly. C8-T04 puts it into the snapshot's `epics` map so the
C9 port of `colKey` and the lane code (J:785) find the same object.

## 5. Implementation steps

1. Add PROPOSED `src/lib/aiur/build_order/epic.ex` with `Epic.Resolution`
   (nested), `resolve/2`, `unsorted/0`, and a `@spec` on each public `def`
   (`mix lint` runs `specs.check`, CONTRIBUTING.md "Enforcement"). The
   moduledoc says these are home-page epics, not `build-lane:` lanes (§3).
2. Write `resolve/2` as four private steps that each return
   `{:done, resolution} | {:next, acc}`, in the §4.3 order. `acc` carries
   `ignored` and `gaps`. Keep it under credo's complexity limit; no macros.
3. Normalise ticket labels with a private `normalize/1` (valid-label filter,
   then `String.trim |> String.downcase`), as `Metadata.bounded_labels/1` does.
   Do not make `bounded_labels/1` public: it returns warnings the resolver does
   not use.
4. Add PROPOSED `src/test/aiur/build_order/epic_test.exs` with the §8 tests.
5. No config, docs or template changes (C5-T01 owns the config section; the
   resolver has no interface an operator sets).

## 6. Non-happy paths

| Input | Behaviour | Test |
| --- | --- | --- |
| History row with `labels: :unknown` (C4-T01 default) and nothing else | `"unsorted"`, source `"unknown"`, `gaps: [:labels]` | V-3 |
| Labels read but incomplete (`labels_complete: false`, >100 labels) and no match | `"unsorted"`, `"unknown"`, `gaps: [:labels]`; a match still decides | V-16 |
| Feature registry unavailable (`features: :unknown` or `owning_feature: :unknown`) | Skip step 1, gap `:feature`; a label can still decide, but the source is `"label:…"` with the gap kept, never `"feature"` | V-10 |
| Override store unavailable (`override: :unknown`; C5-T03 `{:error, health}` mapped by C8-T04) | gap `:override`, continue | V-12 |
| Override names an epic removed from config (stale override, C5-T03 `epic_known: false`) | `:override_unknown_epic`, continue to labels; no crash | V-8 |
| Override names `"unsorted"` or a feature epic (C5-T03 refuses these; an old journal or another caller may still pass one) | `:override_unknown_epic`, continue | V-9 |
| Override names a general epic on a feature member | Feature epic wins, `:override_outside_feature` (E8-D11) | V-6 |
| Owner epic no longer in the feature's epics (stale owner record) | feature's first epic, `"feature"`, `:owner_epic_missing` | V-5 |
| `owning_feature` slug missing from `features` (dangling membership) | `:feature_missing`, continue | V-11 |
| Feature with no epics (`[]`) | `:feature_without_epics`, continue | V-11 |
| Labels with case or whitespace (`" Bug "`) | match `bug` | V-13 |
| Non-binary or invalid entries in `labels` | dropped, as `Metadata.valid_label?/1` | V-13 |
| Two type labels (`refactor` and `bug`), EC-21 | first epic in config order (`bugs`), one epic | V-2 |
| Two labels of one epic on the ticket (`chore`, `refactor`) | first label in that epic's list decides the label in the source | V-14 |
| Empty `general` list (`epics: []`, C5-T01 §4.1) | labels never match; Unsorted | V-1 |

- **Concurrency, retries, disconnects.** Not relevant: a pure function with no
  state. Concurrent writes are settled by the stores (C5-T03 EC-13).
- **Security and privacy.** The actor string comes from C5-T03 (validated there,
  `^[A-Za-z0-9._-]{1,64}$`) and goes into the source unchanged. It is the
  operator's or agent's login, already shown in the CLI; no new exposure. The
  resolver never logs.

## 7. Compatibility and rollout

- New module, no caller at merge. No config key, no CLI, no migration, no
  feature gate. Rollback is a revert.
- No docs change: no operator-facing interface (AGENTS.md "Docs are not
  required for internal refactors"). The concept page for epics is C12-T07.

## 8. Verification

Default context for the examples: `general` = the C5-T01 defaults
(`bugs: [bug]`, `design: [design]`, `infra: [refactor, chore]`,
`docs: [documentation]`, C5-T01 §4.1), and
`features = %{"pag" => ["f-pag-api", "f-pag-ui"], "docs-site" => ["f-docs"]}`.
"Member of `pag` with `f-pag-ui`" means
`owning_feature: %{feature: "pag", epic: "f-pag-ui"}`.

| # | Input | Expected | Fails when this production line is changed |
| --- | --- | --- | --- |
| V-1 | `labels: []`, feature `:none`, override `:none` | `key "unsorted"`, `"default"`, `gaps []`; same with `general: []` and `labels: ["bug"]` | fallback key changed to `nil` or `"bugs"` |
| V-2 | `labels: ["refactor", "bug"]` and `["bug", "refactor"]` | both `bugs`, `"label:bug"` | walk labels instead of config order |
| V-3 | `labels: :unknown`, rest `:none` | `"unsorted"`, `"unknown"`, `gaps [:labels]` | replace the `"unknown"` branch with `"default"` (AGENTS.md unknown-path mutation) |
| V-4 | member of `docs-site` with `f-docs`, `labels: ["bug"]` | `f-docs`, `"feature"` | move the label step before the feature step |
| V-5 | member of `pag` with `f-pag-ui`; and member of `pag` with `f-gone` | `f-pag-ui`, `"feature"`; then `f-pag-api`, `"feature"`, `ignored [:owner_epic_missing]` | always take the feature's first epic; or return the owner epic unchecked |
| V-6 | member of `pag` with `f-pag-api`, override `bugs` | `f-pag-api`, `"feature"`, `ignored [:override_outside_feature]` | let the override win over the feature |
| V-7 | no feature, override `infra` by `agent-1`, `labels: ["bug"]` | `infra`, `"override:agent-1"` | put labels before the override |
| V-8 | no feature, override `ops` (not in config), `labels: ["bug"]` | `bugs`, `"label:bug"`, `ignored [:override_unknown_epic]` | accept any override key |
| V-9 | no feature, override `f-pag-ui`; and override `unsorted`; `labels: ["bug"]` | both `bugs`, `"label:bug"`, `ignored [:override_unknown_epic]` | check the override against all known keys instead of `general` keys |
| V-10 | `owning_feature: :unknown`, `labels: ["documentation"]` | `docs`, `"label:documentation"`, `gaps [:feature]`; and with `labels: []` → `"unsorted"`, `"unknown"`; same with `features: :unknown` and a known owner | drop the `:feature` gap |
| V-11 | member of `gone` (not in map); member of `empty` (`[]`); `labels: ["bug"]` | `bugs`, `"label:bug"`; `ignored [:feature_missing]` / `[:feature_without_epics]`; no raise | `Map.fetch!` on the slug, or `hd/1` on `[]` |
| V-12 | `override: :unknown`, `labels: []` | `"unsorted"`, `"unknown"`, `gaps [:override]` | drop the `:override` gap |
| V-13 | `labels: [" Bug ", 42, nil, ""]` | `bugs`, `"label:bug"` | remove `normalize/1` or the valid-label filter |
| V-14 | `labels: ["chore", "refactor"]` | `infra`, `"label:refactor"` | walk ticket labels instead of the epic's labels inside an epic |
| V-15 | `unsorted/0` | equals J:116 map field by field | any field edit |
| V-16 | `labels: ["agent:done"], labels_complete: false`; and `labels: ["bug"], labels_complete: false` | `"unsorted"`, `"unknown"`, `gaps [:labels]`; then `bugs`, `"label:bug"`, `gaps []` | ignore `labels_complete` |
| P-1 | property: generated labels from a pool including every default label and noise, owner from `:none \| :unknown \| known \| stale epic \| dangling`, override from `:none \| :unknown \| any key` | I-1 holds | return the override key without the step-2 check |
| P-2 | property: `labels` shuffled and duplicated | identical `Resolution` | any `List.first(labels)` style shortcut |
| P-3 | property: any input with a gap | I-3 holds | V-3 mutation |
| P-4 | property: owner found in `features` with epics | I-4 holds | V-6 mutation |

- There is no "same input twice gives the same output" property: that is a
  self-comparison that cannot fail (AGENTS.md). Determinism is shown by P-2
  and by V-1..V-16 fixed answers.
- **Mutation discipline.** For each V and P row, in a worktree, apply the
  mutation in the last column, run the test, see it fail, restore it. Before
  each run, `git status --porcelain` shows only `src/lib/aiur/build_order/epic.ex`.
  The PR body names each result and the exact commands.
- **Commands** (from `src/`):
  - `mise exec -- mix test test/aiur/build_order/epic_test.exs`
  - `mise exec -- mix compile --warnings-as-errors`
  - `mise exec -- mix format --check-formatted`
  - `mise exec -- mix lint` (specs.check and credo --strict)
  - `mise exec -- mix dialyzer`
  - CI green on the head SHA (`make ci` gate), not only the narrow run.
- **Manual test.** Not applicable: nothing calls the resolver until C8-T04. The
  end-to-end check of epic columns belongs to C8-T04 and the C9 board tickets.

## 9. Pixel parity

This ticket draws nothing, so C1-T02's side-by-side harness has nothing of its
own to compare. Parity depends on it in three exact values, which V-15 and V-1
pin:

- the fallback key is the string `"unsorted"`, the value `colKey` (J:332)
  produces for a ticket without an epic;
- `unsorted/0` is J:116 field by field (`label "Unsorted"`, `hue 0`,
  `icon "unsorted"`, `unsorted: true`), so the lane gets the `.unsorted` class
  (J:785) and the muted colour `--ec: var(--muted)` (C:230), and the dashed
  `I.unsorted` icon (J:41);
- general and feature keys pass through unchanged, so `D.epics[colKey(t)]`
  (J:815, J:1159, J:1212, J:1356) always finds an entry.

**Known divergence from the mock.** The design's fixture gives about 22 % of
general-epic tickets an owning feature (J:186) and draws them in the general
column with a feature dot (J:823, J:829). Under E8-D11 and this rule such a
ticket goes to a feature-epic column. A parity fixture that is fed through the
resolver must therefore express those tickets as "also affects" links or with
no owner, or C1-T02 will show them in a different column (sign-off item S-25).
This does not affect
fixtures that C3-T02 renders directly.

When C8-T04 is merged, the C1-T02 run with the fixture that contains an
Unsorted ticket (`POOL.unsorted`, J:102) is the parity check for this output.

## 10. Decisions made without the owner

1. **A fifth source, `"unknown"`.** The row lists four sources. A ticket whose
   labels were never observed (C4-T01 `:unknown`) would otherwise read
   `"default"`, which claims "we looked and found nothing". AGENTS.md
   "A collapsed cause names the collapse at the source" requires a
   cause-neutral value. The column is still Unsorted, because the design has
   no other column for it and E8-D1 requires exactly one epic.
2. **The owning feature always wins, as E8-D11 says, not as the mock data
   does.** The mock puts some feature members in general columns (J:186, §3).
   The owner decision (E8-D11, "the owning feature sets the ticket's
   feature-epic column") and C6-T01's owner record (epic always one of the
   feature's epics) both say otherwise, and the row puts the feature first. An
   override that names a general epic on a member is reported as
   `:override_outside_feature`; to move such a ticket, the operator moves it out
   of the feature (C6-T04). This divergence from the mock is sign-off item S-25
   in DESIGN-E8.md; if the mock behaviour is intended, step 1 would apply only
   when no override or label decides.
3. **The feature epic comes from the owner record.** C6-T01 stores an `epic` on
   each membership (C6-T01 §10 decision 4; default: the feature's first epic).
   The resolver uses it and falls back to the feature's first epic only when the
   stored epic is no longer one of the feature's epics.
4. **Overrides decide only general epics.** This matches C5-T03 §10 decision 3:
   choosing a feature epic belongs to `aiur feature add` (C6-T04). A feature
   epic key or `"unsorted"` in an override is ignored with
   `:override_unknown_epic`, never trusted.
5. **`"unsorted"` is not an override target** (C5-T03 §10 decision 4). Removing
   a guess is `aiur epic clear`.
6. **Exact label matching, case and whitespace ignored.** No prefixes or globs:
   C5-T01 lists whole label names, and the IssueSync and Metadata code use the
   same trim-and-downcase rule.
7. **The source uses the configured label, not the raw label** (`"label:bug"`
   for `" Bug "`), so the source is stable across label spelling.
8. **The override's `confirmed` flag is not an input.** S-8 default shows
   confirmation through the CLI (C5-T03), and it does not change the column.
9. **Not in scope: the epic order and counts** (J:289–293). They need the
   features' start times and all rows, which C8-T04 has.
10. **Module name `Aiur.BuildOrder.Epic` kept** (row: "a pure function in
    `Aiur.BuildOrder`"), even though Build Order already says "epic" for a
    `build-lane:` lane (§3). The moduledoc names the difference. Renaming the
    existing `epic_count` is out of scope.
11. **Incomplete labels count as a gap only when nothing matched.** A matching
    label that was read is real evidence; a missing match on a truncated list is
    not "we looked and found nothing".

## 11. Completion and handoff

- [ ] `Aiur.BuildOrder.Epic.resolve/2`, `Epic.Resolution` and `unsorted/0`
      exist with `@spec`s; no process, no I/O.
- [ ] V-1..V-16 and P-1..P-4 pass; each mutation in §8 fails its test; the PR
      body lists the commands that ran.
- [ ] `mix compile --warnings-as-errors`, `mix lint`, `mix dialyzer` pass; CI
      green on the head SHA.
- [ ] No docs change (internal function); the PR says so.
- **Dependents:** C5-T03, C8-T04 (and through C8-T04, the C9 lane code). C6-T01
  lists this ticket as predecessor but uses nothing from it.
- **Hand-off notes for neighbours:**
  - **C5-T01** gives `build_order.epics` in config order with `key` and
    normalised `labels` (§4.4 there). No change needed.
  - **C5-T03.** Settled 2026-10-08: C5-T03 no longer needs `general_keys/1`;
    it reads the configured keys from `settings.build_order.epics`
    (`Enum.map(epics, & &1.key)`). It must pass `%{epic:, actor:}` (the actor,
    not the source channel).
  - **C6-T01** owner answer `%{feature, epic}` is the `owning_feature` input
    as is; its snapshot `features` gives `slug => [epic keys]` in declared
    order. Its invariant "owner epic ∈ feature epics" makes
    `:owner_epic_missing` rare; the resolver still handles it.
  - **C8-T04.** Settled 2026-10-08 (C8-T04 accepts this): it must pass the
    C6-T01 owner record (not only the slug) as
    `owning_feature`, pass `labels_complete` from the C4-T01 row, pass
    `:unknown` (not `[]` or `:none`) for labels, features or overrides it could
    not read (including C5-T03 `{:error, health}`), put `unsorted/0` in the
    snapshot's `epics` map, and carry `source` for the CLI `--json` view only
    (S-8 default).
  - **C1-T02 / C3-T02 fixtures:** see §9 "Known divergence from the mock".
- **Sources:** tickets/README.md C5 rows (lines 474–525) and C6-T01, C8-T04
  tickets; C5-T01 §4.1, §4.4, handoff 1; C5-T03 §4, §10 decisions 3-4, §11;
  C6-T01 §4.1, §10 decision 4, interface note 1; chunks.md MP-E8-C5;
  plan.md EC-21 (line 235); decisions.md E8-D1, D9, D11; options.md:38 E-C;
  baseline.md:376, 386; DESIGN-E8.md:108 (S-8); C4-T01 §4.1;
  code at `58854d4c8`: `build_order/metadata.ex:22, 69-79, 86-96, 109-115`,
  `build_order/root_summary.ex:19`, `build_order/catalog_store.ex:143`,
  `build_order/ad_hoc_source.ex:3-6`, `issue.ex:52, 89`,
  `github/issues.ex:1013`, `orchestrator/issue_sync.ex:479-494`,
  `mix.exs:160`, `test/aiur/provider_meters_test.exs:3, 76`; design J:41,
  J:96, J:102, J:116-121, J:132, J:186, J:289-293, J:332, J:785, J:815,
  J:823, J:829, J:1159, J:1212, J:1356, C:230.
- **Remaining blocker:** DESIGN-E8 sign-off (including §10 decision 2) and
  C5-T01.

## Review log

Adversarial review, 2026-10-08, against code at `58854d4c8`, design-source and
neighbour tickets.

1. Fixed the history figure: 659 of 1,344 is 49 %, not 90 %; cited both
   baseline lines (376, 386).
2. Input shape aligned with C6-T01: `owning_feature` is now the owner record
   `%{feature, epic}` (C6-T01 stores a per-ticket feature epic; the earlier text
   said it did not). Step 1 uses the stored epic; added `:owner_epic_missing`.
3. Override rule aligned with C5-T03: overrides decide general epics only;
   `"unsorted"` and feature epic keys are ignored. Removed the old decisions 3
   and 5 and `:override_feature_without_membership`; rewrote V-5 and V-9.
4. Config shape aligned with C5-T01: field is `labels`, not `matchers`; path is
   `build_order.epics`; Design default label is `design`, not `[]`. Dropped
   resolver-side normalisation of config labels (C5-T01 already does it).
5. Added `labels_complete` (C4-T01 field) with V-16 and §10 decision 11.
6. Added the existing Build Order "epic" = `build-lane:` collision (metadata.ex,
   root_summary.ex, catalog_store.ex, ad_hoc_source.ex) and §10 decision 10.
7. Added the design divergence (mock gives features to general-epic tickets,
   J:186, J:823, J:829) to §3, §9 and §10 decision 2.
8. Corrected citations: issue_sync.ex range 479-494, bounded_labels 69-76,
   provider_meters_test.exs :76, DESIGN-E8.md:108, README lines; valid-label
   filter now matches `valid_label?/1` (V-13 adds `""`).
9. Noted that C5-T03's expected `Epics.general_keys/1` is not provided here and
   that C6-T01 uses nothing from this ticket.
- Reconciliation 2026-10-08 (coordinator): E8-D11-vs-mock divergence named as S-25 (§9, §10 decision 2), C5-T03 `general_keys/1` hand-off marked settled (C5-T03 reads configured keys), C8-T04 owner-record/`labels_complete`/`:unknown` hand-off marked settled.
