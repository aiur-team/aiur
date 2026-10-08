---
ticket_id: MP-E8-C4-T05
feature_id: MP-E8
chunk_id: MP-E8-C4
bucket: 2-platform
title: Historic edges, children index, order violations
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C4-T02, MP-E8-C4-T04]
complexity: 2
design_gate: DESIGN-E8
design_signoff_items: []
owns_edge_cases: [EC-21]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C4-T05 — Historic edges, children index, order violations

## Identity and outcome

- Bucket 2, feature MP-E8 (home page "Continuous build history"), chunk C4
  (durable history store).
- **User value:** the board draws every `blocked_by` arrow of the repository's
  whole life, not only the open Build Order window. An arrow whose blocked ticket
  merged before its blocker is drawn as a problem (`bad`), not as a clean `ok`.
  An arrow to a ticket that Aiur does not know is never drawn as satisfied, and a
  dependency cycle never hangs the server or the browser.
- **Deliverable:**
  1. PROPOSED pure module `src/lib/aiur/build_order/history/edges.ex`
     (`Aiur.BuildOrder.History.Edges`). From the C4-T01 `snapshot/1` map (rows and
     health) and the configured repository, it builds:
     - the edge list (one entry per native `blocked_by` pair, with the state,
       order and causes);
     - per ticket: `deps` (blockers in the index), `children` (dependents, the
       design's `D.children`, J:288), `dep_states` and `deps_missing`.
  2. `Edges.to_payload/2`, the per-ticket edge fields for the C3-T02 ticket row.
  3. A checked-in "odd edges" fixture (cycle, self-loop, missing blocker, order
     violation, unknown order) for C9-T07 and C9-T11.
- **Non-goals:**
  - No drawing. Edge paths, classes and arrowheads are C9-T07 (J:879-932). The
    chain hover and the tree view are C9-T11 (J:933-985, 1183-1221).
  - No new GitHub reads. The edges come from the `blocked_by` that C4-T02
    (backfill) and C4-T03 (steady-state feed) write. This ticket spends zero
    GraphQL and REST points.
  - No GitHub sub-issue tree. The design's `children` is the reverse of `deps`
    (J:288), not GitHub `parent`/`subIssues`. The row's `parent` field stays as
    it is for C6 (features).
  - No server-side transitive walk. The design walks chains only in the browser
    (`chainOf`, `openTree`). See "Cycles".
  - No cycle edge state. See decision 3.
  - No change to the C4-T01 store. Its `snapshot/1` and `health/1` already give
    everything this ticket reads (C4-T01 §4.3).
  - Not the epic parts of EC-21 ("no epic", "several type labels"). C5-T02 owns
    those (its front matter also lists EC-21; its V-2). This ticket owns the edge
    parts: cycles, edges to tickets not in the index, order violations.

## Dependencies and blockers

- **DESIGN-E8** (explicit go). The `unknown` and `violation` edge looks are a
  design gap, sign-off item S-24; this ticket follows the default in decision 4
  until Kevin answers.
- **C4-T02** (backfill): writes `state`, `state_reason` and `blocked_by` for every
  issue, and marks the store complete when the backfill finishes.
- **C4-T04** (start and end): writes `end` on every row. The order rule compares
  `end` values. This is an extra predecessor that the row does not list (see
  "Interface notes"). Without it, this ticket would copy C4-T04's end rule.
- **C4-T01** (store, transitive): the row shape (C4-T01 §4.1: `lifecycle`,
  `end`, `blocked_by`, `blocked_by_complete`, with `:none`/`:unknown` sentinels
  and no `nil`), `snapshot/1` and `health/1` (§4.3), the PubSub change signal
  and the fail-closed corrupt-file rule (§4.4).
- **C4-T03** (transitive through C4-T04): steady-state `blocked_by` updates.
- Concurrent with: C5, C6, C7 (different files).
- **Successors:** C8-T04 (assembler, puts the fields in the payload), C9-T07
  (edge classes), C9-T11 (chain and tree), C9-T12 (list row counts), C11-T01
  (modal dependency buttons). Rule source: tickets/README.md row C4-T05; plan.md
  §8 EC-21.

## Verified starting point (`58854d4c8`, `/home/everdred/github/everdred/aiur-worktrees/runtime/src`)

- **No history store exists.** `Aiur.BuildOrder.History` is PROPOSED by C4-T01.
  Today `blocked_by` lives only in the ResourceStore `:issue_blocked_by` entries
  that the dispatch gate reads (`lib/aiur/github/bounded_blocked_by.ex:1-40`
  moduledoc), which expire and cover open issues.
- **Edge states to reuse:** `lib/aiur/build_order/edge_state.ex`.
  - `:6` `@type t :: :cleared | :blocking | :terminal_unsatisfied | :unknown | :cyclic`.
  - `:8-11` `classify(lifecycle, health)` returns `:unknown` unless
    `ProviderHealth.usable?(health)`.
  - `:16-22`: open → `:blocking`; closed `:completed` → `:cleared`; closed
    `:not_planned` → `:terminal_unsatisfied`; anything else (for example
    `:duplicate`, `:unknown`) → `:unknown`.
  - `:25-45` `Readiness.from_edges/1` (not used here; the page shows no
    readiness).
- **Lifecycle and health:** `lib/aiur/build_order/lifecycle.ex`.
  - `:65-105` `Aiur.BuildOrder.Lifecycle` (`%Lifecycle{state, state_reason}`).
    This ticket does not call `from_github/2`: the C4-T01 row already stores a
    `%Lifecycle{}` (C4-T01 §4.1 `lifecycle` field), decoded by C4-T01's own
    `from_json/1`.
  - `:1-63` `Aiur.BuildOrder.ProviderHealth`; `:47-51` `usable?/1` is true only
    for `state: :healthy`, `complete?: true` and an integer generation > 0.
- **Current wording of the state:** `lib/aiur_web/build_order_presenter.ex:385`
  says "dependency ended without completion." for `:terminal_unsatisfied`, and
  `:348-357` `edge_state/4` puts `:cyclic` before the lifecycle state. That is
  why this ticket keeps the cause next to the state (AGENTS.md "A collapsed
  cause names the collapse at the source").
- **Cycle-safe walk to reuse if one is ever needed:**
  `lib/aiur/build_order/dependency_chain.ex:43-62` `reachable/2` and its private
  `walk/3` (`:51`) with a visited set. Note: the test file
  `test/aiur/build_order/dependency_chain_test.exs:29` "closures terminate and
  stay deduplicated on cyclic graphs" covers `closures/2`, not `reachable/2`; no
  test covers `reachable/2` on a cycle today.
- **Not reused:** `lib/aiur/build_order/graph_analysis.ex:10` `@max_nodes 100`
  truncates (plan §5.1). `lib/aiur/build_order/graph.ex:4,7-18`
  `Graph.cyclic_nodes/1` drops edges after 10 000 and returns nodes only.
- **Repository match:** `lib/aiur/build_order/bounded.ex:119-130`
  `same_repository?/2` (case-insensitive owner and repository; false unless all
  four values are binaries);
  `lib/aiur/build_order/dependency.ex:59-63` `native?/2` uses it.
- **Ticket id shape:** `lib/aiur/github/issues.ex:986-987` `id` and
  `identifier` are `to_string(number)`.
- **Census (baseline.md §5, 2026-10-06):** 73 native `blocked_by` edges, 31
  blocked issues, 42 blockers, over 1,344 issues. Edges are sparse.

### Design source (read-only)

- J:179 `add` pushes into `all` in creation order, and every row takes `num++`
  (J:180, J:190, J:254, J:260, J:273). So the design's `all` order is ascending
  `num`.
- J:191-194: a history row depends only on a peer with `p.end < t.start`. The
  design data has **no** order violation, no cycle, no self-loop and no missing
  blocker.
- J:264: `deps` of now and plan rows are resolved keys, `filter(Boolean)` drops
  unknown ones.
- J:288: `children[d]` gets every `t.id` whose `t.deps` includes `d`, in `all`
  order.
- Edge class, two sites with the same rule:
  - J:905 (`drawEdges`): ghost → `gh`; blocker `done` → `ok`; blocker `failed`,
    or `t.cue.failed`/`t.cue.blockedChain` → `bad`; else `bl`.
  - J:1206 (`openTree`): the same rule without `gh`.
- Readers of `deps`/`children`:
  - J:903 `vis.get(did)` drops edges to cards that are not rendered;
  - J:933-937 `chainOf`: visited set; `up` checks `D.byId[d]`, `dn` does not
    check `D.byId[c]`;
  - J:1186 `openTree` `dep()`: `depth[x] = 0` before it recurses, so a cycle
    ends;
  - J:1159 list row: `ups = t.deps.length`, `dn = (D.children[t.id] || []).length`;
  - J:1312, J:1419 modal: `ups` filters with `Boolean`, `downs` does **not**
    (`downs.map(...)`, rendered by `downs.map(dep)` at J:1437, then `x.id` in
    `dep` at J:1420 throws on an id that is not loaded).
- Design ids are mock strings `"AIUR-" + num` (J:190, J:254, J:260, J:273). The
  product id is `to_string(number)`; C3-T02 maps `AIUR-N` → `"N"` for the design
  fixtures (C3-T02 line 387).
- J:198 sets `status = "failed"` on one recent `infra` history row (the
  `failedId`). J:282 sets every `cue.failed = null` and `cue.blockedChain` is
  false (J:286), so in the design data the `bad` class comes only from a `failed`
  blocker.
- Edge CSS (C, later rules win): `.bd-e` base faint, solid, 1.5, opacity .75
  (C:183); `.ok` `--good` 1.8 (C:184); `.gh` dash 2 4 (C:186); `.bl` faint, dash
  5 4, 1.5 (C:447, overriding C:185); `.bad` `--block`, dash 5 4, 1.8 (C:449);
  arrowheads C:190, C:448, C:450; Gantt opacities C:451.

## Chosen design

### Inputs

`Edges.build(snapshot, repository)`:

- `snapshot` is the `%{rows: %{number => Row.t()}, health: %ProviderHealth{}}`
  map that C4-T01 `History.snapshot/1` returns in `{:ok, map}` (C4-T01 §4.3).
  C8-T04 calls `build/2` only on `{:ok, _}`; on `{:error, health}` it shows the
  history section as unavailable without calling this module.
- `repository` is the configured `%{owner: String.t(), repository: String.t()}`
  (the same identity C4-T01 checks against the file's `"repository"`).
- From each row (C4-T01 §4.1): `number`; `lifecycle` (`%Lifecycle{}`); `end`
  (`DateTime | :none | :unknown`, derived by C4-T04; there is no `nil`);
  `blocked_by` (`[ref] | :unknown`, ref = `%{owner, repository, number}`);
  `blocked_by_complete` (`boolean | :unknown`).
- Health (C4-T01 §4.4): `state: :unavailable` for every failed load (corrupt,
  rebuilding, unsafe path, version, repository mismatch, not applicable);
  `:healthy, complete?: false` until C4-T02 calls `mark_complete/1`;
  `:healthy, complete?: true` after it. `EdgeState.classify/2` gives a real
  state only when `ProviderHealth.usable?/1` is true (`lifecycle.ex:46-51`).

### Edge entry (server data, not sent whole)

```elixir
%{blocker: ref, blocked: number, state: EdgeState.t(),
  order: :in_order | :violated | :unknown | :not_closed,
  missing: boolean() | nil, causes: [atom()]}
```

Rules, in order:

1. **Store not healthy** (`health.state != :healthy`, which covers a caller that
   passes an error health by mistake) → `{:error, :unavailable}`, never
   `{:ok, empty}`. C8-T04 shows the history section as unavailable (S-9).
2. **Unknown edge list.** A row with `blocked_by: :unknown` adds no edge and its
   `deps_missing` is `nil` (not 0): the blockers are not known yet. A row with
   `blocked_by_complete` not `true` keeps its listed edges but its
   `deps_missing` is `nil` too, because the list may be cut (C4-T02 records
   `blocked_by_complete` from `pageInfo`/`totalCount`).
3. **Dedupe** on `{blocker ref, blocked}` (owner and repository compared
   case-insensitively). Two feeds that write the same pair give one edge.
4. **Self-loop** (native blocker number == blocked number): kept in the list
   with `causes: [:self_loop]`, left out of `deps` and `children` (the design
   would draw a path from a card to itself).
5. **Native check:** a blocker in another repository
   (`Bounded.same_repository?(repository, ref)` is false) or a same-repository
   number with no row in `snapshot.rows` is `missing`.
   - With `complete?: true`: `missing: true`, `state: :unknown`,
     `causes: [:not_in_index]`.
   - With `complete?: false`: `missing: nil` (not known yet), `state: :unknown`.
6. **Blocker state:** `EdgeState.classify(blocker_row.lifecycle, health)`. This
   gives `:unknown` everywhere while the backfill is incomplete, for free. A
   blocker with `%Lifecycle{state: :closed, state_reason: :not_planned}` adds
   the cause `:blocker_not_planned`.
7. **Order** (only for a blocker in the index). An end is "known" only when it
   is a `%DateTime{}`; `:none` and `:unknown` are both "not known". Compare with
   `DateTime.compare/2`, never `>` on structs.
   - blocked ticket not `%Lifecycle{state: :closed, state_reason: :completed}`
     → `:not_closed` (open, reopened, not planned, duplicate, unknown);
   - blocked closed completed and blocker `state: :open` → `:violated`;
   - blocked closed completed and blocker `state: :unknown` → `:unknown`;
   - both ends known and `DateTime.compare(blocker.end, blocked.end) == :gt`
     → `:violated`;
   - both ends known and the compare is `:lt` or `:eq` → `:in_order`;
   - otherwise (a needed end not known) → `:unknown`.
8. **Order violation reuses `:terminal_unsatisfied`:** `:violated` always adds
   the cause `:closed_before_blocker`. It changes the state to
   `:terminal_unsatisfied` only when rule 6 gave `:cleared` or `:blocking`.
   Every `:unknown` state stays `:unknown` (unusable health, or a
   duplicate-closed blocker), so a violation is never claimed on a state the
   server could not classify. `causes` keeps both causes when the blocker was
   also not planned. `:unknown` order never changes the state and never claims
   `:in_order`.

### Per-ticket projection (`to_payload/2`, for the C3-T02 ticket row)

| Field | Value | Design reader |
| --- | --- | --- |
| `deps` | ids (`to_string(number)`) of blockers in the index, no self-loop, ascending number | J:903, J:935, J:1186, J:1206, J:1312, J:1419 |
| `children` | ids of dependents in the index, no self-loop, ascending number (= the design's `all` order) | J:936, J:1159, J:1419 |
| `dep_states` | `%{id => "cleared" \| "blocking" \| "terminal_unsatisfied" \| "unknown"}`, one key per `deps` id | J:905, J:1206 (via C9-T07/T11) |
| `deps_missing` | integer count of missing blockers; `null` while the store is incomplete, or when the row's `blocked_by` is `:unknown` or `blocked_by_complete` is not `true` (rule 2) | J:1159 (via C9-T12) |

- Missing blockers are sent only as a count. No other repository's name or
  untrusted id goes into the payload (EC-30), and the hook has nothing to drop.
- `dep_states` maps to the design classes as follows (C9-T07 and C9-T11, both
  sites): ghost first (J:905 only); `cleared` → `ok`; `terminal_unsatisfied`, or
  the design's cue rule → `bad`; `blocking` → `bl`; `unknown` → the base `.bd-e`
  with no modifier (C:183, faint solid). `unknown` must never map to `ok`.
- On the design data, every `dep_states` value gives the class that the design's
  `d.status` rule gives, so parity holds. The parity test maps design `status`
  to a lifecycle as: `done` → closed `:completed`; `failed` → closed
  `:not_planned` (the only closed-unsatisfied lifecycle `EdgeState` has,
  `edge_state.ex:19-20`); `running`/`queued`/`open` → `:open`. Then done →
  `cleared` → `ok`; failed → `terminal_unsatisfied` → `bad`; open → `blocking`
  → `bl`. The design data has no order violation (J:191 needs `p.end < t.start`),
  so rule 8 never fires there.

### Cycles

- Cycles are allowed in the data and are not rejected. `build/2` is two linear
  passes over the rows (`Enum.reduce`, no recursion), so a cycle cannot loop it.
- This ticket adds no transitive walk on the server. Any later server walk must
  use `DependencyChain.reachable/2` (visited set).
- The browser walks (`chainOf`, `openTree` `dep()`) are C9-T11's code. This ticket
  gives C9-T11 the odd-edges fixture with a 2-cycle, a 3-cycle and a self-loop.

### Recompute, not incremental

`build/2` rebuilds all edges from the rows on each coalesced History change
(C8-T04 coalesces to ≤ 500 ms). One `ponytail:` comment: full rebuild; switch to
an incremental index if C12-T06 measures the rebuild above its budget at 10k
rows.

## Implementation steps

1. Add `edges.ex` with `build(%{rows: rows, health: health}, repository)` →
   `{:ok, %{edges: [...], by_ticket: %{number => projection}}}` or
   `{:error, :unavailable}`, and `to_payload(by_ticket, number)`. A number with
   no projection gives `%{deps: [], children: [], dep_states: %{}, deps_missing: 0}`
   when the store is complete and `deps_missing: nil` when it is not.
2. Pass 1: the rows are already a map by number (C4-T01 `snapshot/1`). Pass 2:
   for each row, for each `blocked_by` ref, apply rules 2-8 and accumulate
   `deps`, `children`, `dep_states`, `deps_missing`. Sort `deps` and `children`
   by number at the end.
3. Add the odd-edges fixture: PROPOSED
   `src/test/fixtures/build_home/odd_edges.json` (the build-home fixture folder;
   the History rows and the expected `to_payload` output). A test keeps the two
   in sync. Register it as the `odd-edges` dataset in C3-T01's fixture list
   (R-G1).
4. Hand `build/2` and `to_payload/2` to C8-T04. Per R-G1, add `children`,
   `dep_states` and `deps_missing` to `Payload.validate/1` and to the C3-T02
   fixture mapper in this PR.
5. Docs: no config key, CLI flag, env var or new surface. The C12 concepts page
   gets one sentence: "An arrow is drawn as a problem when the blocked ticket
   closed before its blocker." If that page does not exist when this ticket
   merges, put the sentence in the PR body for C12 to carry.

## Non-happy paths

| EC-21 case | Concrete input | Expected | Test |
| --- | --- | --- | --- |
| Clean history edge | #10 merged 09-01 10:00, #12 blocked_by #10, merged 09-02 | `:cleared`, `:in_order`; payload `dep_states["10"] == "cleared"` | E1 |
| Order violation | #12 merged 09-01, its blocker #10 merged 09-03 | `:terminal_unsatisfied`, `:violated`, causes `[:closed_before_blocker]` | E2 |
| Blocked closed, blocker still open | #12 completed, #10 open | `:terminal_unsatisfied`, `:violated` (not `:blocking`) | E3 |
| Same moment | both ends 09-01 10:00:00 (one PR closed both) | `:cleared`, `:in_order` | E4 |
| End unknown | #12 closed completed, `end: :unknown`; and a second case with `end: :none` (C4-T04 stores no `nil`) | `order: :unknown`; state stays `:cleared`; not `:in_order`, not `:terminal_unsatisfied` | E5 |
| Missing blocker, store complete | #12 blocked_by `other/repo#4`, and blocked_by #999 with no row | two edges, `missing: true`, `:unknown`; `deps == []`, `deps_missing == 2`; no `children` entry | E6 |
| Store incomplete | backfill running, `complete?: false` | every state `:unknown`; `missing: nil`; `deps_missing: nil` | E7 |
| Store unavailable | corrupt file, health `:unavailable` | `{:error, :unavailable}` | E8 |
| Cycle | #1↔#2, and #3→#4→#5→#3 | build returns; `children["1"] == ["2"]`, `children["2"] == ["1"]`; states classified | E9 |
| Self-loop | #7 blocked_by #7 | edge with `:self_loop`; `deps` and `children` of #7 empty | E10 |
| Duplicate edge | #12 blocked_by #10 written by backfill and by webhook | one edge | E11 |
| Blocker not planned | #10 closed `NOT_PLANNED` | `:terminal_unsatisfied`, causes `[:blocker_not_planned]`; with a violation, both causes | E12 |
| Blocker duplicate-closed | #10 closed `DUPLICATE` | `:unknown` (existing `EdgeState` rule) | E13 |
| Blocked reopened | #12 reopened, #10 open | `:blocking`, `:not_closed` | E14 |
| Blocked not planned | #12 closed `NOT_PLANNED`, #10 open | `:blocking`, `:not_closed` (no violation claim) | E14 |
| Mixed-case repo | ref `Aiur-Team/AIUR#10`, configured `aiur-team/aiur` | native, in index | E6 |
| Blockers not known yet | #12 `blocked_by: :unknown` | no edge; `deps == []`; `deps_missing == nil` (not 0) | E18 |
| Blocker list cut | #12 `blocked_by: [#10]`, `blocked_by_complete: false` | edge to #10 kept; `deps_missing == nil` | E18 |
| Blocker lifecycle unknown | #12 closed completed, #10 `%Lifecycle{}` (`:unknown`/`:unknown`), both ends known | `state: :unknown`, `order: :unknown`; no violation claim | E19 |
| Violation on an unknown state | #12 merged 09-01, #10 closed `DUPLICATE` 09-03 | `state: :unknown` (not `:terminal_unsatisfied`), `order: :violated`, causes `[:closed_before_blocker]` | E19 |

- **Security/privacy:** only numbers and states leave the server. Other
  repositories' names stay in server data (`edges`), never in the payload.
- **Concurrency/idempotency:** `build/2` is pure and runs over a snapshot of the
  rows; the same rows give the same output (E11, E15).
- **Diffs (C8-T04):** a new edge changes two rows (`deps` of the blocked,
  `children` of the blocker). A blocker that closes changes `dep_states` of every
  child. C8-T04 diffs the projection, not only the changed History row.

## Compatibility and rollout

- No config, CLI, env var or migration. No GitHub budget change.
- The store file is not changed by this ticket; the projection is computed, not
  stored. Rollback removes one module and the payload fields. C9-T07 then draws
  every edge with the base `.bd-e` (its class rule step 5: a missing
  `dep_states` gives `""`, and its test U2 asserts it does **not** fall back to
  the design's `status` rule). Edges stay visible but uncoloured; none is shown
  as cleared. C9-T11/C9-T12 treat a missing `deps_missing` as 0 (C9-T11 line 295).

## Verification

Tests (PROPOSED `src/test/aiur/build_order/history/edges_test.exs`, `async: true`,
rows built in the test, no store process, no `~/.aiur`):

| # | Test | Expected | Fails without |
| --- | --- | --- | --- |
| E1 | "an edge whose blocker closed first is cleared and in order" | `:cleared`, `:in_order`, `"cleared"` in payload | the classify call |
| E2 | "a ticket merged before its blocker is an order violation" | `:terminal_unsatisfied`, `:closed_before_blocker` | rule 8 (M1) |
| E3 | "a completed ticket with an open blocker is a violation, not blocking" | `:terminal_unsatisfied` | the open-blocker clause |
| E4 | "equal end times are in order" | `:in_order` | `:eq` counted as in order (M2) |
| E5 | "an unknown or none end gives unknown order and keeps the blocker state" | for `end: :unknown` and `end: :none`: `order == :unknown`, `state == :cleared` | the not-known clause (M3) |
| E6 | "missing and external blockers are kept as data and counted" | 2 edges `missing: true`, `deps == []`, `deps_missing == 2`; mixed-case ref is native | rule 5 (M4, M7) |
| E7 | "an incomplete store reports unknown, never cleared or zero missing" | all `:unknown`, `deps_missing == nil` | the health argument (M5) |
| E8 | "an unavailable store is an error, not an empty graph" | `{:error, :unavailable}` | rule 1 (M6) |
| E9 | "cycles build, with children both ways" (future-regression guard: there is no recursion today; named so) | as table | — |
| E10 | "a self-loop stays in the edges and leaves deps and children" | as table | rule 4 |
| E11 | "duplicate pairs give one edge" | `length(edges) == 1` | rule 3 |
| E12 | "a not-planned blocker keeps its cause, with a violation both causes" | causes list | the causes accumulation |
| E13 | "a duplicate-closed blocker is unknown" (future-regression guard on `EdgeState`) | `:unknown` | — |
| E14 | "a reopened or not-planned blocked ticket makes no order claim" | `:not_closed`, `:blocking` | the `:not_closed` clause |
| E15 | "design parity: children and classes equal the design data" (see Pixel parity) | equal for `live`, `dense`, `newrepo`, `noqueue` | the sort order, the state mapping |
| E16 | "odd-edges fixture matches to_payload" | JSON equal | any rule change not mirrored in the fixture |
| E18 | "unknown or cut blocker lists report an unknown missing count" | both rows of the table: `deps_missing == nil` | rule 2 (M8) |
| E19 | "an unknown blocker lifecycle never yields a violation state" | both rows of the table | rule 7 `:unknown` clause and rule 8 guard (M9) |
| E17 | contract test with the C3-T02 schema | `deps`/`children` string lists; `dep_states` keys == `deps`; `deps_missing` integer or null | `to_payload/2` |

**Mutation checks (AGENTS.md "Tests must fail without the production change"):**
- M1: delete rule 8 (violation leaves the state from classify) → E2 and E3 fail.
- M2: treat `:eq` as `:violated` → E4 fails.
- M3: replace the `:unknown` order with `:in_order`, then treat `:none` as a known end of epoch 0 → E5 fails both times.
- M4: give a missing blocker `state: :cleared`, then `deps_missing: 0` → E6 fails
  both times.
- M5: call `classify` with a fixed healthy `ProviderHealth`, then set
  `deps_missing: 0` when incomplete → E7 fails both times.
- M6: return `{:ok, %{edges: [], by_ticket: %{}}}` on `:unavailable` → E8 fails.
- M7: replace `Bounded.same_repository?/2` with `==` on the maps → the
  mixed-case case in E6 fails.
- M8: count `:unknown`/incomplete lists as 0 missing → E18 fails.
- M9: let rule 8 override `:unknown`, then let a blocker with unknown state
  count as open → E19 fails both times.
- Run each in a worktree. `git status --porcelain` must show only the reverted
  hunk. Put the commands and results in the PR body.

Command (isolated HOME, per the "mix test clobbers agent-token" note):

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/build_order/history/edges_test.exs
```

Scale check (not a unit test, recorded in the PR body): `build/2` on 10 000
generated rows with 20 000 edges, wall time with `:timer.tc/1`, so C12-T06 has
a number for its T4 budget (`Edges.build/2` ≤ 300 ms, C12-T06 line 224).

## Pixel parity

This ticket draws nothing. It decides which arrows exist and which class each
gets, so it is checked against the design data through C1's harness:

- **Design elements fed:** `D.children` (J:288), `t.deps` (J:191-194, J:264),
  the edge classes `.bd-e.ok/.bl/.bad/.gh` and `.bd-ea.*` (C:183-190,
  C:447-451) through the rules at J:905 and J:1206, the list-row counts (J:1159),
  and the modal dependency buttons (J:1419).
- **Check 1, data parity (E15):** C1-T01 exports `live`, `dense`, `newrepo` and
  `noqueue`. The test turns each design ticket into a History row (`number` =
  `num`; `lifecycle` from `status` by the mapping in "Per-ticket projection";
  `end` as a `DateTime` from the design `end`, or `:none` for open rows;
  `blocked_by` = the `deps` ids `AIUR-N` → `%{owner, repository, number: N}` in
  the configured repository; `blocked_by_complete: true`), runs `build/2` with
  `ProviderHealth.new(1, :healthy, true)`, and asserts, after mapping the design
  ids `AIUR-N` → `"N"` (as C3-T02 does):
  - `to_payload(..).children` equals the exported `children[id]`, same order,
    for every id;
  - `to_payload(..).deps` equals the exported `deps`, as a set (the design keeps
    insertion order; the class does not depend on it);
  - each `dep_states` value maps to the class that J:905 gives from `d.status`,
    with the cue rule left out;
  - `deps_missing == 0` everywhere (the design has no missing blocker).
  Same data in, so C1-T02's screenshot of the product at the real-source route
  (C8-T04) must match the design, with zero diff above the recorded anti-aliasing
  floor, at 1440/1024/390 px, dark and light, `TZ=America/Los_Angeles`, frozen
  `NOW` (J:11).
- **Check 2, states the design lacks:** the odd-edges fixture (E16) is rendered by
  C9-T07 and C9-T11. C1-T02's element mode captures `svg.bd-edges` for the
  violation (`bad`), the `unknown` edge (base `.bd-e`), the cycle and the tree
  view. These screenshots go to Kevin's DESIGN-E8 sign-off (S-24). Until signed off,
  they are the baseline, and a change to them is a failing check.
- Any difference not approved by Kevin in writing is a failing test.

## Completion and handoff

- [ ] `Edges.build/2` and `to_payload/2` follow rules 1-8; E1-E19 pass.
- [ ] M1-M9 fail as stated; commands in the PR body.
- [ ] Odd-edges fixture checked in and used by C9-T07 and C9-T11.
- [ ] Pixel-parity check 1 passes; check 2 screenshots attached for sign-off.
- [ ] Scale number in the PR body.
- [ ] Docs sentence placed (step 5).
- **Dependents:** C8-T04, C9-T07, C9-T11, C9-T12, C11-T01.

### Interface notes for neighbours

- **README row vs. predecessors:** Settled 2026-10-08: the order rule needs
  `end` from C4-T04, so this ticket waits on C4-T02 and C4-T04 (front matter).
- **C4-T01** already gives what this ticket reads: `snapshot/1` and `health/1`
  (§4.3), `blocked_by` as refs (§4.1), `lifecycle` as `%Lifecycle{}`, and `end`
  with `:none`/`:unknown` sentinels. No change to C4-T01 is asked.
- **C4-T02** Settled 2026-10-08: it calls `mark_complete/1` when the backfill
  finishes, and sets `blocked_by_complete: false` while a `blockedBy` list over
  100 is still being paged. Rule 2 then reports the missing count as unknown.
- **C3-T02** Settled 2026-10-08: `children`, `dep_states` and nullable
  `deps_missing` are accepted additive fields owned by this ticket (step 4).
- **C8-T04:** its README row does not list C4-T05, but its ticket file adds it
  to `blocked_by` (C8-T04 decision 13). It is the only caller of `build/2` and
  `to_payload/2`, passes the `snapshot/1` map and the configured repository, and
  must diff the projection (see Non-happy paths).
- **C9-T07 / C9-T11:** both class sites (J:905, J:1206) must read `dep_states`
  with the mapping above and map `unknown` and a missing `dep_states` to the base
  `.bd-e` (C9-T07 class rule steps 1-5 already do this; no fallback to the
  design's `status` rule). `chainOf` `dn` (J:936) must check `D.byId[c]`
  like `up` does, because the server's `children` can name a ticket outside the
  loaded window; otherwise `openTree` (J:1186) reads `D.byId[x].deps` of
  `undefined`.
- **C9-T12:** list-row `ups` (J:1159) is `deps.length + deps_missing`. With
  `deps_missing: null` it must show an unknown marker, not the in-index count
  alone. `dn` counts the server `children`, which includes dependents not loaded.
- **C11-T01:** modal `downs` (J:1419) must `filter(Boolean)` like `ups`, or fetch
  the missing rows. The design code throws on an id that is not loaded.
- **C7-T01:** if the planned-row cue walk (the design's `failedDeps`, J:279) is
  done on the server, it must use `DependencyChain.reachable/2`.

## Decisions made without the owner

1. **An order violation is "the blocked ticket closed completed while its blocker
   was open, or before the blocker's end"**, compared on C4-T04's `end`. Equal ends
   are in order (one PR that closes both tickets gives the same `merged_at`).
2. **The cause is kept next to the reused state.** The row asks to reuse
   `:terminal_unsatisfied`; it does, and `causes` says why
   (`:closed_before_blocker`, `:blocker_not_planned`), so no consumer reads a
   violation as "dependency ended without completion".
3. **No `:cyclic` edge state.** The design has no cycle look, and the current
   presenter's `:cyclic`-first rule would hide the lifecycle colour. Cycles are
   classified like any other edge and only the walks guard them.
4. **`unknown` edges use the base `.bd-e` style** (faint, solid). The design has
   no unknown class; `bl` would claim "blocked" and `ok` would claim "satisfied".
   This is a design gap, sign-off item S-24 (with the violation look).
5. **Missing blockers are sent as a count, not as ids.** This keeps other
   repositories' names out of the payload and gives the hook nothing to drop.
   Server data still keeps each one with `missing: true`, as the row asks.
6. **Self-loops stay in the data and leave the drawing.** The design would draw a
   card-to-itself path.
7. **`children` and `deps` are sorted by ascending number.** In the design, `all`
   order is ascending `num` (J:179-180), so this matches; E15 proves it.
8. **Until the backfill is complete, every edge is `unknown` and the missing count
   is `null`.** Before the backfill finishes, "not in the index" can mean "not
   loaded yet".
9. **A duplicate-closed blocker stays `unknown`**, as `EdgeState` says today. The
   work moved to another issue, which this ticket does not follow. A violation
   against it is recorded as a cause only (rule 8).
10. **An unknown or cut `blocked_by` list gives `deps_missing: null`.** A count
    of 0 would claim "no missing blockers" when the list was never read or was
    cut at 100.
11. **The design's `failed` status maps to closed `:not_planned` in the parity
    test.** It is the only closed lifecycle that `EdgeState` classifies as
    `:terminal_unsatisfied`, which is what gives the design's `bad` class.
12. **`build/2` takes the snapshot map and the configured repository**, not a
    row list and a health. The native check needs the repository, and
    `snapshot/1` already returns rows and health together, so the arity stays 2
    and C8-T04's call is unchanged.

## Review log

Adversarial review, 2026-10-08, against `runtime/src` at `58854d4c8`, the
design source, C4-T01, C4-T04, C8-T04, C9-T07 and C3-T02:

1. Inputs rewritten to the C4-T01 row: `lifecycle` (not `state`/`state_reason`),
   `end` as `DateTime | :none | :unknown` (no `nil`), `blocked_by` may be
   `:unknown`, `blocked_by_complete`. Rule 6 now reads `row.lifecycle`; the
   `Lifecycle.from_github/2` call is gone.
2. Order rule uses `DateTime.compare/2`; `:none` and `:unknown` ends are "not
   known"; a blocker with unknown lifecycle gives `:unknown` order.
3. New rule 2 (unknown or cut `blocked_by` → `deps_missing: nil`), with E18 and
   M8. Rules renumbered 1-8; test and mutation references updated.
4. Rule 8 no longer turns an `:unknown` state into `:terminal_unsatisfied`;
   E19 and M9 added.
5. `build/2` signature changed to `(snapshot, repository)`: the native check
   needed a repository that the old signature did not have. Mixed-case test now
   has a mutation (M7).
6. Removed scope creep: step 3 "add `History.health/0`" and the C4-T01
   interface ask. C4-T01 already defines `health/1` and `snapshot/1`.
7. Rollback text and the C9-T07 interface note now match C9-T07 (missing
   `dep_states` → base `.bd-e`, no `status` fallback, its U2).
8. Line fixes: J:906 → J:905, J:1204 → J:1206, `bounded.ex:119-130`,
   `dependency_chain.ex:43-62`; added J:1437, J:198, J:282-286 and the
   `AIUR-N` id format. The cited cycle test covers `closures/2`, not
   `reachable/2`; said so.
9. Parity test (E15) now states the status → lifecycle mapping and the id
   mapping, and that rule 8 never fires on design data.
10. C8-T04 note corrected (its ticket already lists C4-T05). EC-21 epic parts
    marked as C5-T02's. Scale check tied to C12-T06 T4 (≤ 300 ms).

Verified unchanged: `edge_state.ex:6-22`, `lifecycle.ex:1-105`,
`build_order_presenter.ex:348-357, 385`, `graph_analysis.ex:10`,
`graph.ex:4,7-18`, `dependency.ex:59-63`, `issues.ex:986-987`,
`bounded_blocked_by.ex:1-40`; design J:11, 179-194, 264, 288, 903, 933-937,
1159, 1186, 1312, 1419; CSS C:183-190, 447-451; S-9. `blocked_by` front matter
(adds C4-T04 to the README row) kept: rule 7 needs C4-T04's `end`.
- Reconciliation 2026-10-08 (coordinator): odd-edges fixture moved to `src/test/fixtures/build_home/` and registered as the `odd-edges` dataset; R-G1 step for `children`/`dep_states`/`deps_missing`; edge looks `unknown` and `violation` named S-24; interface notes for predecessors, C4-T02 and C3-T02 settled.
