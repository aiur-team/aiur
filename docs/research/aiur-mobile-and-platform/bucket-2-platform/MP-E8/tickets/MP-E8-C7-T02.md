---
ticket_id: MP-E8-C7-T02
feature_id: MP-E8
chunk_id: MP-E8-C7
bucket: 2-platform
title: Unfiled planning-pack items as planned rows
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C7-T01, MP-E8-C8-T04, MP-E8-C11-T02]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-23]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C7-T02 — Unfiled planning-pack items as planned rows

> **Wave 0b.** Code is cited at `origin/main` `58854d4c8`
> (`/home/everdred/github/everdred/aiur-worktrees/runtime/src`, repo-relative
> paths below start at `src/`). Paths marked PROPOSED do not exist yet.
> `J` = `design-source/assets/build.js`, `C` = `design-source/assets/build.css`.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C7 (planned,
  not-queued and estimates).
- **User value.** The operator sees the work that is planned in a planning pack
  but is not on GitHub yet. It sits after the queued tickets, in pack wave
  order, and it says plainly that it is not filed. When the publisher files an
  item, the row becomes the real ticket. The operator never sees the same work
  twice, and an old link to the unfiled row still opens the filed ticket.
- **Deliverable.**
  1. A public pack-read function on `AiurWeb.BuildOrder.PlanningSource` that
     returns the loaded packs **and** the packs that failed to load (today a bad
     pack is dropped without a trace).
  2. PROPOSED `AiurWeb.Build.UnfiledRows`: maps unfiled pack items
     (`ticket: null`) to payload rows with `id: "pack:<pack>/<item>"`,
     `sec: "plan"`, `num: null`, `qpos: null`, a `src` block, and a
     `sources.packs` state (`ok` / `disabled` / `unavailable`).
  3. The C8-T04 assembler gets a separate `packs` part: it appends these rows
     after the filed planned rows and puts a `was` alias on a filed ticket that
     replaced a pack row.
  4. The hook: one small helper module that replaces the design's
     `fromDoc = t.wave >= 5` mock rule, and every `"#" + t.num` /
     `"Q" + t.qpos` call site that can meet an unfiled row (or a filed plan row
     with `qpos: null`, C7-T01 §4.6). A source scan keeps later ports on the
     helper.
  5. The "planning packs unavailable" marker in the planned section.
  6. One added fixture dataset, `unfiled`, for parity and browser tests.
- **Non-goals.**
  - No writes to packs or GitHub. Filing is the publisher's job (aiur-build
    flow); the daemon has no writer of pack `ticket` numbers (no match for a
    `"ticket"` write under `lib/` at `58854d4c8`).
  - No estimates. `est` stays `null` here; C7-T03 fills plan-row estimates,
    pack rows included.
  - No "Add to queue" for unfiled rows (there is no issue to queue; C11-T02 shows
    that button only for `nq`).
  - No new operator config key. Packs come from the existing discovery
    (`Aiur.BuildOrder.PackPaths`) and the existing app-env overrides.
  - No change to the Build Order page or its catalog behaviour.

## Dependencies and blockers

- **DESIGN-E8** (Kevin's go). The design has no state for "a pack is unreadable",
  no real id for an unfiled item and no queue position for it. This ticket
  follows written defaults (see "Decisions made without the owner") and lists
  them for the C12-T08 sign-off package.
- **MP-E8-C7-T01** (row predecessor). It produces the filed planned rows and
  their `wave` (prerequisite level inside the queue rank) and `ord` (queue
  rank). This ticket needs the largest filed `wave` and `ord` to place pack
  rows after them.
- **MP-E8-C8-T04** (added; see "Interface mismatches"). C8-T04 already names
  "C7-T02 pack rows" in its non-goals, its parts table ("planned" row) and its
  D4 test ("filed pack row"), but its predecessor list does not include C7-T02,
  so nothing produces those rows when it lands. This ticket plugs into the
  assembler after it exists, instead of making C8-T04 wait. C8-T04 brings
  C3-T02 (payload schema and validator) with it.
- **MP-E8-C11-T02** (added). The modal views (C11-T01 head, C11-T02 issue view)
  and the card renderer (C9-T05, upstream of C11-T01) contain most of the
  `fromDoc` / `#num` / `Qqpos` call sites. Landing after them lets this ticket
  patch the sites once. C11-T02 brings C11-T01, C3-T03 and C9-T05 with it.
- **Contracts.** Payload schema v1 (C3-T02). This ticket adds three fields to it
  (`src`, `was`, `sources.packs`) in the same PR, with validator cases.
- **May run concurrently with** C7-T03, C7-T04, C9-T06..T13, C10-*, C11-T03..T10.
  File overlap: the hook helper call sites in C9-T11 (tree) and C9-T12 (list) if
  they are still open. The source scan settles the order: whoever lands second
  uses the helper.
- **OQ / S items.** None in the row. Two new design gaps are proposed for
  DESIGN-E8 (**S-27** and **S-28** below; the numbers are final in DESIGN-E8);
  their defaults apply until Kevin answers.

## Verified starting point (`58854d4c8`)

**Pack loading (reused).**
- `src/lib/aiur_web/build_order/planning_source.ex:1-18` moduledoc: a
  "pre-ticket Build Order data source", selected by
  `config :aiur, :build_order_data_source, AiurWeb.BuildOrder.PlanningSource`;
  "read-only demo/planning tooling". `:20` `@behaviour AiurWeb.BuildOrder.DataSource`.
  It *replaces* the live source; it is not an extra feed.
- `src/config/config.exs:20-25` selects it only when `AIUR_BUILD_ORDER_DEMO=1`.
- `planning_source.ex:43-60` `catalog/0` calls `load_packs()` (`:45`);
  `:77-110` `selected_snapshot/1` calls `load_packs(include_drafts?: true)` (`:80`).
- `planning_source.ex:545-559` `defp load_packs/1`: `pack_paths()` →
  `load_pack/2` → **`:error -> []`** (a broken pack disappears silently, `:551-553`)
  → `filter_for_tracked_repository/1` (`:564-570`) → `reconcile_duplicate_packs/1`
  (`:664`) → `Enum.sort(&pack_before?/2)` (`:918-924`) → default root numbers and
  icons.
- `planning_source.ex:575-586` `defp pack_paths/0`: `:build_order_planning_pack`
  (explicit) → `:build_order_planning_packs` (configured list) →
  `PackPaths.discovered_sources/0` (`:590-592`).
- `planning_source.ex:617-655` `defp load_pack/2` returns `%{source, path,
  repository, build_order_id, build_order_id_explicit?, title, completed,
  tickets, ...}` (`:631-652`).
- `planning_source.ex:771-795` `defp ticket/3`: keeps `id, title, lane, phase,
  complexity, number, depends_on, document_path, ...`. Any other key is dropped.
  `:801` `ticket_phase/1` = `"phase"` or `"phase_hint"` or `0` (so a missing
  phase and an explicit `0` are the same value); `:803`
  `ticket_complexity/1`; `:807-813` `safe_document_path?/1` requires
  `tickets/...`; `:879-882` `ticket_number/1`: `"ticket": N` (N > 0) → filed,
  `"ticket": null` → unfiled, `"github": {"number": N}` → filed, anything else
  (no `ticket` key and no `github.number`) → the item is `:error` and
  `tickets/3` (`:756-767`) halts, so the whole pack is `:error`. The format
  sample in `priv/build_orders/README.md` (`"github": null`, no `ticket`, no
  `doc`) would therefore fail to load today.
- `planning_source.ex:926-930` `configured_repository/0` already rescues a
  failing `Config.repo()` (returns `nil`); `:932` `absolute_path/1` calls
  `Path.type/1`, which raises on a non-chardata entry in
  `:build_order_planning_packs`.
- `src/lib/aiur/build_order/pack_paths.ex:39-46` `discovered_sources/0`
  (`{:workspace | :state | :override, path}`); `:113-118` workspace directory
  `<cwd>/.aiur/build_orders` (overridable by `:build_order_workspace_directory`);
  `:120-128` state directory `RepoBase.builds_path/1` (`src/lib/aiur/repo_base.ex:85-86`,
  `<repo>/builds`), state packs are `*/build-order.json` (`pack_paths.ex:90-100`).
- `src/priv/build_orders/README.md` pack format: `"phase": 1 // execution wave
  (row)`, `"lane": "core" // epic / workstream (column)`, `"complexity"`,
  `"depends_on"`, `"github": null // filled once materialized`.
  `src/priv/build_orders/aiur-build-order.json` is a shipped pack (54 tickets,
  `completed: true`, every item filed). The `priv` packs load only through the
  explicit override, not through discovery.
- **Census of real discovered packs (this host, 2026-10-08, read-only scan of
  `~/.aiur/repo/*/*/builds/*/build-order.json`, 9 packs).** 8 packs have every
  item filed (13–98 items each). One, `aiur-team/aiur:platform-program-2026-10`,
  is 284 KB with 647 items, **604 unfiled**, phases `0, 2, 3, 4, 5, 6` (43
  items in phase `0`), item ids up to 13 characters, all matching
  `^[A-Za-z0-9._-]+$`, a `feature` key on items (values such as `MP-E1`, not
  dashboard feature keys), no `epic` or `type` key. So the population this
  ticket meets on the dogfood daemon is about 604 rows from one pack, and phase
  `0` is a real first wave, not "unknown".
- `src/lib/aiur/build_order/pack_status.ex:51` `@topic`,
  `:79` `subscribe/0`, `:226-232` `broadcast_changed/1`. It has no timer of its
  own (moduledoc `:24-27`): `Aiur.GitHub.ViewStateSweep` drives it
  (`view_state_sweep.ex:95` default 15 minutes), and `record_result/2`
  (`:163-181`) broadcasts only when `status.json` changed or the reconcile
  failed. A publisher writing `"ticket": 1234` into a pack fires no signal by
  itself.
- Tests: `src/test/aiur_web/build_order/planning_source_test.exs` (45 KB). Setup
  `:60-87` writes a temp pack and sets `:build_order_planning_pack`;
  `:140-147` "missing pack yields no catalog rather than crashing";
  `:660-672` "rejects members without canonical ticket or document fields".
  The setup's `:build_order_planning_pack` wins over
  `:build_order_planning_packs` in `pack_paths/0` (`:575-586`) and also turns
  off the repository filter (`:564-570`). A test of the configured list must
  delete it and write `Config.repo()` as the pack repository, as
  `:150-172` does. A test of `:state` discovery sets `:repo_base_root` to a
  temp directory and deletes both overrides and `AIUR_BUILD_ORDER_DIRS`, as
  `:808-832` does (`RepoBase.base_root/0`, `repo_base.ex:1498-1500`, falls back
  to `~/.aiur/repo` otherwise).
  `Aiur.TestSupport.tmp_root!/1` is `src/test/support/test_support.exs:167-169`.
- Source-scan precedent: `src/test/aiur/orchestrator/resume_decline_reason_test.exs:39-51`
  (`File.read!` + `Regex.scan`, `assert MapSet.size(literals) > 0`).
- Browser specs run through `node scripts/run-browser-tests.mjs tests/<x>.browser.spec.mjs`
  (`src/browser/package.json:10` chain).

**Neighbour contracts (PROPOSED, read from their ticket docs).**
- C3-T02 payload: row `id` is `"pack:<slug>"` for an unfiled item, `num: null`
  and `qpos: null` only for `pack:` rows (C3-T02 "Ticket row" table). The
  validator's id rule is `^[1-9][0-9]*$` or `^pack:[a-z0-9][a-z0-9-]{0,63}$`
  (C3-T02 implementation step "validate"): lower case, no `/`, no `.`. Row key
  sets are closed (an unknown key is an error). `sources` keys are
  `history | queue | agents | index` with `state: ok | stale | unavailable |
  disabled`, and a missing key is a validation error.
- C4-T04 / C4-T05 add row keys `start_src`, `children`, `dep_states`
  (`id => cleared | blocking | terminal_unsatisfied | unknown`) and
  `deps_missing` (C4-T05 table). C8-T04's row table: `plan` rows have `pct: 0`.
- C7-T01 `PlannedRows`: `ord` is 0-based; `cue` has **seven** keys
  (`held, promoted, wait, waitAny, failed, blockedChain, unknown`); filed plan
  rows with `qpos: nil` exist (§4.6, todo-labelled tickets outside a queue) and
  C7-T01 asks this ticket's `queueText` not to print `Qnull` for them.
- C8-T04: the Index coalesces signals for **250 ms**; its "planned" part, on a
  queue failure, sets `sections.plan = []`; its diff puts `remove` of a
  `pack:` id and the upsert of the real id in one message (D4).
- C9-T05 and C11-T01 already render the id slot of a pack row as `—` with
  `title="Not filed yet"` (C9-T05 unknown table; C11-T01 head table, `.bm-num`),
  and the card status label as "Planned · not filed". C11-T01 writes
  `ticket: ""` to the URL for a pack row and hands "the `was` lookup in
  `modalSync` and the `pack:` id rule in `ticket_id/1`" to this ticket. C11-T02
  `open/2` pushes nothing for a `pack:` id.
- C9-T12 interface note 5: the list status chip (`stText`/`stClass`, J:1152-1153)
  would say "Queued" for an unfiled row.
- C3-T03 URL state: `ticket` must match `^[0-9]{1,10}$` (C3-T03 parse table);
  its note 2 assumes a `pack:` id never reaches the parser.
- C3-T01 seam scan: `lib/aiur_web/build/**/*.ex` may reference
  `Aiur.BuildOrder.*` and `AiurWeb.BuildOrder.Runtime`, but not
  `AiurWeb.BuildOrder.PlanningSource`.
- C1-T02 allowlist: `design-removal | pixel-mask | design-style | property |
  motion | axe | copy` entries, each with `approval.status: pending-sign-off |
  approved`. The loader rejects any other spelling (C1-T02 test N10).

**Design source (what must match).**
- J:1378 `const fromDoc = t.sec === "plan" && t.wave >= 5;` — mock rule.
- J:1379 `stLabel`: `fromDoc ? "Planned · not filed" : "Queued · Q" + t.qpos`.
- J:1380 tone: a `plan` row is `"idle"` (`.bm-st` grey dot, C:484-485).
- J:1394 head link: `<a class="bm-ib" href="#" data-a="none" title="From
  docs/build-plan.md · wave N">` + `I.docs`, instead of the GitHub issue link.
  J:1445 `if (a === "none") { ev.preventDefault(); return; }`. `.bm-ib` is
  30×30 px, radius 8 px, `color: var(--muted)`, `cursor: pointer`, hover
  `var(--surface-3)` (C:495-498); svg 15×15.
- J:1429 `.bm-src`: `I.docs + "docs/build-plan.md · wave " + t.wave + " · not
  filed yet"`. `.bm-src` is flex, gap .45rem, `.72rem "JetBrains Mono"`,
  `var(--muted)`, margin-bottom 1rem; svg 14×14 (C:587-588).
- J:1434 facts: `Queue Q<qpos>` and `Wave W<wave>` for plan rows; `fact("Queue",
  "—")` is the design's own "no queue" rendering.
- J:499 the plan-section empty marker: `{ kind: "empty", y: SEC, h: 96, label,
  sub }`, section height `SEC + 104`; rendered at J:719-724 as
  `.bd-mk.empty` with `<b>label</b><p>sub</p>` (C:210-212: column flex, gap
  .3rem, `b` .95rem, `p` .82rem `var(--muted)`, max-width 46ch).
- J:503-508 waves: one label per distinct `t.wave`, text
  `list.length + (w === 1 ? " · ready" : "")`.
- J:659 header: `"Planned <em>" + pc + " in build-queue order · dependency
  waves"` where `pc = D.plan.length` (pack rows count, as in the design).
- J:333 `tstate`: plan row → `held` / `blocked` (if `waitAny || failed ||
  blockedChain`) / `queued`.
- J:237 `TARGET = [8, 10, 11, 9, 7, 9]` items per wave: the design's
  "from docs" rows are waves 5 and 6, 16 rows in `live`.
- Call sites that print a GitHub number or queue position and can meet a pack
  row: J:830, 832, 837, 840 (card titles and `.bd-id`), J:860 (card
  `.bd-status` `"Q" + t.qpos`), J:1152-1153 (list chip `stClass`/`stText`:
  a plan row is `st-queued` "Queued"; `.lst.st-open` is C:736), J:1161, 1163
  (list `.lr-mu`, `.c-id`), J:1210,
  1212, 1214 (tree), J:1312 (conversation dependency event), J:1386 (`.bm-num`),
  J:1394, J:1420 (`.bm-dep`), J:1429, J:1434.
- `.bd-id` is `white-space: nowrap` with no overflow rule outside the mini tier
  (C:237, 311, 443).

## Chosen design

### Server: reading packs

Add one public function to `PlanningSource` (reuse; no move):

```elixir
@doc """
Loads every planning pack the Build Order catalog would load, and also reports
the packs that could not be read. Used by the home page as an extra read; it
never changes which DataSource is selected.
"""
@spec load_pack_results() :: %{
        configured: non_neg_integer(),
        packs: [map()],
        failed: [%{source: atom(), path: Path.t()}]
      }
```

- `configured` = `length(pack_paths())`. `0` means "no pack configured".
- `failed` = every `{source, path}` whose `load_pack/2` returned `:error`
  (unreadable, invalid JSON, bad schema, bad `doc` path).
- `packs` = the same pipeline `load_packs/1` runs today (tracked-repository
  filter, duplicate reconcile, sort). `load_packs/1` is rewritten to call the
  shared pipeline, so the catalog's output does not change.
- `ticket/3` is **not** changed. The pack's `lane` (the README calls it "epic /
  workstream") is already kept and is the epic input. No real pack carries
  `epic` or `type` (census above), and the `feature` values seen are pack
  feature ids, not dashboard feature keys, so new keys would match nothing.

C3-T01's seam allowlist gets one entry, `AiurWeb.BuildOrder.PlanningSource`
(only `load_pack_results/0` is called), with a `# ponytail:` comment: moving the
loader to `Aiur.BuildOrder` is MP-R1's job, not this ticket's.

### Server: rows (PROPOSED `src/lib/aiur_web/build/unfiled_rows.ex`)

```elixir
@spec build(%{
        filed_numbers: MapSet.t(pos_integer()),   # every num in the index
        done_numbers: MapSet.t(pos_integer()),    # hist rows with status "done"
        max_wave: non_neg_integer(),              # largest filed plan wave, 0 if none
        max_ord: integer(),                       # largest filed plan ord, -1 if none
        epics: MapSet.t(String.t()),
        now: integer()                            # ms, daemon clock
      }, keyword()) ::
        %{rows: [map()], aliases: %{pos_integer() => String.t()}, source: map()}
```

`opts[:loader]` defaults to `&PlanningSource.load_pack_results/0` (test seam).

**Which items.** From each pack that is not `completed`, each item with
`number: nil`. Items with a number are filed: they get no row here. They add
`aliases[number] = pack_id` so the assembler can mark the real row.

**Ids.** `pack_id = "pack:" <> pack_key <> "/" <> item_id`.
- `pack_key` = the part of `build_order_id` after the last `:` when
  `build_order_id_explicit?` (for example `build-order-dashboard`), else `"p"` +
  the first 8 hex of `sha256(path)`. Two packs without ids can no longer collide
  on the `"planning"` fallback (`planning_source.ex:712-713` `normalized_build_order_id/1`).
- Both parts must match `^[A-Za-z0-9._-]{1,64}$`. An item id outside that is
  skipped and counted as a failure (see sources). No escaping tricks. This is
  wider than C3-T02's `^pack:[a-z0-9][a-z0-9-]{0,63}$`; this ticket changes that
  validator rule (step 3), because real item ids are upper case (`CLI-LOGIN-T01`)
  and lower-casing them could merge two ids.
- Two explicit ids whose suffixes are equal (`a/x:demo`, `b/x:demo`) cannot
  both reach here: the repository filter keeps one repository. Two such packs
  in the same repository get the same `pack_key`; the second pack's items are
  then skipped and counted as failures (no silent overwrite, U11b).

**Order and waves.**
- Pack phases are ranked densely over all included items: distinct
  non-negative integer phases, ascending → rank 1, 2, …. `0` is a real phase:
  aiur-build writes it (43 items in the census pack) and the Build Order page
  already treats a missing phase as `0` (`ticket_phase/1`). An item whose phase
  is not a non-negative integer (`"2"`, `-1`, `1.5`) goes into one last rank
  group.
- Row `wave = max_wave + rank`. The board's W labels therefore follow the filed
  waves (the design's W5/W6 after W1–W4) and never mix pack items into a filed
  wave group.
- Sort key: `{rank, pack order from load_pack_results, item index in the pack}`.
  `ord = max_ord + position` (1-based, so the first pack row follows C7-T01's
  0-based last `ord`). There is no queue position. (C8-T04's row table says
  `plan` `ord` = `qpos`; that rule cannot apply to a row with `qpos: null`, so
  pack rows keep this `ord`.)

**Row fields** (C3-T02 names):

| Field | Value |
| --- | --- |
| `id` | `pack_id` |
| `num`, `qpos`, `start`, `end`, `created`, `agent`, `pr`, `override`, `est` | `null` |
| `pct` | `0` (C8-T04 rule for `plan` rows) |
| `start_src` | `"unknown"` (C8-T04 "Unknown" column) |
| `title` | the item `title` (raw; the payload scrubs UTF-8) |
| `type` | `"feature"` (packs carry no type; the type only picks an icon) |
| `epic` | the item `lane` when it is in `epics`, else `null` (Unsorted) |
| `feature`, `also` | `null`, `[]` |
| `cx` | the item complexity when an integer 1..5, else `null` |
| `pts` | `[1, 2, 3, 5, 8]` at `cx - 1` (the design's `PTS`, J:93), else `null` |
| `sec`, `status` | `"plan"`, `"queued"` |
| `ord`, `wave` | as above |
| `deps` | each `depends_on` id, in pack order: a filed pack item whose number is in `filed_numbers` → `"<number>"`; an unfiled included one → its `pack_id`; anything else (not in the pack, filed but not in the index, skipped id) → dropped (C3-T02: ids not in the index are dropped by the producer) |
| `deps_missing` | the count dropped from `deps` |
| `dep_states` | per `deps` id: a `pack:` id → `"blocking"`; a number in `done_numbers` → `"cleared"`; any other number → `"blocking"` |
| `children` | the `pack_id`s of included pack rows whose `deps` hold this row's id, in `ord` order |
| `cue` | `{held: nil, promoted: nil, wait: nil, waitAny: <any dep_states value is "blocking">, failed: nil, blockedChain: false, unknown: false}` (C7-T01's seven keys) |
| `added` | `false` |
| `src` (new) | `{kind: "pack", path: display_path, wave: phase \| null}` (`phase` when a non-negative integer) |
| `was` (new) | `null` on pack rows |

The pack row's own id, not a display ref, is the provisional id. The item id
is not printed anywhere (decision 2), so `src` carries no `ref`.

**`display_path`** never shows an absolute path (EC-30, no per-machine paths):
- `:workspace` → `".aiur/build_orders/" <> basename`;
- `:state` → `"builds/" <> parent dir name <> "/build-order.json"`;
- `:override`, `:configured`, `:explicit` → `Path.basename(path)`.

**`source`** (`sources.packs`, new key):

| Situation | `state` | `reason` | rows |
| --- | --- | --- | --- |
| `configured == 0` | `disabled` | `"no_pack_configured"` | none |
| all loaded, all ids valid | `ok` | `null` | all |
| some failed | `unavailable` | `"<k> of <n> planning packs could not be read: <display paths>"` | from the good packs |
| all failed | `unavailable` | same text | none |
| items skipped (bad id, duplicate `pack_key`) | `unavailable` | `"<j> planning-pack items could not be read: <display paths>"`, joined with `"; "` after the pack text when both apply | all other rows |
| the loader raised | `unavailable` | `"planning packs could not be read"` | none |

`observed_at = now` in every case. There is no `stale`: packs are read from disk
on every build. `ok` with zero rows is a real empty state (every item filed).

### Assembler hook-up (C8-T04's module)

- Add one row to C8-T04's parts table: **packs** — read `UnfiledRows.build/2`
  **on every flush** (as the `epics` part is), signal
  `Aiur.BuildOrder.PackStatus.subscribe/0` (`pack_status.ex:79`, message
  `{:build_order_pack_status_changed, _}`), on failure `sources.packs =
  unavailable` and no pack rows. It is separate from the "planned" part, so a
  queue failure (`sections.plan = []` for filed rows) still shows pack rows,
  and a pack failure never hides filed rows. Reading on every flush is what
  bounds the duplicate window of N7: any later signal re-reads the packs.
- Call it after the filed planned rows exist (it needs `max_wave`, `max_ord`).
  Append its rows to `sections.plan`; put its `source` at `sources.packs`.
- For each `{number, pack_id}` in `aliases` where row `"<number>"` is in the
  index, set that row's `was = pack_id`. All other rows get `was: null`.
- For each pack row dep that is a number, append the pack id to that filed
  row's `children` (C4-T05 builds `children` from History edges only, so it
  cannot know pack rows).
- The filing move is one diff: the same generation carries
  `remove: ["pack:k/ITEM"]` and the upsert of `"1234"` with `was: "pack:k/ITEM"`.
  C8-T04's D4 already proves the remove and upsert share a message; this ticket
  extends D4 to assert `was`.

### Client (hook)

PROPOSED `src/priv/static/build-home/unfiled.js`, placed in C9-T01's module
layout:

```js
export const isUnfiled = (t) => t.num == null && t.src != null && t.src.kind === "pack";
// "—" + title "Not filed yet" is the C9-T05 / C11-T01 pack default; keep one source.
export const refText   = (t) => isUnfiled(t) ? "—" : "#" + t.num;
export const refTitle  = (t) => isUnfiled(t) ? "Not filed yet" : "#" + t.num;
export const queueText = (t) => isUnfiled(t) ? "Not filed" : t.qpos == null ? "Q?" : "Q" + t.qpos;
export const srcLine   = (t) => t.src.path + (t.src.wave != null ? " · wave " + t.src.wave : "") + " · not filed yet";
export const srcTitle  = (t) => "From " + t.src.path + (t.src.wave != null ? " · wave " + t.src.wave : "");
export const findWas   = (rows, id) => rows.find((r) => r.was === id) || null;
```

`refText`/`refTitle` reproduce what C9-T05 (card) and C11-T01 (`.bm-num`)
already render for a pack row, so those two tickets' tests stay green; their
inline branches are replaced by the helper. `Q?` for a filed row with
`qpos: null` is C11-T01's head wording ("Queued · Q?") and C9-T05's `?`
unknown marker; it closes C7-T01 §4.6's `Qnull` request.

Call-site changes (port text otherwise unchanged; every string still goes
through `esc`):
- J:1378 `fromDoc` → `isUnfiled(t)`. J:1379 label unchanged ("Planned · not
  filed"); the filed branch uses `"Queued · " + queueText(t)`. J:1394 `title` →
  `esc(srcTitle(t))`, plus `aria-label` (same text) and `aria-disabled="true"`;
  `href="#"` and `data-a="none"` stay, so J:1445 keeps the click inert. J:1429
  → `I.docs + esc(srcLine(t))`.
- J:830/832/837/840/1163/1212/1214/1312/1386/1420: `"#" + x.num` →
  `esc(refText(x))`; the `title` attributes at J:830/832/837 use
  `refTitle(x)`.
- J:860 card status: unfiled → `"<span>Not filed</span>"` with no cue suffix
  (`· held` etc. never apply: `held` and `failed` are `null`); filed →
  `queueText(t)` + the cue suffix. The second span (`≈est h · pts`) is C9-T05's
  and C7-T03's (they render unknown `est`/`pts`).
- J:1152-1153 list chip: unfiled → class `st-open`, text "Not filed" (C9-T12
  note 5; `.lst.st-open`, C:736, is the design's own "not in the queue" chip).
- J:1161 list and J:1210 tree: `"Q" + t.qpos` → `queueText(t)`.
- J:1434 facts: unfiled → `fact("Queue", "—")` + `fact("Wave", "W" + t.wave)`;
  filed → `fact("Queue", queueText(t))`.
- J:508 wave label: `" · ready"` only when `w === 1 && list.some((x) => !isUnfiled(x))`.
  (With an empty queue the first pack wave is W1; it is not "ready".)
- Plan-section marker: when `sources.packs.state === "unavailable"`, push one
  `{kind: "empty", y, h: 96, label: "Planning packs unavailable", sub: reason +
  " · checked " + fmtT(observed_at)}` (`fmtT`, J:17) after the last wave (after
  the "Nothing planned" marker when the queue is empty), and add 104 to the
  section height, the same geometry as J:499.
- C11-T01 open path: for a pack row, write `writeURL({ ticket: t.id })` instead
  of `ticket: ""` (C11-T01 "Open, replace, close"), and update C11-T01 B18 to
  expect `ticket=pack:…` in the URL. In `modalSync` (C11-T01): when the open id
  leaves the index, `findWas(rows, id)` replaces the modal with the filed row
  and writes `ticket=<num>`. Only when both miss does S-10 "Ticket not found"
  show.
- Server, in the same PR: C11-T01's `ticket_id/1` and C3-T03's `ticket` rule
  accept `^[0-9]{1,10}$|^pack:[A-Za-z0-9._-]{1,64}/[A-Za-z0-9._-]{1,64}$`;
  C11-T01's by-id `ticket/2` on `IndexSource` answers a `pack:` id with the
  pack row, else with the row whose `was` equals it, else `not_found`. So
  "Copy link" on an unfiled row (J:1396) gives a link that still works after
  filing, also for a row outside the loaded window. C11-T02 `open/2` is
  unchanged (it pushes nothing for a `pack:` id).

### Invariants

1. A pack row never has a `num`, `qpos`, GitHub URL or `est` that it does not
   have. The client never prints `#null`, `Qnull`, `null`, `undefined` or `NaN`
   for a pack row.
2. A filed item is never a pack row. One unit of work is one row, except in the
   N7 window (issue created, pack not yet rewritten), which this ticket bounds
   but cannot close.
3. `sources.packs` is always present. `disabled` and `unavailable` are never
   shown as an empty, healthy plan.
4. No absolute filesystem path reaches the payload.

## Implementation steps

1. **`planning_source.ex`.** Split `load_packs/1` (`:545-559`) into
   `load_results(include_drafts?)` → `{loaded, failed}` and a private
   `finish/1` (filter, reconcile, sort, defaults). `load_packs/1` returns
   `finish(loaded)`; add public `load_pack_results/0`. No other change
   (`ticket/3` is untouched; `lane` is already kept).
2. **C3-T01 seam allowlist** (PROPOSED `src/test/aiur_web/build/seam_test.exs`):
   add `AiurWeb.BuildOrder.PlanningSource` with the ponytail comment.
3. **C3-T02 schema** (PROPOSED `src/lib/aiur_web/build/payload.ex`): add
   `src: {kind: "pack", path: str, wave: non_neg_int | null} | null`
   (required non-null exactly on `pack:` rows), `was: "pack:…" | null`, and the
   `packs` key in `sources`. Widen the id rule from
   `^pack:[a-z0-9][a-z0-9-]{0,63}$` to
   `^pack:[A-Za-z0-9._-]{1,64}/[A-Za-z0-9._-]{1,64}$` (the same regex as step
   8), for row ids, `deps` ids and `was`. Validator cases: V1–V6 below.
4. **`AiurWeb.Build.UnfiledRows`** (PROPOSED) as in "Chosen design". About 150
   lines. No process, no state. It wraps the loader call in `try/rescue` (N4).
5. **Assembler** (C8-T04's real DataSource): the `packs` part (read on every
   flush, `PackStatus.subscribe/0` signal, its own failure row), the `was`
   marking, the `children` append.
6. **Hook**: add `unfiled.js`; patch every call site listed above that exists at
   your base, including C9-T05's and C11-T01's inline pack branches (replaced by
   the helper, same output) and C11-T01's `writeURL` pack branch and
   `modalSync`; patch C9-T11/C9-T12 sites if they have landed.
7. **Hook source scan** (PROPOSED `src/test/aiur_web/build/unfiled_scan_test.exs`):
   over `src/priv/static/build-home/**/*.js` except `unfiled.js`, fail on
   `~r/"#"\s*\+\s*\w+\.num\b/`, `~r/"Q"\s*\+\s*\w+\.qpos\b/`, the template
   forms `~r/#\$\{\s*\w+\.num\s*\}/` and `~r/Q\$\{\s*\w+\.qpos\s*\}/`,
   `~r/wave\s*>=\s*5/` and `~r/build-plan\.md/`, with file and line. Assert at
   least one file was scanned (precedent above).
8. **C3-T03 and C11-T01 `ticket_id/1`**: widen the `ticket` rule; add the parse
   cases below; correct C3-T03 note 2. **`IndexSource.ticket/2`** (C11-T01):
   the `pack:` and `was` lookups.
9. **Fixtures.** PROPOSED `src/test/support/build_home/unfiled_fixture.ex`:
   `convert(live)` turns every `plan` row with `wave >= 5` into a pack row
   (`id: "pack:build-plan/BP-<num>"`, `num: null`, `qpos: null`, `src: {kind:
   "pack", path: "docs/build-plan.md", wave: <wave>}`, `sources.packs: ok`) and
   rewrites `deps`, `children` and `dep_states` keys that point at them. The
   fixture source (C3-T01) serves it as dataset `unfiled`, and
   `unfiled_unavailable` as the same data minus those rows with
   `sources.packs` = `unavailable`, reason
   `"1 of 2 planning packs could not be read: broken.json"`. The other datasets
   are unchanged (C3-T02's mapping keeps their wave ≥ 5 rows queued). The path
   `docs/build-plan.md` is fixture-only (it matches the design text); the real
   loader never produces it.
10. **Browser spec** PROPOSED `src/browser/tests/build-home-unfiled.browser.spec.mjs`,
    npm script `test:build-home-unfiled`, appended to the `test` chain
    (`src/browser/package.json:10`).
11. **Allowlist entries** in C1-T02's `design-parity-allowlist.json` (see Pixel
    parity), all `"status": "pending-sign-off"`.

## Non-happy paths

| # | Input | Expected | Test |
| --- | --- | --- | --- |
| N1 | No pack paths at all (default repo) | `sources.packs = disabled / no_pack_configured`; no pack rows; no marker; plan header counts only filed rows | U1 |
| N2 | One of two packs is invalid JSON | `unavailable`, reason names `k of n` and the display path; rows from the good pack present; marker shown with "checked HH:MM" | U2, B4 |
| N3 | Every pack invalid | `unavailable`, zero pack rows, marker shown | U3 |
| N4 | Loader raises (for example a non-string entry in `:build_order_planning_packs`: `absolute_path/1` → `Path.type/1` raises; `Config.repo` failures are already rescued at `:926-930`) | `unavailable` with reason `"planning packs could not be read"`, assembler alive, filed rows unaffected | U4 |
| N5 | Item filed (`ticket: 1234`), 1234 in queue | no pack row; real row `was = "pack:k/ITEM"` | U5 |
| N6 | Item goes from `null` to `1234` between two builds | one diff: `remove` pack id + upsert `"1234"` with `was`; never both rows in one snapshot | A1 |
| N7 | Issue 1234 already polled, pack not yet rewritten; or pack rewritten with no later signal | **transient duplicate**. The pack write itself fires no signal (PackStatus broadcasts only when `status.json` changes, at the sweep cadence, 15 min by default). Because the `packs` part is read on every flush, the duplicate ends at the next flush caused by any signal (queue, history, agents, PackStatus, or C8-T04's 15 s `:daemon_tick`), so it lasts at most about 15 s after the pack write. No title heuristic: two items may share a title. Documented, not hidden | A3 |
| N8 | Modal or URL open on `pack:k/ITEM` after filing | opens `#1234` via `was`; URL patched to `ticket=1234` | B5, A4 |
| N9 | `?ticket=pack:k/ITEM` for an item that no longer exists anywhere (or whose pack is now `completed`, so no alias) | S-10 "Ticket not found" | B6 |
| N10 | Item `complexity` missing or `7` | `cx: null`, `pts: null`; never `1` | U6 |
| N11 | Item `phase` `"2"` / `-1` | last rank group; `src.wave: null`; source line has no "wave" part | U7, H2 |
| N11b | Item `phase` `0` or missing (`ticket_phase/1` → `0`) | ranked first, as a real wave; `src.wave: 0` | U7 |
| N12 | Queue empty (`max_wave = 0`) and pack rows exist | first pack wave is W1, label without "· ready"; no "Nothing planned" marker (the section is not empty, J:499) | U8, H3 |
| N13 | Queue `disabled`/`unavailable` (C7-T01) and pack rows exist | the queue's own S-9 marker **and** the pack rows (separate `packs` part); `max_wave = 0` | A2 |
| N14 | `depends_on` cycle or unknown id inside a pack | straight map, no recursion; unknown ids dropped and counted in `deps_missing`; client chain walk is C9-T11's cycle-safe port | U9 |
| N14b | Dep on a filed item that is merged / open / not in the index | `dep_states` `cleared` / `blocking` / dropped; `waitAny` false only when every dep is `cleared` | U16 |
| N15 | Item id `"../x"` or 200 chars | item skipped; counted in the `unavailable` reason | U10 |
| N16 | Two packs without `build_order_id` | distinct `pack_key` from path hash; no id collision | U11 |
| N16b | Two packs in one repository whose explicit ids end in the same suffix | second pack's items skipped and counted as failures | U11b |
| N17 | Pack for another repository in discovery | dropped by the existing `filter_for_tracked_repository/1`; not counted as failed | U12 |
| N18 | Completed pack with unfiled items | no rows and no aliases (`completed` packs are history, not plan) | U13 |
| N19 | Title `<img onerror>` / invalid UTF-8 | escaped by `esc` on render; scrubbed by C3-T02 | B7 (reuses C3-T02 hostile fixture rule) |
| N20 | Read-only dashboard | nothing to write; same rows | — (no write path) |
| N21 | Large pack: the census pack, 604 unfiled items | 604 rows, no cap (no silent data loss); mean row within C3-T02's 400 B budget, so about 240 KB added, under C3-T02's 512 KB warning; C12-T06 owns the large-index measurement | U17 |
| N22 | Filed plan row with `qpos: null` (C7-T01 §4.6) | "Q?" on card, list, tree and the head label; never `Qnull` | H4 |

Security: the only filesystem input is the existing discovery set; this ticket
does not read item documents (`include_drafts?` stays `false`). No path reaches
the browser except `display_path`. Concurrency: the loader is a pure read; a
pack being rewritten during a read fails JSON decode → `unavailable` for that
build only, and the next build recovers.

Performance: packs are read on every Index flush (C8-T04 coalesces signals for
250 ms, so at most four reads a second under load). The census pack is 284 KB;
`Jason.decode/1` of that size is a few milliseconds, inside the Index process,
not per socket. No caching is added; this ticket claims no saving. If C12-T06
finds the flush slow, a cache keyed by file mtime is the follow-up.

## Compatibility and rollout

- No config key, no migration, no CLI change. No docs page changes here: the
  home page's documentation is C12-T07, which must mention "Planned · not filed"
  rows and the "Planning packs unavailable" marker (handoff below).
- `PlanningSource` behaviour for the Build Order page is unchanged; its 45 KB
  test file must pass untouched.
- Payload v1 gains optional-shaped fields with strict rules. This lands before
  cutover (C12-T01), so there is no deployed client to break.
- Rollback: revert the PR. Pack rows disappear; `sources.packs` disappears with
  the schema change in the same revert.

## Verification

Run from `src/` with an isolated home and no GitHub tokens (a local `mix test`
otherwise touches `~/.aiur`):
`env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur_web/build/unfiled_rows_test.exs test/aiur_web/build_order/planning_source_test.exs test/aiur_web/build/unfiled_scan_test.exs test/aiur_web/build/index_test.exs test/aiur_web/build/payload_test.exs`
and `mise exec -- npm --prefix src/browser run test:build-home-unfiled`.
(The C8-T04 and C3-T02 test file names are the ones those tickets create; use
the names they landed with.)

**ExUnit — `UnfiledRows` (PROPOSED `src/test/aiur_web/build/unfiled_rows_test.exs`,**
`async: false`; temp packs via `Aiur.TestSupport.tmp_root!/1`. Setup deletes
`:build_order_planning_pack`, sets `:build_order_planning_packs` and writes
`Config.repo()` as each pack's `repository`, as
`planning_source_test.exs:150-172` does; `on_exit` restores both keys. Never
the real `~/.aiur` or checkout.) Each test names the production hunk that, when
reverted, makes it fail:

| ID | Fixture → expected | Fails when |
| --- | --- | --- |
| U1 | no paths (`:build_order_planning_packs` = `[]`) → `source.state == "disabled"`, `reason == "no_pack_configured"`, `rows == []` | the `configured == 0` clause is replaced by `ok` |
| U2 | good + broken pack → `unavailable`, reason `"1 of 2 planning packs could not be read: broken.json"`, the good pack's 2 rows present | `failed` is dropped from `load_pack_results/0` (today's `:error -> []`) |
| U3 | only broken → `unavailable`, `rows == []` | the `failed != []` check is replaced by `ok` |
| U4 | `loader:` fn that raises → `unavailable`, reason `"planning packs could not be read"`, no raise | the `rescue` is removed |
| U5 | items `{A, ticket: 1234}`, `{B, ticket: nil}` → one row (`B`); `aliases == %{1234 => "pack:demo/A"}` | the `number: nil` filter is removed (A would appear) |
| U6 | complexity missing / `7` → `cx: nil, pts: nil`; complexity `4` → `cx: 4, pts: 5` | `pts` defaults to `PTS[0]` |
| U7 | phases `[2, 5, "x", 0]`, `max_wave: 4` → row order `0, 2, 5, "x"`, waves `5, 6, 7, 8`; `src.wave` `0, 2, 5, nil` | `wave = phase` (no offset), or `0` treated as unknown (it would sort last) |
| U8 | `max_wave: 0`, `max_ord: -1` → first wave `1`, `ord` `0..n-1` | offset ignores `max_wave` / `max_ord` |
| U9 | `A → B → A` cycle, `C → Z` (Z absent) → deps `["pack:demo/B"]`, `["pack:demo/A"]`, `[]`; C `deps_missing: 1`; A `children: ["pack:demo/B"]` | unknown ids kept, or `deps_missing` hard-coded to `0` |
| U10 | item id `"../x"` → skipped; reason counts it | the id regex is removed |
| U11 | two id-less packs, same item id `T-1` → two distinct ids | `pack_key` falls back to `"planning"` |
| U11b | two packs, explicit ids `<repo>:demo` and `<repo>:x:demo`, same item `T-1` → one row; the other counted in the reason | the second pack overwrites the first |
| U12 | pack for `other/repo` → no rows, not in `failed` | repository filter bypassed |
| U13 | `completed: true` pack with `ticket: null` and `ticket: 77` items → no rows, `aliases == %{}` | completed filter removed |
| U14 | `:state` discovery (`:repo_base_root` = temp dir; both overrides and `AIUR_BUILD_ORDER_DIRS` deleted, as `planning_source_test.exs:808-832`): pack at `RepoBase.builds_path(...)/x/build-order.json` → `src.path == "builds/x/build-order.json"`; no row or reason contains `System.tmp_dir!()` | `display_path` returns the absolute path |
| U15 | items with `lane: "bugs"` (in `epics`) and `lane: "nope"` → `epic` `"bugs"`, `nil` | unknown lanes pass through |
| U16 | deps on `9` (in `done_numbers`), on `10` (filed, open), on `11` (filed in the pack, not in `filed_numbers`) → `deps ["9", "10"]`, `dep_states %{"9" => "cleared", "10" => "blocking"}`, `deps_missing 1`, `waitAny true`; a row with only dep `9` → `waitAny false` | `waitAny = deps != []`, or numbers not in the index kept |
| U17 | guard, not coverage: a 650-item pack (the census size) → 650 rows; mean `byte_size(Jason.encode!(row))` ≤ 400 (C3-T02 budget) | a row cap, or a field that bloats rows |

**ExUnit — loader (added to `planning_source_test.exs`).**
- L1 `load_pack_results/0`: delete `:build_order_planning_pack`, set
  `:build_order_planning_packs` to `[matching, broken]` (matching = `@pack`
  with `Config.repo()` as repository, broken = `"{"`) → `configured: 2`, one
  pack, `failed == [%{source: :configured, path: broken}]`. Fails with today's
  `load_packs/1` behaviour (no `failed`).
- L2 guard (not counted as coverage of this change): `catalog/0` output equals
  the pre-change output for the setup pack (existing tests already cover it).

**ExUnit — assembler (in C8-T04's Index test file).**
- A1 (extends C8-T04 D4) index state 1 has `pack:demo/A`; state 2 the pack says
  `ticket: 1234` and 1234 is a queue row → the diff has
  `remove: ["pack:demo/A"]` and an upsert of `"1234"` with
  `was: "pack:demo/A"` in the same message; no snapshot ever holds both. Fails
  when the `was` marking is removed (upsert lacks `was`).
- A2 queue source `{:error, :boom}` and one pack row → `sources.queue` is
  `unavailable`, the pack row is in `plan` with `wave == 1`. Fails when pack
  rows stay inside the "planned" part (C8-T04 empties it).
- A3 (N7) Index with injected timer, pack row `pack:demo/A` present; rewrite the
  pack file to `ticket: 1234` and send only `:daemon_tick` → after the flush
  `pack:demo/A` is removed. Fails when the `packs` part is re-read only on its
  PackStatus signal.
- A4 `IndexSource.ticket/2` with `"pack:demo/A"` after A1 → the `"1234"` row;
  with `"pack:demo/NOPE"` → `{:error, :not_found}`. Fails when the `was` lookup
  is removed.
- A5 pack row with dep `"1234"` → row `"1234"` has `"pack:demo/A"` in
  `children`. Fails when the `children` append is removed.

**ExUnit — payload validator (C3-T02 file).** V1 a `pack:` row without `src` →
error at `src`; V2 a numeric row with `src` → error; V3 `src.path: "/home/x"`
and `"~/x"` → error; V4 `sources` without `packs` → error; V5 id
`pack:platform-program-2026-10/CLI-LOGIN-T01` is accepted and `pack:../x`,
`pack:demo` are rejected (fails with C3-T02's old lower-case regex, and with
`^pack:.*$`); V6 `src.wave: -1` → error. Each fails when its validator clause
is replaced by `:ok`.

**ExUnit — scan and URL.** S1 the hook scan finds no offenders and scanned ≥ 1
file; S2 positive control: the scanner flags the fixture strings
`'"#" + t.num'` and `` '`Q${t.qpos}`' ``. P1 C3-T03 `parse("ticket=pack:demo/T-1")`
keeps it, and C11-T01 `ticket_id/1` accepts it; P2 `ticket=pack:../x` and
`ticket=pack:demo` are dropped by both (fail when the new regex is
`^pack:.*$`).

**Hook unit checks (in the browser spec, page context).**
- H1 `refText({num: null, src: {kind: "pack"}})` → `"—"` and `refTitle` →
  `"Not filed yet"`; `refText({num: 57})` → `"#57"`. Fails when the unfiled
  branch is replaced by `"#" + t.num` (`"#null"`).
- H2 `srcLine` with `wave: null` → `"docs/build-plan.md · not filed yet"` (no
  `"wave null"`); with `wave: 0` → `"… · wave 0 · not filed yet"`. Fails when
  the `!= null` guard is removed or replaced by a truthiness test.
- H3 with `unfiled` data and an empty queue, the first W label text has no
  `"ready"`. Fails when the `list.some` condition is removed.
- H4 `queueText({num: 9, qpos: null})` → `"Q?"`; `{num: 9, qpos: 3}` → `"Q3"`;
  unfiled → `"Not filed"`. Fails when the `qpos == null` branch is removed
  (`"Qnull"`).

**Browser (Playwright, `unfiled` and `unfiled_unavailable` datasets).**
- B1 no element text on the page matches `/#null|Qnull|undefined|NaN/`, and no
  text inside a `[data-id^="pack:"]` node matches `/null/`, in board, list and
  tree views, after opening one pack modal. This is the unknown-path mutation
  guard: replace `queueText`'s unfiled branch with `"Q" + t.qpos` and it fails.
- B2 a pack card's `.bd-status > span:first-child` text is `"Not filed"`; in
  the list view its `.c-st .lst` has class `st-open` and text `"Not filed"`.
  Fails when the J:860 or J:1152-1153 branch is removed ("Q…" / "Queued").
- B3 the pack modal: `.bm-st` = `"Planned · not filed"`, `.bm-num` = `"—"` with
  `title="Not filed yet"`, `.bm-src` =
  `"docs/build-plan.md · wave 5 · not filed yet"`, the head docs link has
  `aria-disabled="true"` and clicking it leaves `location.href` unchanged,
  facts Queue = `"—"`.
- B4 `unfiled_unavailable`: a `.bd-mk.empty` in the planned section with `b` =
  `"Planning packs unavailable"` and `p` containing `"1 of 2"` and
  `"checked 14:20"` (frozen `NOW`). Replace the marker branch with nothing and
  it fails; set the source to `ok` and it fails.
- B5 push a diff that removes `pack:build-plan/BP-57` and upserts `"57"` with
  `was` while its modal is open → the modal shows `#57` and the URL is
  `?ticket=57`. Fails when the `modalSync` `findWas` call is removed.
- B6 `?ticket=pack:build-plan/BP-999` → S-10 not-found state.
- B7 a pack row titled `<img src=x onerror=alert(1)>` renders as text.
- B8 open a pack card → the URL `ticket` value decodes to
  `pack:build-plan/BP-57`; "Copy link" copies that URL; loading it opens the
  same pack modal. Fails when C11-T01's `writeURL({ ticket: "" })` pack branch
  is kept.

**Manual.** Not required by this ticket: no chat or TUI path changes. C12-T01's
cutover run covers the page end to end.

## Pixel parity

Design elements reproduced: `fromDoc` (J:1378), the label (J:1379), the head
docs link `.bm-ib` (J:1394, C:495-498), `.bm-src` (J:1429, C:587-588), the facts
(J:1434), and the empty marker `.bd-mk.empty` (J:499, J:719-724, C:210-212) for
the new unavailable state.

Checks, in C1-T02's side-by-side runner (1440/1024/390 px, dark and light,
default and Gruvbox palettes, `TZ=America/Los_Angeles`, frozen `NOW`):
1. **Exact match, no allowlist.** Design `?example=live` with the modal open on
   a wave-5 row, against the product `unfiled` dataset with the modal open on
   the converted row. Element screenshots of `.bm-st` and `.bm-src` and of the
   head docs `.bm-ib` (rest and hover) must be pixel-identical. The fixture's
   `src.path` is the design's literal `docs/build-plan.md`, so the text is
   byte-identical.
2. **Board, list and tree cells** for `unfiled`: whole-page compare against
   design `live`, with `pixel-mask` entries (both sides,
   `"status": "pending-sign-off"`, `ref` this ticket's Decisions 2, 3 and 16)
   for exactly these nodes of the 16 wave ≥ 5 rows: `.bd-id`,
   `.bd-status > span:first-child`, `.c-id`, `.lr-mu`, `.c-st .lst`, the tree
   node `em` and `b`, `.bm-num`, and the first `.bm-facts` value. The selectors
   are unions of the design id and the product id per row (for example
   `[data-id="AIUR-57"] .bd-id, [data-id="pack:build-plan/BP-57"] .bd-id`), so
   each side matches and no entry goes stale. Everything else in those cells
   must match exactly.
3. **No design equivalent:** the "Planning packs unavailable" marker. It reuses
   `.bd-mk.empty` unchanged (geometry `h: 96`, `+104` section height); its
   approved look is a product-only baseline (`unfiled_unavailable`) shown in the
   C12-T08 package as S-28.
4. C2-T04's computed-style snapshot must show no style change on `.bm-ib`,
   `.bm-src`, `.bd-id`, `.bd-status`, `.lst.st-open`, `.bd-mk.empty`: this
   ticket adds no CSS.

## Completion and handoff

- [ ] `load_pack_results/0` public; `load_packs/1` output unchanged;
      `planning_source_test.exs` passes untouched plus L1.
- [ ] `UnfiledRows.build/2` with U1–U16 green; each fails with its hunk reverted
      (one line per test in the PR body, with the command run in a worktree whose
      `git status --porcelain` shows only that revert). U17 is a named guard.
- [ ] Schema fields `src`, `was`, `sources.packs` and the widened id rule with
      V1–V6.
- [ ] Assembler `packs` part with A1–A5; `PackStatus.subscribe/0` added.
- [ ] `unfiled.js` and every call site at the base patched, including the list
      chip and the C9-T05 / C11-T01 inline pack branches; S1–S2 green.
- [ ] C3-T03 and C11-T01 `ticket_id/1` regex widened; C11-T01 pack `writeURL`
      and B18 updated; `IndexSource.ticket/2` alias lookup; P1–P2 green.
- [ ] `unfiled` and `unfiled_unavailable` fixtures; B1–B8 and H1–H4 green.
- [ ] Parity checks 1–4 green; allowlist entries `pending-sign-off`.
- [ ] No absolute path in any payload (U14).

**Handoff.**
- C7-T03: apply the default estimate to pack rows (`cx` set, `est: null`);
  unknown `cx` stays "—".
- C9-T11, C9-T12 (if still open), C11-T04: use `refText`/`refTitle`/`queueText`;
  the scan enforces it.
- C12-T06: include the census pack (604 unfiled rows) in the large-index
  measurement.
- C12-T07: document unfiled rows and the unavailable marker on the home page doc.
- C12-T08: include S-27, S-28 and the allowlist entries in the sign-off
  package (numbers are final in DESIGN-E8).
- DESIGN-E8: S-27 (id slot and queue slot for an unfiled row; "Q?" for a
  filed row without a queue position) and S-28 ("Planning packs
  unavailable" marker).

**Interface mismatches found (for the work-order owner).**
1. Settled 2026-10-08: C8-T04 does not include pack rows; C7-T02 wires them.
   C8-T04 names "C7-T02 pack rows" (non-goals, parts table, D4) but does not
   list C7-T02 as a predecessor, and its "planned" part would hide pack rows on
   a queue failure; this ticket depends on C8-T04 and adds a separate `packs`
   part. C8-T04's `plan` `ord = qpos` rule cannot apply to pack rows.
2. Settled 2026-10-08: `sources.packs` is in C3-T02's accepted additive fields
   table. C3-T02 `sources` enumerates `history|queue|agents|index` and treats a missing
   key as an error; `packs` is added here.
3. Settled 2026-10-08: `src` and `was` are in C3-T02's additive table.
   C3-T02 has no field for the pack path or pack wave, which J:1394 and J:1429
   need; `src` is added. The row's "moves to the real id" needs `was`.
4. Settled 2026-10-08: C7-T02 widens the C3-T02 id regex in its PR. C3-T02's
   id rule `^pack:[a-z0-9][a-z0-9-]{0,63}$` rejects real item ids
   (upper case) and the `<pack>/<item>` form; widened here.
5. Settled 2026-10-08: C7-T02 widens the C3-T03 `ticket` rule and makes the
   C11-T01 writeURL change in its PR. C3-T03's `ticket` rule (`^[0-9]{1,10}$`) and its note 2, and C11-T01's
   `writeURL({ ticket: "" })` for pack rows (its B18), keep `pack:` ids out of
   the URL; C11-T01 note 4 asks one side to change. This ticket changes them
   (decision 16) and fills C11-T01's hand-off (`ticket_id/1`, `modalSync`).
6. C7-T01's `cue` has seven keys (`unknown` included); pack rows carry all
   seven. C7-T01 §4.6 filed rows with `qpos: nil` need `queueText`'s "Q?".
7. C3-T01's seam scan forbids `AiurWeb.BuildOrder.PlanningSource` in
   `lib/aiur_web/build/**`, but the row and plan §5.1 say to call its loader;
   one allowlist entry is added (the move to `Aiur.BuildOrder` is MP-R1).
8. The row's "with its own configured pack path" is met by the existing
   discovery and overrides; no new key is added (Decision 1).
9. Row Cx 2 → 3: the payload, URL, assembler and client call-site work above is
   more than the row priced, and the real population is 604 rows, not a few.

## Decisions made without the owner

1. **No new config key.** "Its own configured pack path" uses
   `PackPaths` discovery (state node `builds/*/build-order.json`, workspace
   `.aiur/build_orders/*.json`) and the existing `:build_order_planning_pack(s)`
   overrides. Reason: ponytail reuse; a new key needs docs and a checker entry
   for no gain. "No pack configured" = discovery finds nothing.
2. **The id slot of an unfiled row shows `—` with `title="Not filed yet"`,**
   the default C9-T05 and C11-T01 already chose. A `#` means a GitHub issue.
   The item id is not printed; the source line and the title identify the
   item. S-27.
3. **The queue slot shows "Not filed"** on cards, the list chip, list and tree,
   and "—" in the modal facts (the design's own no-queue rendering, J:1434).
   Never `Q` + a made-up position. S-27.
4. **Board waves are offset after the filed waves** (`max_wave + rank`); the
   modal source line shows the pack's own phase. This keeps W groups from
   mixing pack and queue items, as the design's W5/W6 do.
5. **The head docs link stays inert,** as in the design (`href="#"`,
   `data-a="none"`), with `aria-disabled` and an `aria-label`. There is no served
   URL for a local pack document.
6. **A partly broken pack set is `unavailable`, not `ok`,** with the good packs'
   rows still shown and the marker naming the count. Hiding a broken pack is
   the bug this replaces.
7. **Completed packs contribute no rows and no aliases,** even with unfiled
   items. An old `pack:` link to a completed pack shows S-10.
8. **`type` is always `"feature"`.** Packs carry no type; the type only picks an
   icon. `cx`/`pts`/`est` unknowns stay `null`.
9. **No title matching to hide the brief duplicate** between issue creation and
   the pack write (N7). Two items can share a title; a wrong merge hides work.
10. **`load_pack_results/0` on `PlanningSource` plus a seam allowlist entry,**
    not a move of the loader into `Aiur.BuildOrder`. MP-R1 moves it.
11. **Added `blocked_by` C8-T04 and C11-T02** beyond the row, so the client call
    sites and the assembler exist when this ticket lands.
12. **The `unfiled` fixture is a new dataset;** the other five keep C3-T02's
    mapping, so their parity is not touched.
13. **`epic` comes from the item `lane`** (the pack README calls it "epic /
    workstream"), not from new item keys that no real pack writes.
14. **Phase `0` is a real wave,** ranked first. A missing phase is also `0`, as
    the Build Order page already reads it; only a non-integer or negative phase
    is "unknown".
15. **Pack rows are their own Index part, read on every flush.** This keeps them
    visible on a queue failure and bounds the N7 duplicate to the next flush
    (at most about 15 s, the daemon tick) without a file watcher.
16. **`pack:` ids go in the URL** (C3-T03 and C11-T01 changed), so "Copy link"
    works and an old link follows `was` to the filed ticket.
17. **A filed plan row without a queue position shows "Q?"**, C11-T01's head
    wording and C9-T05's unknown marker.
18. **The list chip for an unfiled row is `st-open` "Not filed",** reusing the
    design's not-queued chip style (C:736), as C9-T12 note 5 asks.

## Review log

Adversarial review, 2026-10-08, against `58854d4c8`, the design source and the
neighbour ticket files.

1. `ticket_number/1` has three clauses (`github.number` too); the "missing key"
   claim was wrong. Added the `configured_repository/0` rescue fact.
2. N4's example (`Config.repo` raising) cannot happen (`:926-930` rescues it);
   replaced with a non-string pack-path entry.
3. C8-T04 coalesces for 250 ms, not 500 ms. C8-T04 already names C7-T02 pack
   rows; mismatch 1 reworded. Its "planned" part empties on a queue failure,
   which contradicted N13: pack rows are now a separate `packs` part.
4. PackStatus broadcasts only when `status.json` changes, at the 15-minute sweep;
   a pack write fires no signal. N7 was unbounded; the `packs` part is now read
   on every flush (bounded by the 15 s daemon tick), with test A3.
5. C3-T02's id regex (`^pack:[a-z0-9][a-z0-9-]{0,63}$`) rejected the ticket's
   own ids; widened in step 3 with V5. Added V6.
6. Rows lacked C7-T01's seventh cue key (`unknown`) and C4-T04/T05/C8-T04 keys
   (`start_src`, `children`, `dep_states`, `deps_missing`, `pct: 0`); the
   closed key set would reject them. Added, with the filed-row `children`
   append (A5).
7. `waitAny: deps != []` marked rows blocked by merged prerequisites, and deps
   on numbers outside the index were kept (C3-T02 says drop). Fixed with
   `done_numbers`; test U16.
8. Census of the 9 real discovered packs: one has 604 unfiled items and 43 items
   in phase `0`. Phase `0` was sent to the last group; it is now a real wave
   (U7 changed). "Largest pack 35 KB" was wrong (284 KB). Added N21 and U17.
9. `epic`/`feature`/`type` item keys match zero real packs; dropped the
   `ticket/3` change and use `lane` as the epic input (U15 changed).
10. The id slot conflicted with C9-T05 and C11-T01 (both render `—` +
    "Not filed yet"); aligned to that, removed `src.ref`, rewrote H1.
11. `queueText` printed `Qnull` for C7-T01 §4.6 filed rows; now "Q?" (H4).
12. Missing call site: the list chip `stText`/`stClass` (J:1152-1153, C9-T12
    note 5); added with B2 and a `.c-st .lst` mask.
13. URL widening conflicted with C11-T01 (`writeURL({ticket: ""})`, B18) and
    C3-T03 note 2; made the C11-T01 edits, `ticket_id/1` and the
    `IndexSource.ticket/2` alias lookup explicit (A4, B8).
14. Allowlist status is `pending-sign-off`; `pending-signoff` is rejected by
    C1-T02's loader.
15. S-18 is already proposed by C11-T08, C11-T04 and C10-T03; renamed to
    S-new-A / S-new-B for C12-T08 to number.
16. L1 and the U tests would have read the setup's explicit pack (it wins over
    the configured list and skips the repository filter); U14 could not reach
    `:state` discovery. Cited the `:150-172` and `:808-832` test precedents.
17. B1 missed `≈nullh`-style text; the scan missed template literals. Both
    widened.
- Reconciliation 2026-10-08 (coordinator): S-new-A/S-new-B -> S-27/S-28 (numbers final in DESIGN-E8), allowlist kinds per R-G6 and `pending-signoff` mention removed, interface mismatches 1-5 marked settled.
