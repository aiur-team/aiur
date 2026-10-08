---
ticket_id: MP-E8-C6-T05
feature_id: MP-E8
chunk_id: MP-E8-C6
bucket: 2-platform
title: Feature statistics
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C6-T01, MP-E8-C4-T01, MP-E8-C1-T01]
complexity: 2
design_gate: DESIGN-E8
owns_edge_cases: [EC-24, EC-08]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C6-T05 — Feature statistics

> Cites code at `origin/main` `58854d4c8` (runtime worktree
> `aiur-worktrees/runtime/src`). Paths marked PROPOSED do not exist yet. Design
> citations: `J` = `design-source/assets/build.js`, `C` = `design-source/assets/build.css`.
> If MP-R1 has moved `build_order/` before this starts, re-resolve the symbols
> below (CR-E8-6 places the feature store in `build-orders`).

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C6
  (features), ticket T05.
- **User value.** The feature header (`.bd-fh`) and the Feature filter show how
  far a feature is: Done `n/m`, the "Weighted" %, "Scope · original → now" with
  `+added`, a scope sparkline, and "+N also affect". In the design the browser
  computes these from every ticket it holds (`featStats`, J:343–352). In the
  product the browser holds only the loaded days of history (C8-T04 pages by
  day), so a browser-side count would be wrong for any feature older than the
  loaded window. The server must compute them over the whole registry.
- **Deliverable.**
  - PROPOSED `src/lib/aiur/build_order/feature_stats.ex`
    (`Aiur.BuildOrder.FeatureStats`): a pure port of `featStats` with explicit
    unknown handling, plus `points/1`, `fact/3` and `to_json/1`.
  - An extension of the C1-T01 exporter that writes the design's own
    `featStats` output (with its inputs) as an oracle file,
    `feature-stats.json`, and passes it to the fixture mapper.
  - ExUnit tests, including a parity test against that oracle.
- **Non-goals.**
  - No rendering. `renderFeatures` and the sparkline polyline are C10-T03; the
    Feature filter options (`FOPTS`, J:1099) are C10-T02.
  - No payload wiring. C8-T04 calls this module and puts the result into the
    payload (see §4.6 for the schema change this needs).
  - No store, no PubSub, no GitHub call, no config key, no CLI.
  - Status mapping (closed → `done`/`failed`/`not_planned`/`closed`) is
    C8-T04's (C4-T01 hand-off note; `:duplicate` and unknown close reasons →
    `closed`, R-G11). This module takes the status as input.

## 2. Dependencies and blockers

- **DESIGN-E8.** Every MP-E8 ticket waits on it. S-26 covers this ticket's
  three decisions (2, 3, 10) and the unknown feature figure (decision 6).
- **MP-E8-C6-T01** (feature registry). This ticket reads the C6-T01
  `snapshot/1` value as it is (C6-T01 §4.1 model, §4.3 reads):
  `features: %{slug => %{baseline: :none | %{at, members: MapSet}, ...}}`,
  `owners: %{n => %{feature: slug, joined_at: DateTime, ...}}` (one owner per
  ticket, invariant 1) and `also: %{n => [slug]}`. It uses C6-T01's `added?`
  rule (not in `baseline.members`; C6-T01 §4.1 "Derived") and does not read
  `journal/2` (§10 decision 5). No new C6-T01 field is needed.
- **MP-E8-C4-T01** (History store). `fact/3` reads `Row.labels`
  (C4-T01 §4.1: `[String.t()] | :unknown`). Nothing else from the row.
- **MP-E8-C1-T01** (fixture exporter). Step 3 extends its
  `export-build-home-fixtures.mjs`, so this ticket merges after it. The README
  row does not list it; it is added to `blocked_by` (§10 decision 8).
- **Successors:** C8-T04 (builds facts with `fact/3`, calls `compute_all/3`
  and puts `to_json/1` into `features[k].stats`), C10-T03 (renders the
  result), C10-T02 (Feature filter `%`).
- **Contracts:** none shared.
- **Runs alongside:** C6-T02, C6-T03, C6-T04 (other files).

## 3. Verified starting point (`58854d4c8`)

| What | Where | Use here |
| --- | --- | --- |
| Complexity from labels | `lib/aiur/build_order/metadata.ex:21-64` `Aiur.BuildOrder.Metadata.parse/1` → `complexity: 1..5 \| :unknown` (`:9`, `:99-100`); missing, invalid and two-label cases all give `:unknown` (`:86-96`) | `fact/3` complexity. No new label parser |
| Weighted progress with unknowns | `lib/aiur/current_run_summary/progress.ex:14-35`: `lower_bound` always, `exact` only when no input is unknown; `:56-61` sums only `{:known, percent}`; `:124-130` `fraction/2` returns `nil` for a zero denominator | The model for `pct`/`pct_min`. Not called: it is `@moduledoc false` and tied to a run context |
| Progress tuple and non-work exclusion | `lib/aiur/current_run_summary/facts.ex:55-76` `weights/1` (drops `:non_work_terminal` from the denominator); `:144-159` `member_progress/2` (`{:known, 0..100}` or `{:unknown, reason}`; `:155` clamps a fresh percent to 0..100); `:169-170` `fresh_percent/1` (`%{status: :known, freshness: :fresh, percent: p}`) | Same tuple shape on input; same "non-work closure is not in the denominator" rule (§10 decision 2). The clamp is not copied (§10 decision 9) |
| Weight default to 1 | `facts.ex:120-121` and `lib/aiur_web/components/operator_control_center/build_order_grid_model.ex:273-295` `aggregate_completion/1` (`card.complexity \|\| 1` at `:277`, `:partial` resolution) | Not copied: this ticket excludes unknown weights and says so (§10 decision 3) |
| Lifecycle facts | `lib/aiur/build_order/lifecycle.ex:65-105` (`:closed` with `:completed/:not_planned/:duplicate`) | C8-T04 maps these to the status input; this module does not read lifecycle |

Current behaviour: nothing computes per-feature statistics. Build Order progress
exists only per root and per wave (`build_order_grid_model.ex:121-127`
`aggregate/1`), in the web layer.

### Design source (what must match exactly)

`featStats(fk)`, J:343–352, verbatim semantics:

| Output | Design rule | Line |
| --- | --- | --- |
| `total` | members with `t.feature === fk` (owner only), every section | 344 |
| `done` | members in `hist` with `status === "done"` (`failed` is not done) | 345 |
| `pct` | `w = Σ pts`; `wp = Σ pts × f`, `f` = 1 in `hist` (done **and** failed), `pct/100` in `now`, 0 in `plan`/`nq`; `w ? Math.round(wp / w * 100) : 0` | 346, 351 |
| `added` | members with `t.added` | 347 |
| `orig` | `total − added` | 351 |
| `spark` | `first = min(created)`; for `d = first; d <= NOW + 1; d += DAY` push count of members with `created <= d`; then push `total` if the last point differs | 348–350 |
| `also` | tickets with `fk` in `t.also` (the design never gives an owned ticket an `also` link, J:189) | 351 |

Other constants: `PTS = [1, 2, 3, 5, 8]` (J:93), `DAY = 864e5` (J:10).
History rows carry `pct: 100` (J:190) but `featStats` ignores it for `hist`.

Consumers of the figures: J:1076–1086 (`renderFeatures`: Done `s.done/s.total`,
Weighted `s.pct%`, `s.orig → s.total` with `<em>+s.added</em>` only when
`added > 0`, the sparkline from `s.spark` scaled to `viewBox 0 0 76 22`, and
`+s.also also affect` only when `also > 0`), J:1099 (Feature filter label
`label + "  " + pct + "%"`). Styles: `.bd-kv` and `.bd-kv b em` (C:109–112),
`.bd-kv svg.sp` 76 × 22 px (C:113).

Edge behaviours of the design code the port keeps:
- A feature with no members: `Math.min()` is `Infinity`, the loop does not run,
  then `0 !== undefined` pushes `0` → `spark: [0]`.
- `NOW + 1` is one millisecond, not one day.
- A join in the future (`first > NOW + 1`): no loop points, then `total`.

## 4. Chosen design

### 4.1 Inputs (plain data, like C5-T02 §4.1)

```elixir
# registry: the C6-T01 snapshot/1 value, read as it is (extra keys ignored)
%{
  features: %{String.t() => %{baseline: :none | %{at: DateTime.t(), members: MapSet.t(pos_integer())}}},
  owners:   %{pos_integer() => %{feature: String.t(), joined_at: DateTime.t()}},  # one owner per ticket
  also:     %{pos_integer() => [String.t()]}
}

# one fact per ticket number, built by C8-T04 with fact/3
%{
  status: :done | :failed | :not_planned | :closed | :running | :queued | :open | :unknown,
  complexity: 1..5 | :unknown,
  progress: {:known, 0..100} | {:unknown, atom()}    # read only when status == :running
}
```

`fact(row, status, progress)` builds the fact: `row` is a C4-T01
`History.Row` or `:missing`; complexity is
`Metadata.parse(row.labels).complexity` (`:unknown` when labels are
`:unknown` or the row is missing; `parse/1` already returns `:unknown` for a
non-list, `metadata.ex:76`). The status mapping is C8-T04's.

### 4.2 Output

```elixir
defmodule Aiur.BuildOrder.FeatureStats do
  @enforce_keys [:total, :done, :done_min, :pct, :pct_min, :orig, :added,
                 :baseline?, :spark, :also, :reasons]
  defstruct @enforce_keys
  # total        :: non_neg_integer()          always exact (registry count)
  # done         :: non_neg_integer() | nil    nil when any member status is :unknown
  # done_min     :: non_neg_integer()          known done count (a lower bound)
  # pct          :: 0..100 | nil               nil unless every input is known and weight > 0
  # pct_min      :: 0..100 | nil               lower bound; nil when weight == 0 or any complexity is unknown
  # orig, added  :: non_neg_integer()          added = members not in the baseline
  # baseline?    :: boolean()                  false → every member counts as original
  # spark        :: [non_neg_integer()]        the design series
  # also         :: non_neg_integer()
  # reasons      :: [:complexity | :no_weight | :progress | :status]  sorted, unique
end
```

### 4.3 Rules

1. **Members** of a feature = the numbers whose `owners[n].feature` is its
   slug (a map, so no duplicates). A number with no fact gets
   `%{status: :unknown, complexity: :unknown, progress: {:unknown, :missing}}`.
2. **total** = member count. **done_min** = members with status `:done`.
   **done** = `done_min` when no member has status `:unknown`, else `nil` and
   `:status` in `reasons`.
3. **Weight.** `points/1`: `1→1, 2→2, 3→3, 4→5, 5→8` (the design's `PTS`),
   `:unknown → :unknown`. Each member is one of:
   - `:not_planned` and `:closed` (duplicate or unknown close reason): left
     out of the weight sums (§10 decision 2);
   - complexity `:unknown`: left out, `:complexity` in `reasons`;
   - otherwise weight `p` with a fraction in hundredths: `:done`/`:failed`
     → 100; `:running` with `{:known, x}`, `x` an integer in 0..100 → `x`;
     `:running` with anything else → unknown, `:progress` in `reasons`;
     `:queued`/`:open` → 0; `:unknown` → unknown, `:status` in `reasons`.
4. **pct.** `W = Σ p` over weighted members; `N = Σ p × x` over members with a
   known fraction. Unknown fractions add to `W` and not to `N` (a lower bound,
   as `progress.ex:30`).
   - `pct_min = nil` when `:complexity` is in `reasons`: a member with no
     weight can move the figure either way, so no bound is honest.
   - Else if `W == 0`: `pct = pct_min = nil`. `:no_weight` goes in `reasons`
     only here, that is when nothing was left out for an unknown complexity
     (zero owners, or all owners `not_planned`). An all-unknown feature never
     says "no weighted tickets".
   - Else `pct_min = div(2N + W, 2W)`, which is `Math.round(N / W)` (the
     design's `Math.round(wp / w * 100)`) in integers (JS rounds .5 up; all
     values are positive).
   - `pct = pct_min` when `reasons` has none of `:status`, `:complexity`,
     `:progress`; else `nil`.
5. **added / orig.** C6-T01's rule: baseline `:none` → `added = 0`,
   `baseline? = false`. Else `added` = members whose number is not in
   `baseline.members` (`MapSet.member?/2`). `orig = total − added`. A ticket
   in the baseline that left and came back is original. C8-T04 sets each row's
   `added` from C6-T01's `added?`, so the row flag and this count use one rule.
6. **spark.** Times are epoch ms (`DateTime.to_unix(t, :millisecond)`);
   `day = 86_400_000`. `first` = minimum `joined_at` ms. Loop
   `d = first; d <= now + 1; d += day` and count joins `<= d`. Then append
   `total` if the list is empty or its last point differs from `total`. No time
   zone is involved.
7. **also** = distinct numbers `n` with the slug in `also[n]` and `n` not an
   owning member of this feature (C6-T01 invariant 3 already forbids that; the
   filter is a guard).
8. **compute_all/3** takes the registry, the fact map and `now:` (ms, from the
   payload clock). It returns `%{slug => %FeatureStats{}}` for every key of
   `registry.features`, including features with zero owners. A feature whose
   facts are all `:unknown` still returns `total`, `orig`, `added`, `also` and
   `spark`: these come from the registry only.

### 4.4 Public API (PROPOSED)

```elixir
@spec compute_all(registry(), %{pos_integer() => fact()}, now: integer()) :: %{String.t() => t()}
@spec points(1..5 | :unknown) :: pos_integer() | :unknown
@spec fact(Aiur.BuildOrder.History.Row.t() | :missing, status(), progress()) :: fact()
@spec to_json(t()) :: map()   # §4.6 shape; nil stays nil, atoms become strings
```

`points/1` is public so C8-T04 can use it for the row `pts` instead of a second
copy of the table (C8-T04 §4 row table computes `[1,2,3,5,8][cx-1]` inline).

### 4.5 Invariants

- `0 <= done_min <= total`; `done` is `nil` or `done_min`.
- `pct` is `nil` or equal to `pct_min`. Neither is ever a default `0`.
- `:no_weight` and `:complexity` are never both in `reasons`.
- `orig + added == total`.
- `List.last(spark) == total`.
- The same input gives the same output. No clock read: `now` is an argument.

### 4.6 Payload shape (needs a C3-T02 schema change)

C3-T02's schema v1 `features.<key>` is `{key, label, hue, epics, from, to}`
(C3-T02 §"Messages"). It has no place for statistics. This ticket asks for one
required key, `stats`, filled by C8-T04 from `to_json/1`. Its value is that
object or `null` (C10-T03 §4.4 renders `stats: null` as "Feature figures
unavailable"):

```json
"stats": { "total": 12, "done": 7, "done_min": 7, "pct": 64, "pct_min": 64,
           "orig": 10, "added": 2, "baseline": true,
           "spark": [8, 9, 10, 12], "also": 3, "reasons": [] }
```

`null` means unknown (C3-T02 rule: no defaults). In the fixture source, the
C3-T02 body of `mapRawToPayload` (C1-T01's PROPOSED
`src/browser/scripts/build-home-fixture-map.mjs`) fills `stats` from the
design's `featStats` output that the exporter passes in (§5 step 3), mapped to
the server shape: `done_min = done`, `pct_min = pct`, `baseline: true` (the
design marks scope with `added`), and for `total == 0` (the design's
`w ? … : 0`) `pct = pct_min = null` with `reasons: ["no_weight"]`, else
`reasons: []`. The fixture page then shows what the server would send for the
same rows.

## 5. Implementation steps

1. Write `Aiur.BuildOrder.FeatureStats` (about 110 lines) per §4. Use
   `Metadata.parse/1` in `fact/3`. Use integer arithmetic only.
2. Write `src/test/aiur/build_order/feature_stats_test.exs` (§8 V-1..V-14,
   V-16).
3. Extend the C1-T01 exporter (PROPOSED
   `src/browser/scripts/export-build-home-fixtures.mjs`). C1-T01's
   `loadBuildJs` accepts only identifiers in `expose`, and `featStats` reads
   the IIFE's `let D` (J:331), which nothing outside can set. Add one optional
   `prelude` argument to `loadBuildJs`: a fixed source string from the exporter
   (never from a flag or a file), inserted before the `window.__E8` line. The
   exporter passes:
   `const featStatsFor = (k) => { const prev = D; D = dataFor(k); try { return Object.fromEntries(Object.keys(D.features).map((f) => [f, featStats(f)])); } finally { D = prev; } };`
   and adds `"featStatsFor"` to `expose`. A probe of exactly this (Node,
   `vm`, `TZ=America/Los_Angeles`, 2026-10-08, scratch copy) returned all 18
   features of `live`, `dense`, `newrepo` and `noqueue`. Then:
   - write `src/test/fixtures/build_home/feature-stats.json` with `encode` as
     `{ "<dataset>": { "<feature key>": {total, done, pct, orig, added, spark, also} } }`
     for those four datasets (`offline` is `live`);
   - call `mapRawToPayload(dataset(k), { featureStats: featStatsFor(k === "offline" ? "live" : k) })`
     (a second, optional argument; the identity mapper ignores it);
   - add the file to the manifest's `fixture_sha256`, so `--check` covers it.
4. Add `features[k].stats` to `AiurWeb.Build.Payload.validate/1` and fill it
   in the C3-T02 fixture mapper (`mapRawToPayload`) as §4.6 says, in this
   ticket's PR (R-G1; C3-T02 lists it as an accepted additive field).
5. Write `src/test/aiur/build_order/feature_stats_parity_test.exs` (V-15).

## 6. Non-happy paths

| Case | Behaviour | Test |
| --- | --- | --- |
| History store unavailable (C4-T01 `{:error, health}`) | C8-T04 passes `:missing` rows → every status and complexity `:unknown` → `done: nil`, `pct: nil`, `pct_min: nil`, `reasons: [:complexity, :status]` (not `:no_weight`); `total`, `added`, `also` still exact | V-6 |
| Some members have no `complexity:` label | `pct: nil` and `pct_min: nil` (no honest bound without a weight), `reasons ∋ :complexity` | V-16 |
| One running agent without a fresh percent | `pct: nil`, `pct_min` counts it as 0, `reasons: [:progress]` | V-5 |
| Feature with only also-affects tickets (EC-24) | `total: 0`, `done: 0`, `pct: nil`, `reasons: [:no_weight]`, `spark: [0]`, `also: n` | V-8 |
| No baseline (EC-24) | `added: 0`, `orig == total`, `baseline?: false` | V-7 |
| Scope added after the baseline (EC-24) | `added` counts members not in the snapshot; a member removed and re-added after the baseline is not added if its number is in the snapshot | V-7 |
| Feature renamed (EC-24) | Keyed by slug; the label is not an input, so the figures do not change | V-12 |
| More than six features (EC-24) | Computed for every feature; the client picks six (J:1099) | V-11 |
| Focus on a feature with no loaded tickets (EC-24) | Figures come from the registry and the fact map, not the loaded day window | V-11 |
| A number both owning and also-linked (C6-T01 invariant 3 broken) | Not counted in `also` | V-9 |
| Progress outside 0..100 or not an integer | Treated as unknown progress (never clamped to a plausible value; `facts.ex:155` clamps, §10 decision 9) | V-5 |
| Join time after `now` (clock skew) | No loop points for it; the series ends with `total` | V-10 |
| Feature with zero owners | The design gives `pct: 0` (`w ? … : 0`); the server gives `pct: nil`, `:no_weight`. The design datasets have 7 such features (dense d0–d5, newrepo khala); V-15 asserts this deviation, not the design `0` | V-8, V-15 |
| A feature 3 years old | About 1,100 spark points (about 4 KB per feature in JSON). `ponytail:` comment: no cap; C12-T06 measures the payload and adds a cap if needed | — |
| Security, permissions | No input from the browser; no write. The stats are not financial data | — |
| Concurrency, retries | Pure function; C8-T04 recomputes on each coalesced change | — |

## 7. Compatibility and rollout

- New module and tests only, plus a small exporter change (one optional
  `loadBuildJs` argument, one mapper argument) and one new fixture file.
  No config, no migration, no flag, no docs (internal; the user-facing header
  is documented by C12-T07).
- Rollback: revert the commit. Nothing persists.
- The `stats` key is a schema change to C3-T02's v1. If v1 has shipped to a
  browser by then, it is still unreleased (C12-T01 is the cutover), so no
  version bump is needed.

## 8. Verification

PROPOSED `src/test/aiur/build_order/feature_stats_test.exs` (`async: true`,
pure data, no store, no `~/.aiur`). Each test builds a C6-T01-shaped
registry map (§4.1) by hand.

| # | Test | Expected | Fails without |
| --- | --- | --- | --- |
| V-1 | "done counts only done, total counts every owner" | members: done, failed, not_planned, closed, running, queued, open → `total: 7`, `done: 1`; cx 2 closed + cx 2 queued → `pct: 0`, `reasons: []` | rule 2 (counting `failed` as done gives 2); the `:closed` exclusion (treating it as `:unknown` gives `pct: nil`) |
| V-2 | "weighted matches the design formula" | cx 1 done, cx 3 running 50, cx 5 queued → `W = 1+3+8 = 12`, `N = 100+150+0 = 250` → `pct: 21` (`round(20.83)`) | `points/1` (using cx as weight gives `round(250/900·100) = 28`) |
| V-3 | "failed counts as finished weight, not_planned is out" | cx 2 failed + cx 2 not_planned + cx 2 queued → `pct: 50` | the `:not_planned` exclusion (counting it as finished, the design's `hist → 1`, gives 67) |
| V-4 | "half rounds up" | cx 1 running `{:known, 25}` + cx 1 queued → `N = 25`, `W = 2`, 12.5 → `pct: 13` (JS `Math.round(12.5)`) | the integer rounding formula (`div(N, W)` gives 12) |
| V-5 | "unknown progress is never 0 %" | cx 3 running `{:unknown, :stale}` + cx 3 done → `pct: nil`, `pct_min: 50`, `reasons: [:progress]`; and running `{:known, 140}` → same | the unknown branch. **Mutation:** treat unknown progress as `{:known, 0}` → `pct: 50` and the test fails |
| V-6 | "history missing makes done and pct unknown" | 3 owners, every fact `fact(:missing, :unknown, {:unknown, :missing})` → `done: nil`, `done_min: 0`, `pct: nil`, `pct_min: nil`, `reasons: [:complexity, :status]` (no `:no_weight`); `total: 3` | rule 2/3/4. **Mutations:** return `done_min` as `done` → `done: 0`, fails; add `:no_weight` whenever `W == 0` → reasons differ, fails |
| V-7 | "baseline splits original and added" | baseline `%{at: t, members: MapSet.new([1, 2])}`, owners 1, 2, 3 → `orig: 2`, `added: 1`, `baseline?: true`; baseline `:none` → `orig: 3`, `added: 0`, `baseline?: false` | rule 5 (mutation: a missing baseline read as an empty set gives `added: 3`) |
| V-8 | "a feature with only also-affects tickets" | feature `c` with no owners, also `%{7 => ["c"], 8 => ["c"]}` → `total: 0`, `pct: nil`, `reasons: [:no_weight]`, `spark: [0]`, `also: 2` | the `W == 0` branch. **Mutation:** return `0` like the design's `w ? … : 0` → fails |
| V-9 | "owner links are not counted as also" | owners 1, 2 → `f`; also `%{2 => ["f"], 3 => ["f"], 4 => ["g"]}` → `total: 2`, `also: 1` | rule 7 (without the owner filter, `also: 2`) |
| V-10 | "spark follows the design loop" | (a) joins at `now − 2d`, `now − 1d`, `now − 1h` → `[1, 2, 3]`; (b) add a join at `now + 5d` → `[1, 2, 3, 4]`; (c) one join at `now + 5d` only → `[1]` | rule 6. In (a) a bound of `now + day` instead of `now + 1` ms adds a 4th loop point (`[1, 2, 3, 3]`) and fails |
| V-11 | "every registry feature gets figures" | 9 features (one with zero owners), 2,000 owners in total, facts for all → 9 keys in the result, the zero-owner one with `total: 0` | `compute_all/3` iterating `owners` instead of `features` drops the zero-owner feature. Also a size smoke test, not a timing assertion |
| V-12 | "label is not an input" | same feature with `label: "A"` and `label: "B"` → equal structs | — (guard, kept on purpose: future regression) |
| V-13 | "points table" | `points(1..5) == [1,2,3,5,8]`, `points(:unknown) == :unknown` | the table |
| V-14 | "to_json keeps nil and sorts reasons" | `pct: nil` → `"pct" => nil`; reasons `[:progress, :complexity]` → `["complexity", "progress"]`; `baseline?: false` → `"baseline" => false`; the key set is exactly the §4.6 list | `to_json/1` (a `|| 0` fallback fails) |
| V-16 | "unknown complexity gives no lower bound" | owner A cx 1 done, owner B with no `complexity:` label (`fact(row_with_labels(["bug"]), :queued, …)`) → `pct: nil`, `pct_min: nil`, `reasons: [:complexity]` | rule 4. **Mutation:** leave B out of `W` and keep the bound → `pct_min: 100`, fails |

V-15 (parity) in PROPOSED `src/test/aiur/build_order/feature_stats_parity_test.exs`.
The oracle is self-contained, so the test does not depend on C3-T02's row
schema: step 3 writes, per dataset, `now` (`NOW`) and per feature `expected`
(the `featStats` output) plus the inputs it used: `members` as
`{num, sec, status, pct, cx, pts, created, added}` for every row with
`feature === key` (`created` floored to an integer ms), and `also` as the
`num`s of rows with the key in `also`. The probe above measured about 108 KB
of member rows over the four datasets; flooring `created` changed no spark
series. The test builds the registry (owners with `joined_at` = `created`;
baseline members = rows with `added: false`) and the facts through `fact/3`
(a `History.Row` with labels `["complexity:<cx>"]`; `hist` → the row's
`status`, `now` → `:running` with `{:known, pct}`, `plan` → `:queued`, `nq` →
`:open`), runs `compute_all/3` with `now:` and asserts per feature:
- `total`, `done`, `orig`, `added`, `spark` and `also` equal `expected`;
- `pct` equals `expected.pct` when `total > 0`; when `total == 0` (7 features:
  dense d0–d5, newrepo khala) `pct: nil` and `reasons: [:no_weight]` while
  `expected.pct == 0` (the one deliberate deviation, §6);
- `points(cx)` equals every member's `pts`.
It fails if any rule above drifts from J:343–352. The 18 features include no
`failed` member (failed rows sit in `infra`, no feature), so V-3 alone covers
that rule.

**Mutation check (AGENTS.md).** In a worktree with `git status --porcelain`
showing only the intended revert: (a) unknown progress → `{:known, 0}`: V-5
fails; (b) `W == 0` → `0`: V-8 fails; (c) `done` always `done_min`: V-6 fails;
(d) weight = complexity, not points: V-2 and V-15 fail; (e) `day` added to
`now` instead of 1 ms: V-10 fails; (f) unknown complexity left out of `W` with
the bound kept: V-16 fails. Restore; all pass. Put the commands in the PR body.

Commands (isolated HOME and no GitHub tokens):

```bash
env -C /path/to/checkout/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/build_order/feature_stats_test.exs \
                        test/aiur/build_order/feature_stats_parity_test.exs
env -C /path/to/checkout/src/browser mise exec -- npm run check:build-home-fixtures
```

Then the full suite on CI for the head SHA.

**Manual check.** None for this ticket: nothing renders. C10-T03 checks the
header on screen.

## 9. Pixel parity

This ticket draws nothing, so the C1-T02 screenshot harness has nothing of its
own to compare. It decides the **numbers** in these design elements:

- `.bd-fh` → `.bd-kv b` for Done `n/m`, Weighted `n%`, and
  `orig → total <em>+added</em>` (J:1081–1083, C:109–112);
- `svg.sp` polyline points, which C10-T03 computes from `spark` with the
  design's formula (J:1077–1078, 1084; 76 × 22 px, C:113);
- the `+N also affect` chip (J:1086);
- the Feature filter option text `label + "  " + pct + "%"` (J:1099).

Parity is checked two ways:
1. **V-15** proves the server figures equal the design's `featStats` output on
   every design dataset (for zero-owner features, `pct` is `nil` by §10
   decision 10).
2. **C1-T02** side-by-side screenshots of the feature header (C10-T03's
   scenario, `?feature=` focus on the `live` and `dense` datasets) then match
   because the fixture payload carries the same numbers (`feature-stats.json`).

## 10. Decisions made without the owner

1. **Stats are computed on the server, over the whole registry.** The design
   computes them in the browser over `D.all`. The product browser holds only
   loaded days, so the same code there would undercount. The formula is the
   design's.
2. **`not_planned` members are left out of the weighted figure** (both sums).
   `closed` (duplicate or unknown reason) is treated the same: it is not work.
   The design has no `not_planned` state (S-17 adds it). `failed` stays in, at
   full weight, as the design does. This copies the product rule in
   `facts.ex:55-58` (non-work closures are not in the denominator). The design
   datasets have no `not_planned`, so parity is unaffected. `total` (and so
   Done `n/m`) still counts them: it is the registry count, as in the design.
   Kevin may prefer to count them as finished (the design's `hist → 1`) or to
   leave them out of `total` too.
3. **Unknown complexity is left out of the weight, not defaulted to 1.** The
   existing grid and run summary default to 1 (`facts.ex:121`,
   `build_order_grid_model.ex:277`). A default is a plausible value, which
   AGENTS.md forbids for a figure the user reads as exact. `pct` and `pct_min`
   become `nil` and the reason is kept: with a weight unknown (1 to 8 points)
   the true figure can be above or below any bound computed without it.
4. **One unknown progress or status makes `pct` `nil`, with `pct_min` kept.**
   This copies `progress.ex:30-32` (`lower_bound` always, `exact` only when
   complete). Counting an unknown fraction as 0 with a known weight is a true
   lower bound; an unknown weight is not (decision 3).
5. **Scope series uses join time, not created time.** The design uses
   `created` because its mock tickets are created into their feature. A real
   ticket can join a feature long after it was created (C6-T03 imports old
   roots). Only current members count, as in the design; a member that left
   does not lower earlier points.
6. **Rendering an unknown figure is C10-T03's, with no S-item yet.** Default
   proposed for C10-T03: the design's `—` in the same `.bd-kv b`, with the
   reasons in its `title`. This is S-26.
7. **Points use the design's `PTS` table.** The product has only
   `complexity:N` labels; `points/1` is public so C8-T04 can set the row `pts`
   from the same table (today C8-T04 §4 computes it inline).
8. **C1-T01 is a blocker although the README row does not list it.** Step 3
   edits C1-T01's exporter, so it cannot start first. C1-T01 is a level-0
   ticket, so the critical path does not move.
9. **Out-of-range progress is unknown, not clamped.** `facts.ex:155` clamps a
   fresh percent to 0..100. A value such as 140 is a broken input; clamping it
   to 100 shows a plausible figure, which EC-08 forbids. The run summary keeps
   its own rule.
10. **A zero-owner feature reads `pct: nil` with `:no_weight`, not the design's
    `0`.** The design's `w ? … : 0` shows `0%` for a feature with nothing to
    weigh. "0 %" claims no progress, which is not the same as "nothing to
    measure". The only visible effect on the design datasets is focus on
    dense d0–d5 (C10-T02 and C10-T03 render `—`); the C1-T02 header scenarios
    use khala and pag.
11. **`added?` is C6-T01's, not a second copy here.** The first draft had an
    `added?/2`; C6-T01 §4.1 already derives `added?` and C8-T04 reads it from
    there. This module applies the same one-line rule for the count only.
12. **No join-time unknown.** C6-T01 stores `joined_at` on every owner (C6-T03
    passes historical times), so the first draft's `spark_partial` and
    `:joined_at` reason had no source and are removed.

## 11. Completion and handoff

- [ ] `Aiur.BuildOrder.FeatureStats` with the §4.4 API; invariants §4.5 hold.
- [ ] V-1..V-16 pass; each mutation in §8 fails the named tests; the PR body
      lists the commands.
- [ ] `feature-stats.json` is exported and covered by `--check`.
- [ ] No branch returns `0` or a last value for an unknown figure.
- [ ] No docs change (internal); the PR says so.
- **Hand-off notes for neighbours:**
  - **C6-T01:** nothing new. This ticket reads `snapshot/1` as specified
    (§4.1); keep `owners[n].joined_at` required and `baseline: :none` distinct
    from an empty set (C6-T01 V-3).
  - **C1-T01:** Settled 2026-10-08: this ticket adds the optional `prelude`
    argument to `loadBuildJs` and the optional second argument to
    `mapRawToPayload` (§5 step 3).
  - **C3-T02:** Settled 2026-10-08: `features[k].stats` (object or `null`) is
    an accepted additive field; this ticket adds it to `Payload.validate/1`
    and the mapper (§4.6, §5 step 4).
  - **C8-T04** builds facts with `fact/3` and its own status mapping
    (Settled 2026-10-08: `:duplicate` and an unknown close reason → `:closed`),
    passes the C6-T01 snapshot to `compute_all/3` with the payload `now`, may
    set row `pts` with `points/1`, and recomputes on History, Features and
    agent-progress changes. When the features source is unavailable it sends
    no features, so no `stats`.
  - **C10-T03 and C10-T02** read `D.features[k].stats` instead of calling a
    client `featStats` over loaded rows; they render `null` as unknown, never
    `0`.
- **Sources:** tickets/README.md C6 rows (MP-E8-C6-T05), chunks.md MP-E8-C6;
  plan.md §3 (E8-Q6, E8-Q14), §8 (EC-08, EC-24); decisions.md E8-D2, E8-D11,
  E8-R1; questions.md PQ-7; C4-T01 §4.1; C5-T02 §4.1; C6-T01 §4.1, §4.3;
  C3-T02 "Messages"; C1-T01 "Exporter", "Mapping"; C8-T04 §4 row table;
  C10-T02 note 8; C10-T03 §4.4.

## Review log

Adversarial review, 2026-10-08, against `58854d4c8`, design-source and the
neighbour tickets.

1. C6-T01 exists: §2, §4.1 and §11 now read its real `snapshot/1` shape
   (`features`, `owners`, `also`; baseline as a `MapSet`) instead of asking it
   for a new per-feature member list.
2. Removed `added?/2` (C6-T01 already owns the rule; C8-T04 reads it there)
   and `compute/3` (unused by any consumer).
3. Removed `spark_partial`, the `:joined_at` reason and `created_at` in the
   fact: C6-T01 always stores `joined_at`, and `created_at` was read by no rule.
4. Soundness: `pct_min` excluded unknown-complexity members from `W` and still
   called itself a lower bound. It is now `nil` when any complexity is
   unknown (V-16 added).
5. `:no_weight` was set for an all-unknown feature, so C10-T03 would show "No
   weighted tickets" for a history outage. It is now set only when nothing
   was left out for an unknown weight (V-6 made concrete).
6. Probe (Node `vm`, design build.js): 7 of 18 design features have zero
   owners, where the design's `pct` is `0` and the server's is `nil`. V-15
   would have failed; it now asserts that deviation (§10 decision 10). The
   integer rounding matched the design's float rounding on the other 11.
7. Exporter step was not feasible: C1-T01's `expose` accepts identifiers only,
   and `D` (J:331) has no setter. Replaced with a `prelude` argument and a
   probed helper that restores `D`. The mapper gets the stats as an argument.
8. V-15 now reads a self-contained oracle (inputs and outputs) instead of
   C3-T02 rows whose schema is not fixed; flooring float `created` was checked.
9. V-10 could not catch the `now + day` mutation (the extra point equalled
   `total`); new join times make it fail. V-9 and V-11 rewritten for the
   map-shaped input; V-11 now names a real failure.
10. Line fixes: `facts.ex:144-159` (was 144-157), clamp at `:155` noted;
    `build_order_grid_model.ex:273-295`, `:277` (was 274-298, 278).
11. Added MP-E8-C1-T01 to `blocked_by` (§10 decision 8); `stats` may be
    `null` (C10-T03 §4.4); added decisions 9-12 and the C8-T04 status-mapping
    hand-off.
- Reconciliation 2026-10-08 (coordinator): added status `:closed` (duplicate/unknown close reason, R-G11), left out of the weight like `:not_planned` (rule 3, decision 2, V-1); decisions 2, 3, 10 and the unknown figure are S-26; step 4 adds `stats` to `Payload.validate/1` and the mapper in this PR (R-G1); C1-T01, C3-T02, C8-T04 hand-offs marked settled.
