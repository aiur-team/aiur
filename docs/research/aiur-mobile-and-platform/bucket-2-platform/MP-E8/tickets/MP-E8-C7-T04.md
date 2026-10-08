---
ticket_id: MP-E8-C7-T04
feature_id: MP-E8
chunk_id: MP-E8-C7
bucket: 2-platform
title: Not-queued rows
status: blocked
blocked_by: [DESIGN-E8, MP-E1-C6-T01]
complexity: 2
design_gate: DESIGN-E8
owns_edge_cases: [EC-04]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C7-T04 — Not-queued rows

> Cites code at `origin/main` `58854d4c8` (runtime worktree
> `aiur-worktrees/runtime/src`). Paths marked PROPOSED do not exist yet. If MP-R1
> has moved `build_order/` or `open_ticket_source.ex` before this starts,
> re-resolve the symbols below (CR-E8-6 places the home page's stores in
> `build-orders`). `J` = `design-source/assets/build.js`, `C` =
> `design-source/assets/build.css`.

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C7
  (planned, not-queued and estimates), ticket T04.
- **User value.** The last section of the home page lists every open ticket that
  nobody will run: it is not in a build queue and carries no agent state. The
  operator sees the backlog that is waiting for a decision, and how big it is
  ("Not queued · 63 open · not in the queue"). The Units page's Tickets panel
  showed the same backlog; it retires with Units (options §5).
- **Deliverable.** One pure module, PROPOSED `src/lib/aiur/build_order/not_queued.ex`
  (`Aiur.BuildOrder.NotQueued`), and its test file. `build/3` takes the
  open-ticket snapshot, the MP-E1 queue read model and the set of tickets that
  the now band already shows. It returns the section state plus the not-queued
  rows in design order, with the fields this section owns (`num`, `title`, `cx`,
  `pts`, `created`, `sec`, `status`, `ord`).
- **Scope.**
  - The membership rule (§4.1).
  - The order (§4.2).
  - The section state: ok, stale, unavailable, unsupported, with named reasons
    (§4.3).
  - No row cap. Several hundred rows are returned in full (EC-04).
- **Non-goals.**
  - No rendering. The card is C9-T05 (`nq` content, J:862). The section header,
    the list view and the empty and unavailable markers are C9-T03, C9-T12 and
    C9-T13.
  - No epic, feature, type, `also`, `added`, `deps` or `pr` fields. C8-T04 joins
    them for every section from C5-T02, C6 and C4-T05.
  - No "Add to queue" button (C11-T02) and no queue writes.
  - No chips for `needs-triage`, `human:todo`, `agent:paused` or `agent:parked`.
    Options §3.3 suggested them, but the design's `nq` card has none (J:862), and
    the design is the specification (Decision 3).
  - No subscription and no diffing. C8-T04 calls `build/3` when a source changes.

## 2. Dependencies and blockers

- **DESIGN-E8** (every MP-E8 ticket). The only design gap here is the copy for a
  truncated open-ticket listing (Decision 5). The unavailable copy follows S-9.
- **MP-E1-C6-T01** (`Aiur.BuildQueue.show/1`, contract §3). Queue membership comes
  only from that read model. Until it ships, the queue argument is a fixture in
  tests, and C8-T04 cannot wire the real call.
- **MP-E8-C4-T01 is not a predecessor** (the row lists it; Decision 1). The open
  set comes from `Aiur.OpenTicketSource`, which exists on main, is complete after
  one listing, and does not wait for the history backfill.
- **Shared contracts.** Consumes `contracts/queue-readiness-and-build-progress.md`
  §1 rule 4 (unknown is not zero), §2.3 (item states) and §3 (read model). Owns none.
- **Successors.** C8-T04 (joins the rows into `sections.nq`, maps the state to
  `sources`, and reuses `points/1` for the `pts` of the other sections instead of
  its own inline `[1,2,3,5,8]` table, C8-T04 "Row assembly"); C9-T13 (renders
  the unavailable state). C7-T01 does not compute `pts` (its non-goals leave
  `cx`/`pts` to C8-T04), so it is not a consumer of `points/1`.
- **Concurrent with.** C7-T01, C7-T02, C7-T03 (different files). C7-T01 §4.6
  already places the `agent:todo` tickets that this ticket excludes, using the
  same todo-label rule (§8 interface notes).

## 3. Verified starting point (`58854d4c8`)

| What | Where | Use here |
| --- | --- | --- |
| Open-ticket projection | `lib/aiur/open_ticket_source.ex:1-44` moduledoc: event-sourced from `ResourceStore`, one listing per boot, no steady-state GitHub reads | The open set. No new polling (EC-32) |
| Snapshot read | `open_ticket_source.ex:78-84` `snapshot/1`; on a dead server (`catch :exit`, `:82-83`) it returns the default `%Snapshot{}` (`status: :unavailable`, `snapshot.ex:43`) | Input 1. C8-T04 calls it |
| Labels in the projection | both paths lowercase: the listing (`:317`) and `apply_issue_change/2` (`:214-226`) go through `Issues.normalize_issue/4`; `update_held_labels/2` (`:233`) uses `label_names/1` (`:246-247`, `String.downcase`) | Compare against a lowercased prefix |
| Snapshot struct | `lib/aiur/open_ticket_source/snapshot.ex:20` `status :: :available \| :stale \| :unavailable \| :unsupported`; `:22-33` ticket map (`identifier`, `title`, `labels`, `created_at`, `state`); `:35-43` `generation`, `observed_at`, `truncated?` | The fields read |
| Status rule | `open_ticket_source.ex:421-423` `snapshot_status/1`: `:available` only after a successful listing; `:stale` when it holds tickets without one; else `:unavailable` | Mapped to the section state, never to "empty" |
| Page budget | `open_ticket_source.ex:58` `@max_pages 10` (100 per page, `:294`); `truncated?` set at `:380-381` | Truncation is passed on, not hidden (Decision 5) |
| Ticket shape | `open_ticket_source.ex:341-353` `ticket/1`; labels come from `lib/aiur/github/issues.ex:1013` (downcased) | Labels are lowercase |
| Existing sort | `open_ticket_source.ex:425-432` `sort_key/1`, number descending ("newest first") | Not used. The design order is ascending (§4.2) |
| Tickets panel | `lib/aiur_web/operator_control_center/tickets_presenter.ex:1-16` (stale or unavailable is named, never an empty table); `:66-71` drops rows without a joinable identity | Same honesty rule; same drop rule |
| Child and topic | `lib/aiur.ex:455` `{Aiur.OpenTicketSource, …}`; `open_ticket_source.ex:88` `subscribe/0`; `lib/aiur_web/live/dashboard_live.ex:119` subscribes today | C8-T04 subscribes the same way |
| State labels | `lib/aiur/github/labels.ex:25` `@state_suffixes ~w(todo in-progress ci-wait human-review rework merging done error cancelled canceled)`; `:31-35` marker suffixes (`watch`, `paused`, `parked`, `rate-limit-fallback`); `:55-56` `state_labels/1` | The "agent state" set |
| Terminal states | `lib/aiur/github/state_policy.ex:22-32` `terminal_state_label?/2`, `terminal_state_name?/1` (`done`, `cancelled`, `canceled`) | Terminal labels do not count as active |
| Label prefix | `lib/aiur/github/config.ex:309-325` `label_prefix/0` (default `"agent"`, trimmed) | Default for the `:label_prefix` option |
| Complexity | `lib/aiur/build_order/metadata.ex:9` `complexity :: 1..5 \| :unknown`; `:21-63` `parse/1` (missing, invalid or two `complexity:` labels → `:unknown`); `:99-100` `parse_complexity/1` | `cx`. Reused, not re-parsed |
| Points table | none on the server (searched `lib/` for `[1, 2, 3, 5, 8]` and `story_points`) | New `points/1` (§4.4) |
| Test pattern | `test/aiur/open_ticket_source_test.exs:19-31` builds snapshots from fake pages | Fixture shape for the tests |

**Design source** (read-only, research pack `design-source/`):

- J:265-275: the mock builds 22 `nq` rows (6 for `newrepo`). Each has
  `sec: "nq"`, `status: "open"`, `pct: 0`, `deps: []`, `cx`, `pts: PTS[cx - 1]`,
  and no `agent`, `start`, `est` or `cue` key. `num` increases with each row
  (`num++`). `created` is random noise (`NOW - r() * 20 * DAY`).
- J:93: `const PTS = [1, 2, 3, 5, 8];`.
- J:357: `NQL = D.nq.filter(epicOk)`. J:529-532: `rows(entries(NQL), …)` lays the
  rows out in array order. Nothing sorts `D.nq` (every use: J:357, 660, 689,
  1172).
- J:660: header `"Not queued <em>" + D.nq.length + " open · not in the queue</em>"`
  (the total, not the epic-filtered count).
- J:862: card status `Open · not queued` | `N pts`.
- J:499: the planned-empty marker says `NQL.length + " open tickets are not queued"`.
- J:333 `tstate` → `"open"`; J:1101 filter option `["open", "Not queued"]`;
  J:1152-1153 `stClass` `open`, `stText` "Not queued"; J:1177 list section
  `"Not queued", nq.length + " open"`; J:1379 modal label "Not queued"; J:1438
  "Add to queue" only on `nq` rows.

## 4. Chosen design

### 4.1 Membership

A ticket from the open-ticket snapshot is **not queued** when all of these are
true:

1. Its `identifier` parses as a positive integer and its `title` is a binary.
   Otherwise it is skipped and counted (`skipped`), as `TicketsPresenter` drops
   rows it cannot address.
2. It is not a queue item: its number is not in any `queues[].items[].number` of
   the read model, ignoring items whose `state` is `removed`, `completed` or
   `cancelled` (contract §2.3: those carry no marker or are closed).
3. It carries no active agent state label: no label in
   `Labels.state_labels(prefix)` that is not terminal
   (`StatePolicy.terminal_state_label?/2`). So `agent:todo`, `in-progress`,
   `ci-wait`, `human-review`, `rework`, `merging` and `error` exclude it, and
   `agent:done` or `agent:cancelled` on an open issue do not. Markers (`paused`,
   `parked`, `watch`, `rate-limit-fallback`) are not states (`labels.ex:31-35`).
4. Its number is not in `:active` (the numbers the now band shows, from C8-T01).
   This covers a running agent whose labels have not arrived yet, so a ticket is
   never in two sections.

`agent:todo` outside a queue is **planned**, not here (options §3.3: the
dispatcher will run it).

### 4.2 Order

Ascending issue number. `ord = num` (C3-T02's sort key; ties cannot happen).
GitHub numbers increase with creation, so this is oldest first, and it is the
order the design shows: J:273 assigns increasing `num`, and the layout keeps the
array order (J:531). The row's text says "newest first, as the design's order
shows", but the design's order is ascending; see Decision 2.

### 4.3 Section state

```elixir
# PROPOSED lib/aiur/build_order/not_queued.ex
@type state :: :ok | :stale | :unavailable | :unsupported
@type result :: %{
        state: state(),
        reasons: [atom()],            # every cause, never collapsed (AGENTS.md)
        observed_at: DateTime.t() | nil,  # the older of the two inputs
        truncated?: boolean(),
        skipped: non_neg_integer(),
        rows: [row()]                 # [] whenever state is :unavailable or :unsupported
      }
@type row :: %{
        num: pos_integer(), title: String.t(), cx: 1..5 | nil, pts: 1 | 2 | 3 | 5 | 8 | nil,
        created: DateTime.t() | nil, ord: pos_integer(), sec: "nq", status: "open"
      }
@spec build(Aiur.OpenTicketSource.Snapshot.t(), queue_read_model :: map() | term(), keyword()) :: result()
#   opts: :active (MapSet of pos_integer, default empty), :label_prefix (default GitHub.Config.label_prefix/0)
@spec points(1..5 | :unknown | term()) :: 1 | 2 | 3 | 5 | 8 | nil
```

| Open snapshot `status` | Queue `status` (contract §3) | `state` | `reasons` | `rows` |
| --- | --- | --- | --- | --- |
| `:available` | `running` or `writes_paused`, worst `sources.*.freshness` `current` | `:ok` | `[]` | computed |
| `:available` | `disabled` or `unsupported_tracker` | `:ok` | `[:queue_disabled]` or `[:queue_unsupported]` | computed; nothing is queued |
| `:stale` | any usable status | `:stale` | `[:open_tickets_stale]` | computed |
| any usable | `running`/`writes_paused`, worst freshness `stale` | `:stale` | `[:queue_stale]` | computed |
| any usable | `running`/`writes_paused`, any freshness `unknown`, or `sources` missing or empty | `:stale` | `[:queue_freshness_unknown]` | computed |
| `:unavailable` | any | `:unavailable` | `[:open_tickets_unavailable]` | `[]` |
| any | `store_unavailable` | `:unavailable` | `[:queue_unavailable]` | `[]` |
| any | `{:error, _}` (C8-T04's `show/1` call timed out, exited or raised) | `:unavailable` | `[:queue_read_failed]` | `[]` |
| any | any other term: not a map, or a status outside the five | `:unavailable` | `[:queue_status_unknown]` | `[]` |
| `:unsupported` | any | `:unsupported` | `[:tracker_unsupported]` | `[]` |

- "Usable" means a status that gives rows: open `:available`/`:stale`, queue
  `running`/`writes_paused`/`disabled`/`unsupported_tracker`.
- Freshness is the worst over **every** `sources.*` entry, not only
  `tracker_observation`: membership reads the items of every queue, and a
  `build_order:<root>` source can be stale while the tracker is current. This is
  the same rule as C7-T01 §4.5, so the planned and not-queued heads never
  disagree about one read model. It is read only for `running` and
  `writes_paused`; `disabled` and `unsupported_tracker` carry no sources.
- Reasons accumulate: a stale snapshot and a stale queue give both.
  `:unavailable` wins over `:stale`; `:unsupported` wins over all.
- `observed_at` is the older of `snapshot.observed_at` and the oldest
  `sources.*.observed_at` of the read model (C7-T01 §4.5), not
  `snapshot.captured_at`, which is the capture time. If any of them is missing
  (or the queue is `running`/`writes_paused` with no sources), it is `nil` (age
  unknown, never "now"). For `disabled` and `unsupported_tracker`, it is
  `snapshot.observed_at`.
- **Key encoding.** Contract §3 is JSON. Read `Aiur.BuildQueue.show/1`'s map with
  the same keys C7-T01 reads (atom keys and atom statuses, C7-T01 §4.5:
  `status: :running`). If MP-E1-C6-T01 ships string keys, both tickets change
  together; do not accept both encodings here. The encoding question is
  CR-E8-12.
- **Why `store_unavailable` gives no rows.** Without the read model, any open
  ticket might be queued. Listing it as "not queued" would be a confident lie.
  `disabled` is different: no queue exists, so nothing is queued.

### 4.4 Points

`points/1` maps complexity 1..5 to the design's `PTS` (J:93): 1, 2, 3, 5, 8.
Anything else (`:unknown`, `nil`, 0, 6) returns `nil`. `cx` is
`Metadata.parse(labels).complexity`, with `:unknown` sent as `nil`. Unknown
complexity never becomes `1 pts` or `0 pts`.

### 4.5 Invariants

- No cap: `length(rows)` equals the eligible count for any input size.
- `build/3` is pure and deterministic: the same inputs give the same result.
- A number in `rows` is never a queue item, never in `:active`, and never
  carries an active state label.

## 5. Implementation steps

1. PROPOSED `src/lib/aiur/build_order/not_queued.ex`, about 90 lines:
   - `@pts {1, 2, 3, 5, 8}` and `points/1`.
   - `build/3`: decide the state from §4.3 first. If `:unavailable` or
     `:unsupported`, return with `rows: []`.
   - Otherwise build `queued = MapSet` of item numbers (skip `removed`,
     `completed`, `cancelled`). Lowercase the prefix once, `p =
     String.downcase(prefix)`, and use `p` in **both** calls:
     `active_labels = Labels.state_labels(p) |> Enum.reject(&StatePolicy.terminal_state_label?(&1, p)) |> MapSet.new()`.
     Projection labels are lowercase (§3), and `terminal_state_label?/2` strips
     the prefix with `String.replace_prefix/3` (`state_policy.ex:23-27`), so a raw
     `"Bot"` prefix would not strip from `"bot:done"`: `agent:done` would then
     count as active and drop the ticket.
   - One `Enum.reduce` over `snapshot.tickets`: parse the number with
     `Integer.parse/1` (must be `{n, ""}` and `n > 0`), check the title, apply
     §4.1 rules 2-4, map to a row. Then `Enum.sort_by(& &1.num)`.
2. PROPOSED `src/test/aiur/build_order/not_queued_test.exs` with the cases in §8.
   Snapshots are built as `%Snapshot{}` structs directly. The queue read model is
   a literal map in the contract §3 shape.
3. No other file changes. C8-T04 calls `build/3`, maps `rows` into
   `sections.nq` (adding `id`, epic and the other joined fields), and maps
   `state`/`reasons`/`observed_at`/`truncated?` into the payload (§8 interface
   notes).

## 6. Non-happy paths

- **Open-ticket source down or never listed.** `snapshot/1` returns the default
  `%Snapshot{status: :unavailable}` (`open_ticket_source.ex:83-84`) →
  `:unavailable`, never an empty `:ok` section.
- **Queue store unavailable, or an unknown status string.** `:unavailable` with
  the named reason (§4.3).
- **Non-GitHub tracker.** The snapshot is `:unsupported` → `:unsupported`. C9-T13
  shows the S-9 marker with that reason, not "0 open".
- **Stale inputs.** Rows are returned with `:stale` and `observed_at`. The age is
  rendered by C8-T03 and C9-T13 (EC-07); this ticket only supplies the time.
- **Truncated listing** (more than 1,000 open issues, `@max_pages 10`). The rows
  are a prefix of the open set, so `truncated?: true` is passed on, and the header
  count is not exact (Decision 5).
- **Malformed tickets** (non-numeric identifier, nil title). Skipped and counted
  in `skipped`, which C8-T04 logs once per generation.
- **Concurrency.** The function is pure. A label written between the two input
  reads can put a ticket in nq for one generation. The next change signal
  (OpenTicketSource broadcast or queue change) rebuilds it, and C8-T04 sends one
  diff (EC-10).
- **Untrusted text.** Titles are passed through raw. C3-T02 scrubs UTF-8, and the
  hook escapes (EC-30).
- **Privacy and permissions.** No new data leaves the server. The Tickets panel
  already shows these titles to the same dashboard viewers.
- **GitHub budget.** No reads. Both inputs are existing in-memory projections.

## 7. Compatibility and rollout

- No config key, CLI flag, environment variable or migration. No docs page
  changes in this ticket (AGENTS.md "Docs ship with the change": internal module).
  C12-T07 documents the section.
- The module is unused until C8-T04 wires it, so it ships dark and needs no flag.
- Rollback: delete the module. Nothing else depends on it before C8-T04.

## 8. Verification

All tests are ExUnit in PROPOSED `src/test/aiur/build_order/not_queued_test.exs`,
`async: true`, no processes, no `~/.aiur`.

| # | Test (concrete input) | Expected | Fails without (mutation) |
| --- | --- | --- | --- |
| T1 | "an unlabelled open ticket is not queued": snapshot `:available` with #31 (labels `[]`), queue `running` with no items | one row `%{num: 31, sec: "nq", status: "open", ord: 31}`, `state: :ok` | membership filter replaced by `fn _ -> false end` |
| T2 | "agent:todo outside a queue is planned, not here": #10 `["agent:todo"]` | `rows == []` | rule 3 removed |
| T3 | "every active state label excludes": one ticket per suffix in-progress, ci-wait, human-review, rework, merging, error (prefix `agent`); and, with `label_prefix: "Bot"`, one ticket labelled `bot:in-progress` | `rows == []` | prefix not downcased for `state_labels/1`, or `state_labels/1` replaced by a literal `["agent:in-progress"]` |
| T4 | "terminal labels and markers do not exclude": `agent:done`, `agent:cancelled`, `agent:paused`, `agent:parked`, `human:todo`, `needs-triage` (one ticket each); and, with `label_prefix: "Bot"`, one ticket labelled `bot:done` | six rows, then one row | terminal check removed (`agent:done` drops), or the raw `"Bot"` prefix passed to `terminal_state_label?/2` (`bot:done` drops) |
| T5 | "queue items are excluded, removed items are not": items #5 `waiting`, #6 `held`, #7 `unknown`, #8 `removed` | only #8 in rows | `removed` not skipped, or `unknown` items skipped |
| T6 | "the now band wins": #40 unlabelled, `active: MapSet.new([40])` | `rows == []` | rule 4 removed |
| T7 | "design order": tickets #575, #577, #576 created in reverse | nums `[575, 576, 577]`, `ord == num` | sort replaced by `-num` or by `created_at` |
| T8 | "several hundred rows, no cap": 600 unlabelled tickets #1..#600 | `length(rows) == 600`, first #1, last #600 | any `Enum.take/2` or cap |
| T9 | "empty is ok, not unavailable": `:available`, zero eligible tickets | `state: :ok`, `rows: []`, `reasons: []` | `[]` mapped to `:unavailable` |
| T10 | "unknown complexity is nil, not a number": tickets with `[]`, `["complexity:9"]`, `["complexity:2", "complexity:3"]`, `["complexity:4"]` | `{cx, pts}` = `{nil, nil}`, `{nil, nil}`, `{nil, nil}`, `{4, 5}` | the `nil` branch of `points/1` replaced by `1` or `0` (AGENTS.md unknown-path rule) |
| T11 | "points table": `points/1` for 1..5 | `[1, 2, 3, 5, 8]` | table edited |
| T12 | "open source unavailable gives no rows": `%Snapshot{}` default, tickets list non-empty in a crafted struct | `state: :unavailable`, `reasons: [:open_tickets_unavailable]`, `rows: []` | unavailable branch replaced by the `:ok` path |
| T13 | "queue store_unavailable gives no rows": snapshot with #31, queue `store_unavailable` | `:unavailable`, `[:queue_unavailable]`, `[]` | branch replaced by the `disabled` path (would list #31) |
| T14 | "queue disabled lists everything unlabelled": queue `disabled`, `queues: []` | #31 listed, `reasons: [:queue_disabled]` | `disabled` treated as unavailable |
| T15 | "unknown queue shape": queue `:error`, `%{}`, `%{status: :paused}`; and `{:error, :timeout}` | the first three `:unavailable`, `[:queue_status_unknown]`; the last `:unavailable`, `[:queue_read_failed]` | a default of `running`, or `{:error, _}` folded into `:queue_status_unknown` (one cause collapsed into another, AGENTS.md) |
| T16 | "stale reasons accumulate, observed_at is the older": snapshot `:stale` observed 10:00; queue `running`, `captured_at` 10:05, `tracker_observation` `current` observed 10:01, `build_order:2573` `stale` observed 09:58 | `:stale`, reasons `[:open_tickets_stale, :queue_stale]`, `observed_at` 09:58 | `observed_at` from the newer input or from `captured_at` (10:05), freshness read from `tracker_observation` only (no `:queue_stale`), or reasons collapsed to one |
| T17 | "missing freshness is not current": queue `running` with `sources: %{}`; and one with `tracker_observation` `freshness: :unknown` | each `:stale`, `[:queue_freshness_unknown]`, `observed_at: nil` | missing or unknown source read as `current`, or `observed_at` taken from the snapshot alone |
| T18 | "unsupported tracker": snapshot `:unsupported` | `:unsupported`, `[:tracker_unsupported]`, `[]` | `:unsupported` mapped to `:ok` with `[]` |
| T19 | "truncation passes through": `truncated?: true` | `truncated?: true` | field hard-coded `false` |
| T20 | "malformed tickets are counted": identifiers `"abc"`, `"0"`, and a nil title | `skipped: 3`, no rows | skip replaced by a crash or a silent drop without the count |
| T21 | "design dataset parity": C1-T01's exported `live.json`; snapshot from its `nq` rows (number from `AIUR-N`, `complexity:<cx>`), queue items from its `plan` rows, `active` from its `now` rows, and each history row omitted (closed) | `rows` equal `nq` by `num`, `cx`, `pts`, order (22 rows); the same build over `newrepo.json` gives its 6 rows | any rule above that changes membership or order |

**Mutation run (AGENTS.md).** For each test, revert the production hunk named in
the last column in a worktree (`git status --porcelain` shows only that change),
run the file, and confirm the test fails; restore and confirm it passes. Record
one line per test in the PR body.

```bash
env -C <worktree>/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/build_order/not_queued_test.exs
env -C <worktree>/src mise exec -- mix format --check-formatted lib/aiur/build_order/not_queued.ex test/aiur/build_order/not_queued_test.exs
```

T21 needs C1-T01's export. If C1-T01 has not merged, T21 is `@tag :skip` with the
reason, and the PR says so.

**Manual.** None for this ticket: it renders nothing and is not wired. The manual
TUI and browser checks are C8-T04's and C12-T01's.

## Pixel parity

This ticket draws nothing. It decides which cards the `nq` section draws, their
order and the numbers on them, so it is checked through C1's harness:

- **Design elements fed.** `#bd-sec-nq` (J:613) and its header `.bd-sech`
  (C:193-195, text J:660); the `nq` card `.bd-card.nq .bd-in` (C:265 dashed
  border, C:266 70 % surface wash, C:936 bar tier, C:976 light, C:1152 gruvbox
  light) with `.bd-status` (C:242-243, 869-871) "Open · not queued" | "N pts"
  (J:862); the `.bd-cx` glyph (J:841) from `cx`; the list section (J:1177,
  `.lst.st-open` C:736); the tree node `.bd-tn.nq` (C:692); the planned-empty
  count (J:499).
- **Check 1 (exact data).** T21 above: the producer, fed the design dataset,
  returns the design's `nq` rows with the same `num`, `cx`, `pts` and order.
- **Check 2 (screenshot).** C8-T04 adds a fixture DataSource case that serves T21's
  output. C1-T02's region mode compares `#bd-sec-nq` with the design at 1440,
  1024 and 390 px, dark, light and gruvbox, `TZ=America/Los_Angeles`, frozen `NOW`
  (J:11): zero pixel difference above the recorded floor. With order or `pts`
  wrong, the cards move or the "N pts" text changes, and the check fails.
- **Check 3 (states with no design baseline).** `:unavailable` and `:unsupported`
  use the S-9 marker (C9-T13). The truncated header copy (Decision 5) is captured
  by C1-T02's element mode for Kevin's sign-off. Until he signs, that screenshot
  is the baseline.
- Any difference not approved by Kevin in writing is a failing check.

## 9. Completion and handoff

- [ ] `Aiur.BuildOrder.NotQueued.build/3` and `points/1` as in §4.
- [ ] T1-T20 pass; T21 passes or is skipped with the reason.
- [ ] Each test fails with its production hunk reverted; the commands and the
      one-line results are in the PR body.
- [ ] No new GitHub read, PubSub topic, config key or process.
- **Dependents.** C8-T04 (wires it and reuses `points/1`), C9-T13 (renders the
  non-ok states).
- **Docs.** None here (internal module); C12-T07 owns the section's docs.
- **Sources.** tickets/README.md row C7-T04; chunks.md C7; plan.md §5.1, §8
  EC-04; options.md §3.3, §5; contract `queue-readiness-and-build-progress.md`
  §1-§3; DESIGN-E8 S-9; the code and design lines cited above.

### Interface notes for neighbour rows

- **README row C7-T04 (mismatch).** "Newest first, as the design's order shows"
  is not what the design shows: `D.nq` is never sorted, and its numbers ascend
  (J:273, 531). This ticket follows the design (Decision 2). The row's status
  line "Open · not queued · N pts" is, in the design, two spans:
  "Open · not queued" and "N pts" (J:862). C9-T05 follows J:862.
- **C3-T02 (mismatch).** Settled 2026-10-08: C3-T02's additive table adds
  `sources.open_tickets`, `truncated` and the `unsupported` state (C8-T04 sends
  `"unsupported"`, not `"disabled"`), and the nq sort key is `num` ascending.
  Original finding: its row table sets the nq sort key to `−created`. With
  this ticket it is `num` (ascending). C3-T02 also has no source key for this
  section: `sources` names `history`, `features`, `queue`, `agents`, `index`
  (C3-T02:301). C8-T04 needs `sources.open_tickets` (state, `observed_at`,
  reason), plus a `truncated` boolean for the header, or C9-T13 cannot tell
  "0 open" from "unavailable". C3-T02's source states are `ok`, `stale`,
  `incomplete`, `unavailable`, `disabled`: there is no `unsupported`. C8-T04
  maps `:unsupported` to `"disabled"` with reason `"tracker_unsupported"` (the
  same mapping C7-T01 §4.5 uses for `unsupported_tracker`), unless C3-T02 adds
  the state.
- **C3-T02 / C12-T06 (size).** Settled 2026-10-08: the 64 KB snapshot budget
  excludes the not-queued section; C12-T06 owns a separate 160 KB budget for
  300 not-queued rows. Original finding: the 64 KB snapshot budget was measured with 22 nq
  rows. Aiur has about 63 today (options §3.3), and EC-04 asks for several
  hundred: at about 326 B per row, 300 rows is about 98 KB. The header count is
  `D.nq.length` (J:660), so the window must hold every nq row, or the header must
  read a server total.
- **C7-T01 (covered, one source risk).** C7-T01 §4.6 places open `agent:todo`
  tickets outside every queue as planned rows, so the exclusion here leaves no
  gap in the rule. But C7-T01 reads them from History open rows (C4-T01), and
  this ticket reads `Aiur.OpenTicketSource`. While the History backfill is
  pending, an `agent:todo` ticket can be in the open snapshot and missing from
  History: it is then in no section. C8-T04's one-section assertion (below)
  must count it, and C7-T01 may take its open `todo` set from the same
  snapshot instead.
- **C8-T01 / C8-T04 (gap).** Settled 2026-10-08: C8-T04 asserts every open
  ticket appears in exactly one section. Open tickets with `human-review`, `ci-wait`, `merging`
  or `error` labels and no running agent are excluded here, as the row says
  ("no active agent state"). C8-T04 must place them in the now band or planned,
  and should assert that every open ticket is in exactly one section. C8-T04
  decision 8 says "a failed open ticket is a now or not-queued row with agent
  state `error`". The not-queued half is false: `agent:error` excludes a ticket
  here (rule 3), and `nq` rows carry no `agent`. C8-T04 must make it a now row.
- **C8-T04 (read shape and signals).** Settled 2026-10-08: C8-T04 adds
  `open_tickets:changed`. C8-T04 interface note 5 expects a
  `{:ok, rows} | {:error, reason}` read plus a `subscribe` function from this
  ticket. This ticket gives a pure `build/3` that returns the result map of
  §4.3; C8-T04 makes the two reads and calls it. The signals are the existing
  `Aiur.OpenTicketSource.subscribe/0` (`open_tickets:changed`) and the queue
  signal. C8-T04's parts table lists "History and queue signals" for this row:
  it must add `open_tickets:changed`, or a label change does not reach `nq`.
- **C8-T04 (row assembly).** Its "Row assembly" table joins `title`, `created`,
  `cx` and `pts` from the History row for every section. For `nq` rows it must
  keep the values this ticket returns, because History can be pending for an
  open ticket (Decision 1), and it should call `NotQueued.points/1` instead of
  its inline `[1,2,3,5,8]` table, so there is one table.
- **C4-T01.** Not used. The row named it for open rows; `Aiur.OpenTicketSource`
  already holds them (Decision 1). C4-T01 lines 62 and 599 list C7-T04 as a
  reader of its open rows; that consumer goes.
- **C12-T07 (mismatch).** Its line 280 documents "Not queued newest first". With
  Decision 2 the order is oldest first (ascending number); the docs must say so,
  or follow whichever order Kevin chooses at sign-off.
- **C9-T05 and the list view (C9-T12).** `cx` and `pts` can be `null`. J:841
  (`CX[t.cx - 1]`, `--cxh`), J:862 and the list row J:1161 (`t.pts + " pts"`)
  would print `undefined` and `null pts`. They must render the design's unknown
  mark `—` (`lr-mu`, J:1167) in each place, with the AGENTS.md mutation test.

## Decisions made without the owner

1. **The open set comes from `Aiur.OpenTicketSource`, not from the history store
   (C4-T01).** It exists on main, holds every open issue with a named status, and
   is complete after one listing. The history store stays "backfill pending"
   until C4-T02 finishes, which would hide this section on every new install.
   Reuse first (ponytail). C4-T01 is dropped from `blocked_by`.
2. **Order is ascending issue number (oldest first), as the design renders it,**
   not newest first as the row says. The design is the specification, and the
   C1-T02 screenshot of the design dataset fails with any other order. The other
   answer is a one-line change (`ord = -num`). Kevin can choose at sign-off
   (S-30).
3. **No state chips on not-queued cards** (`needs-triage`, `human:todo`,
   `paused`, `parked`), although options §3.3 lists them. The design's `nq` card
   has none (J:862).
4. **A queue store failure empties the section with a reason,** instead of a
   fallback to the queue marker label. The fallback is allowed by contract §1
   rule 1, but the marker's name is still open in DESIGN-E1, and a second path
   doubles the tests. Revisit if the queue store is often unavailable.
5. **Truncated listing (over 1,000 open issues):** rows are shown, and the
   header count gets a `+` ("1000+ open · not in the queue"), in the same
   `.bd-sech em` style. The design has no such state. It is S-30 in DESIGN-E8's
   sign-off table.
6. **`agent:done` or `agent:cancelled` on an open issue counts as not queued.**
   Those states are terminal (`state_policy.ex:29-32`), so no agent will run the
   ticket. It is open backlog.
7. **Complexity 2, not 1.** The membership rule is small, but the availability
   matrix (§4.3) and its tests are most of the work.
8. **Queue freshness is the worst over every `sources.*` entry, and the age is
   the oldest `sources.*.observed_at`,** not `tracker_observation` alone and not
   `snapshot.captured_at`. Membership depends on every queue's items, and
   C7-T01 §4.5 already uses this rule for the same read model; two rules would
   let the Planned head say "stale" while Not queued says "ok".

## Review log

Adversarial review, 2026-10-08, against `58854d4c8`, design-source and the
neighbour tickets.

1. §5 step 1: the terminal-label check got the raw prefix while the labels and
   `state_labels/1` used the lowercased one, so with `label_prefix: "Bot"` an
   open `bot:done` ticket was wrongly excluded. Both calls now use the
   lowercased prefix; T4 gains a `bot:done` case that fails with the old code.
2. §4.3: queue freshness and `observed_at` aligned with C7-T01 §4.5 (worst over
   all `sources.*`, oldest `observed_at`; `captured_at` is the capture time).
   T16 and T17 rewritten so each mutation is reachable (Decision 8).
3. §4.3: a failed `show/1` read (`{:error, _}`) now has its own reason
   `:queue_read_failed`, matching C7-T01's `read_failed`, instead of being
   collapsed into `:queue_status_unknown`; T15 covers it. Key encoding pinned to
   C7-T01's (atoms); T15's string-key case became `%{status: :paused}`.
4. §2 and §9: C7-T01 does not compute `pts`, so it is not a `points/1`
   consumer; C8-T04 is (it has an inline table). The "C7-T01 gap" note was stale
   (C7-T01 §4.6 places outside-queue `todo` rows); replaced with the real
   History-vs-OpenTicketSource risk.
5. Interface notes added: C8-T04 read shape, missing `open_tickets:changed`
   signal, History join overwriting `nq` fields, and decision 8's "not-queued
   row with agent state error"; C3-T02 `features` source and no `unsupported`
   state; C4-T01 consumer list; C12-T07 "newest first"; README status-line
   wording.
6. §3: `snapshot/1` and `label_prefix/0` line ranges corrected; a row added
   showing where projection labels are lowercased (`open_ticket_source.ex:246-247`).
   T21 names `newrepo.json` explicitly.

Checked and correct: every design line cited (J:11, 93, 265-275, 333, 357, 499,
529-532, 613, 660, 689, 841, 862, 1101, 1152-1153, 1161, 1167, 1172, 1177, 1379,
1438; C:193-195, 242-243, 265-266, 692, 736, 869-871, 936, 976, 1152); `D.nq` is
never sorted and `entries()`/`rows()` keep array order (J:370-410); the code
symbols in §3; all nine §9 sections are present.
- Reconciliation 2026-10-08 (coordinator): truncated header and ascending order -> S-30, key encoding -> CR-E8-12, C3-T02 interface notes settled (open_tickets source, truncated, `unsupported` state, num ascending, 160 KB nq budget in C12-T06), C8-T04 notes settled (`open_tickets:changed`, one-section assertion).
