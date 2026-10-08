---
ticket_id: MP-E8-C7-T01
feature_id: MP-E8
chunk_id: MP-E8-C7
bucket: 2-platform
title: Planned rows, waves and cues from the build queue
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C4-T01, MP-E1-C6-T01, MP-E1-C7-T02, MP-E1-C5-T02]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-03, EC-23]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C7-T01 — Planned rows, waves and cues from the build queue

> Cites code at `origin/main` `58854d4c8` (runtime worktree
> `aiur-worktrees/runtime/src`). Paths marked PROPOSED do not exist yet.
> `Aiur.BuildQueue` does not exist on main: it is MP-E1 (wave 0), which ships
> before this ticket. Its shape is cited from
> [`contracts/queue-readiness-and-build-progress.md`](../../../contracts/queue-readiness-and-build-progress.md)
> §2–§3 and the MP-E1 ticket docs. Re-check those against the merged MP-E1 code
> before starting. If MP-R1 has moved `build_order/` or the queue by then,
> re-resolve the symbols below.
>
> Abbreviations: `J` = `design-source/assets/build.js`, `C` =
> `design-source/assets/build.css`, `H` = `design-source/Aiur Dashboard.html`.

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C7
  (planned, not-queued and estimates), ticket T01.
- **User value.** The operator sees what runs next, in the order the queue will
  start it, grouped in dependency waves, with the reason each ticket waits:
  promoted, held (by whom and why), waits on a running ticket, its prerequisite
  failed (and what else that blocks), or its prerequisite chain failed. "The
  queue is off" and "the queue store is broken" are never shown as "Nothing
  planned".
- **Deliverable.** One pure server module, PROPOSED
  `src/lib/aiur_web/build/planned_rows.ex` (`AiurWeb.Build.PlannedRows`), and
  its test file. It maps the MP-E1 read model (`Aiur.BuildQueue.show/1`) and the
  C4-T01 History rows to:
  - the C7-owned fields of each `plan` row in the C3-T02 payload (`id`, `num`,
    `sec`, `status`, `ord`, `qpos`, `wave`, `deps`, `cue`);
  - the `sources.queue` block (`state`, `observed_at`, `reason`).
- **This ticket replaces MP-E1-C8-T01** (E8-D14, CR-E8-1). No separate queue
  panel is built.
- **Non-goals.**
  - Estimates and overrides (`est`, `override`, the `.bd-q.ovr` cue, ETA):
    C7-T03.
  - Unfiled planning-pack rows (`pack:` ids): C7-T02.
  - Not-queued rows: C7-T04.
  - Title, type, epic, feature, `cx`, `pts`, `created`, `also`, `added`: the
    C8-T04 assembler joins them from History (C4), the epic resolver (C5) and
    features (C6).
  - Rendering. The card cues are C9-T05, the wave labels C9-T02, the empty and
    unavailable markers C9-T13, the modal cues C11-T02.
  - PubSub subscription and diffing: C8-T04 calls this module on each queue
    change.
  - Any queue write ("Add to queue" is C11-T02 over MP-E1-C6-T02).

## 2. Dependencies and blockers

- **DESIGN-E8** (Kevin's go and sign-off items). The S-9 default
  ("unavailable" copy is the `.bd-mk.empty` marker with the age) is followed by
  C9-T13; this ticket only supplies the distinct state.
- **MP-E8-C4-T01** — `Aiur.BuildOrder.History.rows/2` and `snapshot/1`
  (C4-T01 §4.3) give each issue's `lifecycle`, `labels` and `created_at`. Used
  for: a queue item whose issue is closed leaves the section (EC-23); open
  `todo` tickets outside every queue (§4.6).
- **MP-E1-C6-T01** — `Aiur.BuildQueue.show/1`, contract §3 read model. This is
  the main input.
- **MP-E1-C5-T02** — the prerequisite-failed attention. This ticket does not
  read attentions; it derives `cue.failed` from the same edge verdicts
  (`verdict: "failed"`) so the card and the alert agree. The blocker stays so the
  `failed` verdict and its blocked set are real when this ships.
- **MP-E1-C7-T02** — this module does not read `queues[].progress`, but the
  refresh signal does depend on it: C8-T04 re-reads planned rows on the queue
  signal, which is `Aiur.BuildProgress.subscribe/0` (contract §5; C8-T04
  "planned" part row), and MP-E1-C7-T02 is the ticket that makes the queue feed
  `Aiur.BuildProgress` after each reconcile. Keep the blocker (§10 decision 9).
- **Contract requests.** CR-E8-5 (hold actor and reason, promoted time, failed
  prerequisite, queue position in the read model). CR-E8-10 and CR-E8-11
  (§10 decisions 3 and 4) are recorded in CONTRACT-REQUESTS.md by the
  coordinator.
- **May run concurrently with:** C7-T04, C8-T01, C8-T02, C8-T03, every client
  ticket (they build on the C3-T01 fixture source). C7-T02 and C7-T03 extend
  this module and start after it.

## 3. Verified starting point (`58854d4c8`)

| Need | Code at `58854d4c8` | Use here |
| --- | --- | --- |
| Transitive closure over an adjacency map | `lib/aiur/build_order/dependency_chain.ex:42-61` `DependencyChain.reachable/2` (iterative visited set, excludes the node, sorted result) | Reused for `failed.blocks` and `blockedChain` (§4.4) |
| The 100-node cap to avoid | `lib/aiur/build_order/graph_analysis.ex:10` `@max_nodes 100`, `:33` `Enum.take(@max_nodes)` | Not used. Waves are computed here with no cap (row: "no 100-node cap") |
| Source freshness shape to mirror | `lib/aiur/build_orders_cli.ex:244-246` (`observed_at`, `age_ms`, `freshness`), `:254-259` (`unknown_source`, `unavailable_source`, `freshness/1` → `:current \| :stale \| :unknown`) | MP-E1-C6-T01 copies this shape into `sources.*` (its "Verified starting point"); §4.5 maps it |
| Issue lifecycle | `lib/aiur/build_order/lifecycle.ex:65-72` `Aiur.BuildOrder.Lifecycle` (`state: :open \| :closed \| :unknown`) | The closed check (§4.3) reads `row.lifecycle.state` from History |
| Provider health | `lib/aiur/build_order/lifecycle.ex:1-27` `Aiur.BuildOrder.ProviderHealth` | History's error reply (`{:error, ProviderHealth.t()}`, C4-T01 §4.3) |
| Dispatch order helpers | `lib/aiur/orchestrator/dispatch_policy.ex:628-648` `sort_issues_for_dispatch/1`, `priority_rank/1` | Not called (seam, §4.6); the outside-queue order copies its created-at tie rule only |
| Todo label spelling | `lib/aiur/github/state_policy.ex:34-35` `state_label(prefix, state)`; `lib/aiur/github/config.ex:309-310` `label_prefix/0` | Not referenced from the web seam; the caller passes the label (§4.6) |

Seam: C3-T01's source scan allows `lib/aiur_web/build/**/*.ex` to reference
`Aiur.BuildOrder.*` and `Aiur.BuildQueue` (public API) only, among `Aiur.*`
modules (C3-T01 "Seam scan" rule 1). This module fits: it calls
`Aiur.BuildQueue.show/1`, `Aiur.BuildOrder.History.*` and
`Aiur.BuildOrder.DependencyChain.reachable/2`.

Read model facts this ticket depends on (contract §2.3, §3; MP-E1-C2-T01 Item
struct):

- Item fields: `number`, `position`, `state`, `verdict`, `prerequisites[]`
  (`number`, `verdict`, `source`), `downstream_open`, `rank`, `promoted_at`,
  `attention`. Items are listed **in start order** inside each queue
  (MP-E1-C6-T01 "User value"). `rank` must not be used to re-sort (contract §3).
- Two verdict vocabularies: a prerequisite edge has `satisfied | pending |
  failed | unknown` (contract §2.1); the item-level `verdict` has `unknown |
  failed | waiting | ready` (§2.2). This module reads edge verdicts for cues and
  waves, and the item verdict only for `unknown`.
- `position` is the stored list slot (MP-E1-C2-T01 Item table: "non-neg int,
  list kind only"), so it is `nil` for `build_order` queues and can have gaps
  after removals. It is not the start rank. `qpos` therefore comes from the item
  order (§4.3), not from `position` (§10 decision 12).
- Queue fields: `queue_id`, `kind`, `root`, `name`, `held`, `progress`, `items`.
- Top level: `status` (`running | disabled | unsupported_tracker |
  store_unavailable | writes_paused`), `sources.*` with `observed_at`,
  `age_ms`, `freshness`, `reasons`, `snapshot.captured_at`.
- The stored `Item.hold` is `nil | :operator | :external` (MP-E1-C2-T01 table).
  **No actor and no reason are stored and none are in the read model.** The
  design needs both ("Held by Maya · release freeze until Thu", J:217). This is
  CR-E8-5; until it lands, §4.2 renders what is known and never invents an
  actor.
- Keys are atoms and enum values are atoms, as in `BuildOrdersCLI`
  (`build_orders_cli.ex:211`, `:254`). If MP-E1-C6-T01 merged string keys,
  change the one accessor in step 2; nothing else changes.

Design facts (what the payload must let the renderer reproduce):

- `PLAN` rows carry `wave`, `qpos`, `cue: {held, promoted}` (J:213-233,
  J:260-261). `qpos = i + 1` over all plan rows in queue order (J:260).
- Cue derivation (J:277-287): `wait` = number of the first open prerequisite
  that is in the now band, and `null` when `failed` is set (J:284
  `!p.cue.failed && live.length`); `waitAny` = any prerequisite not done; `failed` and
  `blockedChain` are set to `null`/`false` in every design dataset (J:282,
  J:286), so no design screen shows them.
- Card cue strings (J:852-860):
  `promoted <age>` (`.bd-q.promo`), `held` with `title` = the hold text
  (`.bd-q.held`), `waits on #N` (only when not `blockedChain`), `prereq chain
  failed` (only when not `failed`), and, when `failed`, a `.bd-alert` with
  "Prereq #by failed · blocks #a #b" instead of the cue row. Status line
  "Q<qpos> · held | prereq failed | waiting | queued".
- Ticket state for the filter (J:333 `tstate`): plan → `held` if `cue.held`;
  `blocked` if `waitAny || failed || blockedChain`; else `queued`. The list
  view (J:1152-1153 `stClass`/`stText`) uses a different rule: `blocked` only
  for `failed || blockedChain`, and "Waiting on #wait" when `wait` is set. The
  card gets the `.plan.blk` class for `failed || blockedChain` (J:821). This
  module feeds all three; it does not pick one rule.
- Wave labels (J:503-508): one label per distinct wave, ascending, text
  "W<n>" and "<count>" plus " · ready" on W1.
- Section header (J:659): "Planned <em>N in build-queue order · dependency
  waves</em>", or "queue empty".
- Empty marker (J:499): "Nothing planned" / "The build queue is empty. N open
  tickets are not queued — promote some to keep agents busy."
- Modal cues (J:1423-1425): `.bm-cue` with the hold text; `.bm-cue.bad`
  "Prerequisite #by failed — this and (blocks.length − 1) more are blocked", so
  **`blocks` includes the ticket itself**; else "Waiting on #wait". Facts
  "Queue Q<n>", "Wave W<n>" for every plan row, and "Queue —" only for rows
  that are not plan rows (J:1434). The design has no plan row without a
  `qpos`; it would print "Qnull" (J:860, J:1434).

## 4. Chosen design

### 4.1 Interface (PROPOSED)

```elixir
defmodule AiurWeb.Build.PlannedRows do
  @type cue :: %{held: String.t() | nil, promoted: integer() | nil,
                 wait: pos_integer() | nil, waitAny: boolean(),
                 failed: %{by: pos_integer(), blocks: [pos_integer()]} | nil,
                 blockedChain: boolean(), unknown: boolean()}
  @type row :: %{id: String.t(), num: pos_integer(), sec: "plan", status: "queued",
                 ord: non_neg_integer(), qpos: pos_integer() | nil, wave: pos_integer(),
                 deps: [String.t()], cue: cue()}
  @type source :: %{state: "ok" | "stale" | "unavailable" | "disabled",
                    observed_at: integer() | nil, reason: String.t() | nil}

  # Reads the queue and History, then calls build/3. The only impure function.
  @spec read(keyword()) :: %{rows: [row()], source: source()}

  # Pure. show = the show/1 map, or {:error, reason} from read/1.
  # history = {:ok, %{rows: %{number => Row.t()}, health: ProviderHealth.t()}}
  #           (the C4-T01 §4.3 `snapshot/1` reply as is) | {:error, term()}
  @spec build(map() | {:error, term()}, {:ok, map()} | {:error, term()}, keyword()) ::
          %{rows: [row()], source: source()}
end
```

Options (both are passed by C8-T04):

- `:active` — `MapSet` of issue numbers that have a now-band row (C8-T01).
  Default `MapSet.new()`. Used only for `cue.wait` (§4.4).
- `:todo_label` — the full todo label (`"agent:todo"`), or `nil`. When `nil`,
  §4.6 is off. Default `nil`.

`read/1` options: `:queue` (module with `show/1`, default
`Aiur.BuildQueue`), `:history` (module with `snapshot/1`, default
`Aiur.BuildOrder.History`), and `:history_snapshot` (a `snapshot/1` reply the
caller already holds). C8-T04 already reads `History.snapshot/1` for its history
part, and C4-T01 §6 says `snapshot/1` copies the whole map to the caller (V-16
measures it), so C8-T04 passes its copy here instead of making a second one.
When `:history_snapshot` is given, `read/1` does not call the History module.

### 4.2 Which items become planned rows

Walk `queues` in read-model order, and each queue's `items` in read-model order.

| Item `state` (contract §2.3) | Planned row? | Cue |
| --- | --- | --- |
| `waiting` | yes | from edges (§4.4) |
| `ready` | yes | from edges (all satisfied → none) |
| `promoted` | yes | `promoted` = `promoted_at` in ms; `nil` if `promoted_at` is not a `DateTime` |
| `overridden` (todo applied by someone else) | yes | none extra |
| `promoted_unauthorized` | yes | `held = "Held · dispatch not authorized"` (§10 decision 5) |
| `held` | yes | `held` text, table below |
| `failed_prerequisite` | yes | `failed` (§4.4) |
| `unknown` | yes | `unknown: true` (§4.4) |
| `claimed` | **no** | it is in the now band (C8-T01) |
| `completed`, `cancelled`, `removed` | **no** | — |

Then drop any item whose History row says `lifecycle.state == :closed`, even if
the queue still lists it as waiting (EC-23: the queue observation lags the
issue). C8-T04's next diff moves that ticket to `hist` as one upsert (EC-10).

Hold text (`cue.held`). The actor and reason are read from item fields `hold_by`
and `hold_reason` once CR-E8-5 adds them; the code reads them with
`Map.get(item, :hold_by)` so it works before and after.

| Facts | Text |
| --- | --- |
| queue `held: true`, item state `waiting`, `ready` or `held` | `"Held · queue <name> is held"` (overrides the per-item text; `<name>` falls back to `queue_id` when `name` is `nil`). Items in `promoted`, `overridden` or `promoted_unauthorized` keep their own cue: they already carry the todo label, so a queue hold does not stop them |
| `hold_by` and `hold_reason` | `"Held by <by> · <reason>"` (the design's exact form, J:217) |
| `hold_by` only | `"Held by <by>"` |
| `hold_reason` only | `"Held · <reason>"` |
| neither, state `held` | `"Held · no actor or reason recorded"` (EC-23) |

Actor and reason are raw text. They are never HTML-escaped here; the renderer
escapes them (J:854 `esc`, C3-T02 validator rule for `cue.held`).

### 4.3 Order, `ord` and `qpos`

- `ord` = 0-based index of the row in the walk of §4.2, after the drops.
  C3-T02: `ord` is the sort key inside the section.
- `qpos` = `ord + 1` for queue rows. So `Q1` is the next ticket to start, as in
  the design (J:260 counts plan rows only).
- **Several queues.** The read model gives start order inside a queue, not
  across queues. Rows are concatenated in `queues` order. CR-E8-11 asks MP-E1 for
  a global start order (§10 decision 4). With one queue (the common case) the
  result is exact.

### 4.4 Waves and cues

Let `P` be the set of planned queue numbers, and `L` the set of live queue
numbers: every item whose state is not `completed`, `cancelled` or `removed`
(so `P` plus the `claimed` items). Build one adjacency map `dependents` =
prerequisite number → [dependent numbers in `L`], from the `prerequisites` of
every item in `L`. Waves use only `P`; `failed.blocks` uses `L`, so a claimed
dependent of a failed prerequisite is still named.

**Wave** (row: "the prerequisite level inside the queue rank, no 100-node cap"):

```text
contrib(p) = 0            if p.verdict == satisfied
           = wave(p)      if p.number in P
           = 1            otherwise (pending, failed or unknown, not planned:
                          running, not queued, or outside the index)
wave(i)    = 1 + max(contrib(p) for p in prerequisites(i)), max([]) = 0
```

- W1 therefore means "no unsatisfied prerequisite", which is what the design's
  " · ready" label on W1 claims (J:508). A ticket that waits on a running
  ticket is W2, as the design's p8 (waits on active a3) is W2 (J:221).
- Computed with a memo map in `ord` order. A prerequisite that is already on the
  current path (a cycle) contributes `1`, so the walk always ends. Items in a
  cycle have verdict `unknown` in the read model anyway (contract §2.1).
- Unknown verdicts never lower a wave: they count as unsatisfied.

**Cues:**

- `waitAny` = any prerequisite with verdict ≠ `satisfied`. Unknown counts.
- `wait` = `nil` when `failed` is set (J:284). Otherwise the number of the
  first prerequisite (read-model order) with verdict `pending` that is in
  `opts[:active]`; else `nil` (J:284: only a live prerequisite is named).
- `failed`: let `F` be the first prerequisite with verdict `failed`. Then
  `failed = %{by: F, blocks: direct ++ (DependencyChain.reachable(F, dependents) -- direct)}`
  where `direct = Enum.sort(dependents[F])`. The item itself is in `direct`,
  so the modal's "this and N more" count is right (J:1424). The order (direct
  first, then transitive, numbers only) is MP-E1-C5-T02's blocked-set order
  ("Chosen design": `blocked` refs). The sets are not always equal: the alert
  takes the transitive dependents from the `Ordering` closure (MP-E1-C5-T02
  "Verified starting point"), which can include tickets that are in no queue.
  The card names only queue tickets (`L`). For every ticket that is in a queue,
  the card and the alert agree.
- `blockedChain` = `failed == nil` and some ticket that is a transitive
  prerequisite of this item inside `P` has a non-nil `failed`. Computed as: the
  union of `reachable(n, dependents)` over every `n` with `failed`, minus those
  `n`.
- `unknown` = the item's `state` or `verdict` is `unknown`. This field is new
  (CR-E8-10, §10 decision 3). It stops an unknown item from reading as
  "Q3 · queued".
- `deps` = the item's prerequisite numbers as strings, in read-model order
  (C3-T02: ids are decimal strings; C8-T04 drops ids not in the index, EC-21).

### 4.5 The `sources.queue` block (EC-03)

| `show` result | `state` | `observed_at` | `reason` | rows |
| --- | --- | --- | --- | --- |
| `status: :running`, worst `freshness` `:current` | `"ok"` | oldest `sources.*.observed_at` (ms) | `nil` | §4.2 |
| `:running`, worst `:stale` | `"stale"` | oldest `observed_at` | first `reasons` entry, or `"stale"` | §4.2 |
| `:running`, any `:unknown` | `"stale"` | `nil` | `"observation_unknown"` | §4.2 (items carry `unknown`) |
| `:writes_paused` | as `:running` | as above | `"writes_paused"` | §4.2 |
| `:disabled` | `"disabled"` | `nil` | `"disabled"` | §4.6 only |
| `:unsupported_tracker` | `"disabled"` | `nil` | `"unsupported_tracker"` | §4.6 only |
| `:store_unavailable` | `"unavailable"` | `nil` | `"store_unavailable"` | §4.6 only |
| `{:error, _}` (timeout, exit, raise in `read/1`) | `"unavailable"` | `nil` | `"read_failed"` | §4.6 only |
| `Aiur.BuildQueue` not loaded (component absent after MP-R1) | `"disabled"` | `nil` | `"not_installed"` | §4.6 only |

Invariant: `rows == []` with `state == "ok"` is the only "Nothing planned"
case. Every other empty case carries a non-`ok` state, so C9-T13 renders its
S-9 marker with the age. `observed_at` is `nil` when no age is known; it is
never `0` and never the capture time.

### 4.6 Open `todo` tickets outside every queue

Options §3.3: an open ticket that carries the todo label but is not a queue item
belongs in **planned**, because the dispatcher will run it. C7-T04 excludes it
from not-queued on the same rule.

- Source: History rows with `lifecycle.state == :open`, `labels` (a list)
  containing `opts[:todo_label]`, number not in any queue item whose state is
  other than `removed`, `completed` or `cancelled`, and number not in
  `opts[:active]`. The membership rule is C7-T04 §4.1 rule 2 word for word.
  Without it, a `removed` item that someone labelled `agent:todo` by hand would
  be dropped here (§4.2) and excluded by C7-T04 (its rule 3), so it would show
  in no section.
- A row whose `labels` is `:unknown` (C4-T01 §4.1 default) is not a todo row:
  the label is not known to be there. C7-T04 sees the same row.
- Placed after all queue rows. Order: `created_at` ascending, then number
  (`DispatchPolicy` breaks ties by created-at, `dispatch_policy.ex:631`;
  priority labels are not read here). `:unknown` created-at sorts last.
- `qpos: nil` (no queue position), `wave: 1`, `deps: []`, `cue` all
  false/`nil`. The design never has a filed plan row without a `qpos`; its code
  would print "Qnull" (J:860, J:1434). C11-T02 already renders "Queue —" for
  `qpos == null`; C7-T02's `queueText` and the C9-T05 card status line must do
  the same for filed rows (§11 interface notes).
- History `{:error, _}` → no such rows. The History source block (C4/C8-T04)
  shows that error; this module does not repeat it.

### 4.7 Invariants

1. Every row has `sec: "plan"`, `status: "queued"`, a non-`nil` `wave` ≥ 1 and a
   `cue` map with all seven keys.
2. No number appears twice. A number in two queues (should not happen, one-owner
   rule) keeps its first position.
3. `build/3` is pure and deterministic: the same inputs give the same output
   (C8-T04 diffs by equality).
4. Nothing in the output is `0` or `"ready"` for an unknown fact: unknown
   verdicts set `waitAny: true` and `unknown: true`; unknown ages are `nil`.

## 5. Implementation steps

1. **Fixture builder** (test support, PROPOSED
   `src/test/support/build_home/queue_read_model_fixture.ex`). Build a contract
   §3 map from the C1-T01 `live.json` plan rows: one list queue, items in `qpos`
   order; each `deps` entry becomes a prerequisite with verdict `satisfied` if
   the dep is a `hist` row with `status: "done"`, else `pending`; `cue.promoted`
   → `state: :promoted`, `promoted_at = NOW − 6 min`; `cue.held` → `state:
   :held`, `hold_by: "Maya"`, `hold_reason: "release freeze until Thu"`. Also
   small helpers `item/2`, `queue/2`, `show/1` for unit tests (≈ 60 lines).
2. **`PlannedRows.build/3`** (≈ 120 lines): §4.2 selection and hold text, §4.3
   order, §4.4 waves and cues, §4.5 source block, §4.6 outside-queue rows. One
   private accessor reads item fields (atom keys).
3. **`PlannedRows.read/1`** (≈ 20 lines): `Code.ensure_loaded?(queue)` check;
   `queue.show([])` inside `try` catching `:exit` and rescuing any error to
   `{:error, :read_failed}`; `opts[:history_snapshot]`, else
   `history.snapshot([])` inside the same kind of `try` (an exit becomes
   `{:error, :read_failed}`, so a History crash cannot take the queue rows
   with it); then `build/3`.
4. **Tests** (§8).
5. **Contract requests.** CR-E8-10 and CR-E8-11 are already in
   [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md) (the coordinator forwards
   them). Add `unknown: bool` to the C3-T02 `cue` schema row and its
   validator (additive, no version bump, C3-T02 rule "adding fields does not
   bump"), in the same PR.

No change to `layouts.ex`, the router, config or the CLI.

## 6. Non-happy paths

| Case | Input | Behaviour | Test |
| --- | --- | --- | --- |
| Queue empty (EC-03) | `status: :running`, all `items: []`, no todo rows | `rows == []`, `state "ok"` → "Nothing planned" | T-03a |
| Queue disabled (EC-03) | `status: :disabled` | `state "disabled"`, reason `"disabled"` | T-03b |
| Unsupported tracker | `status: :unsupported_tracker` | `state "disabled"`, reason `"unsupported_tracker"` | T-03b |
| Store unavailable (EC-03) | `status: :store_unavailable` | `state "unavailable"`, `observed_at nil` | T-03c |
| `show/1` times out or raises | queue double `exit({:timeout, …})` / `raise` | `state "unavailable"`, reason `"read_failed"`; caller not crashed | T-03d |
| Queue component absent | `queue: NotLoaded` | `state "disabled"`, reason `"not_installed"` | T-03e |
| Stale observation (EC-07) | `freshness: :stale`, `observed_at` 15 min ago | `state "stale"`, `observed_at` = that time in ms | T-07 |
| Unknown observation | `freshness: :unknown` | `state "stale"`, `observed_at nil`, rows kept with per-item `unknown` | T-08 |
| Unknown item | `state: :unknown`, verdict `:unknown`, one prerequisite with edge verdict `:unknown` | `cue.unknown true`, `waitAny true`, wave ≥ 2. (An unknown item with no prerequisites is W1 with `waitAny false`; `cue.unknown true` alone keeps it from reading as ready) | T-08 |
| Closed issue still queued (EC-23) | item `waiting`; History row `lifecycle.state :closed` | row absent | T-23a |
| Held with no actor (EC-23) | `state :held`, no `hold_by`/`hold_reason` | `held "Held · no actor or reason recorded"` | T-23b |
| Held, untrusted text | `hold_reason: "\" onmouseover=\"x"` | passed through raw; C3-T02 validator and C9-T05 escape it | T-30 |
| Cycle | A needs B, B needs A | terminates; A wave 3, B wave 2 (processing in `ord` order) | T-21 |
| 10,000 queue items | one chain of 10,000 | completes; last wave 10,000 | T-09 |
| Promoted with no time | `state :promoted`, `promoted_at nil` | `cue.promoted nil` (no chip, never "0m ago") | T-05 |
| Duplicate number | same number in two queues | one row, first position | T-dup |
| History unavailable | `{:error, health}`; History `snapshot/1` exits | queue rows still built; closed filter and §4.6 skipped | T-hist |
| Removed item labelled todo by hand | item `state :removed` for 400; History open 400 with `agent:todo` | one outside-queue row for 400 (not lost between C7-T01 and C7-T04) | T-todo |
| Labels unknown | History open 401, `labels: :unknown` | no row | T-todo |
| Queue held | queue `held: true`; items `waiting` and `promoted` | waiting row `held "Held · queue <name> is held"`; promoted row keeps `promoted`, `held nil` | T-23b |
| Failed prerequisite with a claimed dependent | F failed; claimed K and planned A need F | A: `failed.blocks == [A, K]` (sorted) | T-10 |
| Failed and waiting | prereqs F `failed`, R `pending` and active | `wait nil`, `failed.by F` | T-10 |

Security and privacy: no titles or bodies travel through the queue read model
(contract §3); this module adds none. No writes, so no `dashboard_writable`
check is needed here.

Concurrency and idempotency: `build/3` is pure. C8-T04 calls it on the queue
signal (`Aiur.BuildProgress.subscribe/0`, contract §5) and on
`"build-order-history:changed"` (C8-T04 part table); repeated calls give equal
output, so no spurious diff. This module does not subscribe: the C3-T01 seam
does not list `Aiur.BuildProgress`, and C8-T04 owns the subscription.

## 7. Compatibility and rollout

- No config, migration or CLI. No docs page changes (C12-T07 documents the home
  page; this ticket adds no documented surface).
- Ships behind the hidden `/build` route (C3-T01) until C12-T01.
- Supersedes MP-E1-C8-T01 (CR-E8-1). If MP-E1-C8-T01 was built anyway, it is
  removed in C12-T02, not here.
- The `cue.unknown` payload field is additive (C3-T02 v1 rule).
- Rollback: revert the PR; C8-T04 then has no planned source and shows
  `sources.queue` as unavailable (C8-T04's own error rule).

## 8. Verification

ExUnit, PROPOSED `src/test/aiur_web/build/planned_rows_test.exs`. Every test
uses fixture maps and module doubles. No test reads `~/.aiur`, the live queue
store or a real History file.

| ID | Test | Input | Expected | Fails when (mutation to try) |
| --- | --- | --- | --- | --- |
| T-01 | "queue order gives ord and qpos" | 3 items in order 2581, 2590, 2600 | `qpos` 1, 2, 3; `ord` 0, 1, 2 | sort by `rank` or by number |
| T-02 | "claimed, completed, cancelled, removed leave the section" | one item per state | only `waiting` row present; the next row is `Q1` | drop the state filter |
| T-03a | "empty running queue is ok and empty" | `:running`, no items | `rows: []`, `state "ok"`, `reason nil` | return `"unavailable"` for an empty running queue (the "Nothing planned" case disappears) |
| T-03b | "disabled is never empty-ok" | `:disabled`; `:unsupported_tracker` | `state "disabled"`, reasons as §4.5 | replace the disabled branch with `"ok"` |
| T-03c | "store unavailable is never empty-ok" | `:store_unavailable` | `state "unavailable"`, `observed_at nil` | map to `"ok"` or `observed_at: 0` |
| T-03d | "read failure degrades, not crashes" | double exits with `:timeout`; double raises | `state "unavailable"`, `"read_failed"` | remove the `try` |
| T-03e | "absent component is disabled" | `queue: NoSuchModule` | `state "disabled"`, `"not_installed"` | drop `Code.ensure_loaded?` |
| T-04 | "waves are prerequisite levels" | A (no prereqs), B needs A, C needs B, D needs a running R (not planned), E needs only a satisfied X | A 1, B 2, C 3, D 2, E 1 | count a satisfied prerequisite as 1 (E becomes 2); count a non-planned pending one as 0 (D becomes 1) |
| T-05 | "promoted carries its time" | `promoted_at` 6 min before capture | `cue.promoted == ms`; with `nil` → `nil` | emit `0` or capture time for `nil` |
| T-06 | "wait names only a running prerequisite" | prereqs pending 11 (not active), 12 (active) | `wait 12`, `waitAny true`; with `active` empty → `wait nil`, `waitAny true` | ignore `:active` |
| T-07 | "stale queue renders its age" | `freshness :stale`, `observed_at` T | `state "stale"`, `observed_at == T ms` | use `captured_at` |
| T-08 | "unknown is never queued-ready" | item `state :unknown` with one `:unknown` edge to a non-planned number; a second unknown item with no prerequisites; source `freshness :unknown` | first: `cue.unknown true`, `waitAny true`, `wave == 2`; second: `cue.unknown true`, `wave == 1`; source `observed_at nil` | replace the unknown branch with `false` / the wave with `1` |
| T-09 | "no 100-node cap" | chain of 10,000 items | last row `wave 10000`; every row present. Run time is printed with `:timer.tc/1` for the PR body, not asserted (a wall-clock bound is flaky on a loaded CI runner); the ExUnit default 60 s timeout is the only time bound | `Enum.take(100)` or `GraphAnalysis.analyze/2` |
| T-10 | "failed lists every blocked ticket, self first group" | F failed; F→A, F→B; A→C (all planned) | A: `failed %{by: F, blocks: [A, B, C]}`; C: `failed nil`, `blockedChain true`. (b) claimed K also needs F → A `blocks == [A, B, K, C]`. (c) A also has pending prereq R in `:active` → A `wait nil` | direct-only blocks (C missing); `blockedChain` from direct edges only; `dependents` built from `P` only (K missing); `wait` computed without the `failed` check (A gets `wait R`) |
| T-21 | "cycle terminates" | A needs B, B needs A | A wave 3, B wave 2 | remove the on-path check (test times out) |
| T-23a | "closed issue leaves even if queued" | item `waiting`; History closed | no row | drop the History check |
| T-23b | "held text never invents an actor" | four hold-fact cases + queue `held: true` (with a `waiting` and a `promoted` item, and a queue whose `name` is `nil`) | the five texts of §4.2; the promoted item keeps `held nil`; the `nil`-name queue uses its `queue_id` | default `by` to `"operator"`; apply the queue hold to every state; interpolate `nil` ("queue  is held") |
| T-30 | "hold text passes raw" | reason with quotes and `<` | text contains them unchanged | HTML-escaping on the server (double escape) |
| T-todo | "todo outside queue is planned after the queue" | History: open 300 with `agent:todo`, not in queue; open 301 without it; open 400 with `agent:todo` whose queue item is `removed`; open 401 with `labels: :unknown` | 300 and 400 last (by `created_at`), `qpos nil`, `wave 1`; 301 and 401 absent; with `todo_label: nil` → 300 and 400 absent | drop the label check (301 appears); count every queue item as membership (400 disappears); treat `:unknown` labels as a match (401 appears) |
| T-dup | "a number in two queues appears once" | 2581 in q1 and q2 | one row, first position | drop the dedupe (two rows for 2581) |
| T-hist | "history unavailable keeps queue rows" | `{:error, %ProviderHealth{state: :unavailable}}`; a History double whose `snapshot/1` exits; `:history_snapshot` given with a History double that raises if called | queue rows present; no todo rows; with `:history_snapshot` the double is not called | crash on the error tuple; remove the History `try`; ignore `:history_snapshot` |
| T-design | "design live plan round-trips" | §5 step 1 fixture from `live.json` | `:active` = the `live.json` now-row numbers. For every row: `qpos`, `cue.held`, `cue.promoted`, `cue.wait`, `cue.waitAny`, `deps` equal `live.json`; `wave` equal for every row except the ids listed in the test (§10 decision 7: p11, p20 and every generated `x<w>_<j>` row whose design wave differs from its prerequisite level; `live.json` ids are `AIUR-<n>`, so the test finds p11 and p20 by title, "Empty page illustrations" and "Release notes 0.9" (J:224, J:233); it computes the exception list from the fixture and asserts both are in it) | any mapping change above |

Mutation discipline (AGENTS.md): for each test, revert or replace its production
hunk as listed in the last column, in a worktree, check `git status
--porcelain` shows only that change, run the test, confirm it fails, restore.
The PR body lists one line per test with the command run.

Commands:

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur_web/build/planned_rows_test.exs
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur_web/build/seam_test.exs
```

The seam test (C3-T01) must stay green: the new file references only allowed
modules.

Manual: none required for this ticket alone (no user-facing surface until
C8-T04 joins it). C8-T04 and C12-T01 run the AGENTS.md manual flow.

## 9. Pixel parity

This ticket renders nothing. Its parity duty is that its data drives the
ported renderer to the design's pixels for the same facts.

| Design element | Source | How parity is checked |
| --- | --- | --- |
| Planned card status line "Q1 · queued", "Q4 · held", "Q8 · waiting" | J:860 | C1-T02 `expectDesignParity(pair, { name: 'plan-cue-cards', region })` on the cards for design rows p1 (promoted), p4 (held) and p8 (waits on a running ticket), with the product page fed by the C3-T01 fixture source whose `plan` rows are **this module's output** for the §5 step 1 fixture. Same viewport (1440), clock (`NOW`, J:11), zone and palette as C1-T02. Zero tolerance beyond C1-T02's floor |
| `.bd-q.promo` "promoted 6m ago", `.bd-q.held` + `title`, `.bd-q` "waits on #N" | J:853-855; C:251-255 | Same region shots; plus a DOM assertion that the `title` of `.bd-q.held` equals "Held by Maya · release freeze until Thu" on both sides |
| `.bd-alert` "Prereq #F failed · blocks …", `.bd-q` "prereq chain failed" | J:856, J:858; C:257-258, C:268 (`.plan.blk`) | No design dataset sets `failed` or `blockedChain` (J:282, J:286), so a full-page shot cannot show them. C9-T05 owns their pixels with a markup-pair shot. This ticket's T-10 fixes the data (`by`, `blocks` order including self) that both sides render |
| Wave labels "W1 · 5 · ready", "W2 …" | J:503-508; C:197-199, C:355 | The `#bd-sec-plan` region shot in C9-T02 with the same fixture. Waves that differ from the design's hand-assigned values (§10 decision 7) are a data difference, not a style difference; that shot uses the design's own `live.json` waves |
| Section header "N in build-queue order · dependency waves" / "queue empty" and the empty marker | J:499, J:659; C:210-212 | C9-T13 with `noqueue` (`rows: []`, `state "ok"`). The S-9 unavailable marker is C9-T13's |
| Modal cues `.bm-cue`, `.bm-cue.bad` "this and N more" | J:1423-1425; C:592-594 | C11-T02, fed by this module's `held` text and `failed.blocks` |

A difference from the design in any shot above is a failing test unless Kevin
approved it in writing (tickets/README.md rules).

## 10. Decisions made without the owner

1. **The mapper is a pure web-side module** (`AiurWeb.Build.PlannedRows`), not
   a store. It sits inside the C3-T01 seam and keeps `build-orders` free of a
   `build-queue` dependency (contract RC-40 has only the reverse optional edge).
2. **`cue.wait` uses an `:active` set from the caller** (C8-T01's now rows)
   instead of reading agent state here. One source of "running" for the page.
3. **New `cue.unknown` field (CR-E8-10).** The design has no unknown readiness
   state, and every design default ("queued", W1 "ready") would be a plausible
   lie. Default rendering for C9-T05: status line "Q<n> · readiness unknown" in
   the existing muted `.bd-status` tone, no chip; the filter state is `blocked`.
   This is listed for Kevin with the S-items.
4. **Several queues are concatenated** in read-model order (CR-E8-11 asks
   MP-E1 for a global start order across queues). One queue is exact.
5. **`promoted_unauthorized` shows as held** ("Held · dispatch not authorized"):
   it will not start, and the design's held chip is the closest true look. The
   attention itself is MP-E1-C5-T04's.
6. **Hold text forms** (§4.2). The actor is never invented; a hold with no
   facts says so. Before CR-E8-5 lands, every operator hold reads
   "Held · no actor or reason recorded", which is true. CR-E8-5 does not name
   the fields; `hold_by` and `hold_reason` are this ticket's proposal for that
   request. If MP-E1 picks other names, change the one accessor; the §5 step 1
   fixture and the J:217 parity check use whatever names MP-E1 ships.
7. **Waves are computed, not copied.** The design assigns waves by hand: p11
   has no prerequisites but is W2 (J:224), and generated rows take a wave from
   their loop index (J:239-248). A computed level is the only honest wave for
   real data. p20 is a second hand-assigned case: it needs p18 (W4) and is
   itself W4 (J:231, J:233), so its computed wave is 5. T-design compares waves
   only where the design is consistent and lists the other rows in the test.
8. **Open `todo` tickets outside every queue are planned here** (options §3.3),
   with `qpos: nil` and W1, after the queue rows. The caller passes the todo
   label, because the C3-T01 seam does not allow `Aiur.GitHub.*`.
9. **MP-E1-C7-T02 stays a blocker.** This ticket reads no progress, but the
   queue signal that makes C8-T04 re-read planned rows is
   `Aiur.BuildProgress.subscribe/0`, and MP-E1-C7-T02 is what feeds
   `Aiur.BuildProgress` from the queue. Risk: a hold, release or promotion that
   does not change a progress fact may not fire that signal, so planned cues
   could lag until the next history or queue change. The contract's live topics
   (`ticket.<id>.queue.held` / `.released` / `.promoted`, contract §4.3) are the
   fix; this is a C8-T04 note (§11), not a change here.
10. **`observed_at` for the source is the oldest source time,** so the age shown
    is the worst one.
11. **`cue.failed` comes from edge verdicts, not from MP-E1-C5-T02 attentions.**
    The README row says "(MP-E1-C5-T02 attentions)". The attention carries the
    blocked set at the time it opened and does not re-fire when the set changes
    (MP-E1-C5-T02 "Chosen design": "the read model shows the current set"). So
    the read model's edges are the current truth, and the attention bus is not
    in the C3-T01 seam. MP-E1-C5-T02 stays a blocker so the `failed` verdict is
    real when this ships.
12. **`qpos` is the 1-based item order, not the read model's `position`.**
    `position` exists only for list queues and is a stored slot, not a start
    rank (§3). CR-E8-5's "queue position" item is therefore answered by the item
    order for one queue; CR-E8-11 covers several queues.

## 11. Completion and handoff

- [ ] `AiurWeb.Build.PlannedRows.read/1` and `build/3` with the §4.1 types.
- [ ] Every row in §6 has its test; each test fails under the listed mutation
      (PR body: one line per test, with the command).
- [ ] No empty-and-ok output for disabled, unsupported, unavailable or failed
      reads (T-03b..e).
- [ ] No `0`, capture-time or "ready" stand-in for an unknown fact (T-05, T-07,
      T-08).
- [ ] T-09 passes at 10,000 items; no call to `GraphAnalysis`.
- [ ] C3-T02 schema row and validator gain `cue.unknown` (additive).
- [ ] CR-E8-10, CR-E8-11 present in CONTRACT-REQUESTS.md (coordinator-owned).
- [ ] Seam test green.
- **Dependents:** C7-T02 (appends `pack:` rows after these, same `ord`
  sequence), C7-T03 (adds `est`/`override` to these rows), C7-T04 (uses the same
  todo-label rule to exclude), C8-T04 (calls `read/1`, passes `:active` and
  `:todo_label`, merges the other row fields, subscribes), C9-T05 and C9-T13
  (render cues and states), C11-T02 (modal cues and facts).
- **Interface notes for neighbours:**
  - C3-T02: Settled 2026-10-08: `cue.unknown` is in C3-T02's accepted additive
    fields table; `qpos: null` also occurs for outside-queue todo rows.
  - C8-T04: Settled 2026-10-08: C8-T04 keeps this module's `deps` for plan
    rows (not History `blocked_by`).
  - C9-T13: `sources.queue.observed_at` may be `nil` with `state "stale"`;
    render "age unknown", never "0s ago".
  - C7-T03: Settled 2026-10-08 (R-G12): `est` is absent from this output; C7-T03
    wires it into the C8-T04 assembler; until then the renderer shows "—".
  - C7-T02 and C9-T05: Settled 2026-10-08: a **filed** plan row can have
    `qpos: null` (§4.6); C7-T02's `queueText` and the C9-T05 status line render
    the no-queue form for `qpos == null`, not "Qnull". C11-T02 already does
    ("Queue —").
  - C8-T04 (part contract, its decision 5): Settled 2026-10-08: C8-T04 passes
    `:todo_label` and `:active`, takes the `%{rows, source}` return and `qpos:
    null` on filed rows. This module returns
    `%{rows, source}`, not `{:ok, rows} | {:error, reason}`, because
    `sources.queue` must tell `disabled` from `unavailable` (EC-03) and C8-T04's
    part table already takes "C7-T01's state". It has no `subscribe/0` (the
    C3-T01 seam does not list `Aiur.BuildProgress`); C8-T04 subscribes. Pass
    `:history_snapshot` so `snapshot/1` is copied once per flush. Consider also
    the contract §4.3 live `ticket.<id>.queue.*` topics (decision 9).
- **Sources:** tickets/README.md row C7-T01; chunks.md C7; plan.md §5, §6, §8
  (EC-03, EC-07, EC-21, EC-23), §10 items 9-10; options.md §3.3; questions.md
  §9; contract `queue-readiness-and-build-progress.md` §1-§3, §4.3, §5;
  MP-E1-C2-T01, C2-T03, C3-T03, C5-T02, C6-T01, C8-T01; MP-E8-C3-T01, C3-T02,
  C4-T01; design J and C lines cited above.
- **Remaining blocker:** DESIGN-E8 only.

## Review log

Adversarial review, 2026-10-08, against `58854d4c8`, the contract, MP-E1
C2-T01/C5-T02/C6-T01/C7-T02, MP-E8 C3-T02/C4-T01/C7-T02/C7-T04/C8-T04/C9-T05/
C11-T02 and design J/C lines. All cited code paths and line numbers were opened
and match. Changes:

1. §2, decision 9: MP-E1-C7-T02 is needed (it feeds the queue signal C8-T04
   uses); "can be dropped" removed. Lag risk recorded.
2. §6: removed the invented `build_queue:changed` topic; the signal is
   `Aiur.BuildProgress.subscribe/0` (contract §5, C8-T04).
3. §4.1: History input type corrected to C4-T01's `snapshot/1` reply
   (`{:ok, %{rows, health}}`); added `:history_snapshot` so the whole-map copy
   is made once; History read wrapped in `try` (step 3).
4. §3: J:1152-1153 is the list view with a different `blocked` rule, not the
   modal; added J:821 `.plan.blk`. Added the two verdict vocabularies and why
   `position` is not `qpos` (decision 12).
5. §4.4: `wait` is `nil` when `failed` is set (J:284). `failed.blocks` now
   built over all live queue items (claimed included); the claim that it always
   equals the MP-E1-C5-T02 alert set was corrected.
6. §4.6: queue-membership rule aligned with C7-T04 rule 2 (a hand-labelled
   `removed` item was lost between the two tickets); `labels: :unknown` is not
   a todo row; "design shows — for qpos null" corrected (design prints "Qnull").
7. §4.2: queue-level hold scoped to waiting/ready/held items, `queue_id`
   fallback for a `nil` name.
8. §8: T-03a and T-dup got real mutations; T-09 wall-clock assertion removed;
   T-10, T-23b, T-todo, T-hist extended for the new rules; T-design finds rows
   by title (live.json ids are `AIUR-n`), checks `wait`, and lists p20 as a
   second hand-assigned wave (decision 7).
9. §10: decisions 11 (edge verdicts over attentions) and 12 added; decision 6
   notes the `hold_by`/`hold_reason` names are a proposal.
10. §6/§8 T-08: an unknown item needs an unknown edge to reach wave ≥ 2; the
    no-prerequisite case is now explicit.
11. §11: interface notes for C7-T02/C9-T05 (`qpos: null` on filed rows) and
    C8-T04 (return shape, no `subscribe/0`, `:history_snapshot`).
- Reconciliation 2026-10-08 (coordinator): CR-E8-10/11 recorded by the coordinator (§2, step 5, §11 checklist), §11 interface notes for C3-T02, C8-T04, C7-T03, C7-T02/C9-T05 marked settled.
