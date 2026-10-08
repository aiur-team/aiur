# Scale findings: one Build Order for the whole platform program

Date: 2026-10-07/08. Runtime daemon: `aiur-everdred-f79e54e461@127.0.0.1`
(PID 476817, worktree `aiur-worktrees/runtime` at `58854d4c8`). Pack:
`aiur-team/aiur:platform-program-2026-10`, 647 members at the last generation (the U-units, U8
and MP-E8 trees were still being written during this run; MP-E8 had no ticket
files yet).

Every number below was measured in this run unless it says "extrapolated".

## 1. The live dashboard cannot show draft members (blocking)

- The running daemon uses `AiurWeb.BuildOrder.DataSource`, which reads the
  GitHub graph (`Aiur.BuildOrder.GraphProjection`). RPC check:
  `Application.get_env(:aiur, :build_order_data_source)` returns `nil`.
- The reader for state-node packs with draft members is
  `AiurWeb.BuildOrder.PlanningSource`. It is used only when the release is
  **built** with `AIUR_BUILD_ORDER_DEMO=1` (`src/config/config.exs`). It is a
  compile-time setting, so a restart alone does not turn it on.
- `PackPaths.discovered/0` on the live node does list
  `builds/platform-program-2026-10/build-order.json`. The pack is discovered
  (the status poller can use it), but the page does not render it.
- Result: `/build-orders/3042` shows **41 members**, the MP-E1 issues the
  Executor promoted under root #3042, not the 647 pack members. The catalog row
  takes its title from the GitHub root issue ("BO: Platform program 2026-10 —
  MP-E1 build queue (wave 0)"), not from the pack `title`.
- The aiur-build skill and planning contract say "with the daemon running,
  open the Build Order page and confirm the pack title and members render".
  For a non-demo build that verification rung cannot pass for a draft pack.

Screenshots: `~/.aiur/review-scratch/bo/catalog.png`,
`~/.aiur/review-scratch/bo/selected-3042.png`.

## 2. The demo reader crashes on this pack, and would merge 600 members

`PlanningSource.synthetic_ticket_number/1` takes the **last digit group** of a
draft id as its issue number (`CT-101` → 101).

- Pack ids end in `-T01`, `-T02`, and so on. 604 drafts map to **16 distinct
  numbers**. **600** drafts share a number with another draft. 177 drafts all
  map to `1`.
- **6** ids end in `-T00` (spikes and measurements, for example
  `MP-E2-C4-T00`). They map to `0`, and `TrackerIdentity.from_github/3`
  rejects that. Calling `PlanningSource.catalog()` over RPC on the live node
  raised `MatchError {:error, :invalid_display_identifier}` at
  `planning_source.ex:286` (`identity!/3`). One bad pack takes down the whole
  planning catalog, including the other packs.
- Fix needed in Aiur (not done here; the pack must not invent issue numbers):
  hash the full id, or give drafts a non-numeric identity.

## 3. GitHub-side limits for a 647-member root

- `github_graph/settings.ex`: `@member_limit 100`. The tracker schema caps
  `planning_page_budget` at 4 (the default is also 4). The selected root
  therefore reads at most **4 pages of up to 100 = 400 members**. 647 members
  under one root would be truncated.
- `queries.ex`: the catalog reads `subIssues(first: 100)`, so a root with more
  than 100 members shows unresolved counts in the catalog.
- GitHub limits a parent issue to 100 sub-issues. A flat root with 647
  sub-issues cannot be built. Use the 20 epics as intermediate parents: the
  largest epic has 74 members, so each fits.
- `blockedBy(first: 100)` and `blocking(first: 100)` are read per member.
  After transitive reduction the largest fan-out is **93** (`U0-T01` blocks
  every MP-R and U1..U7 root) and the largest fan-in is **63**
  (`U8-P00-T02`, the U8 ledger close-out). Both are under 100, but close to it.
  Without the reduction `U0-T01` would block **169** members.
- Recommendation: promote under per-epic parents, or split the program into
  several Build Orders (for example refactor, platform, mobile) of under 400
  members each.

## 4. CLI and RPC

- `aiurdev build-orders <id>` with a `build_order_id` returns "could not find
  Build Order". Only the root number works (`build-orders 3042`).
- The first two `build-orders 3042` calls timed out after 10 s ("outcome is
  unknown"). The third returned `planning_graph: loading`. The graph became
  `available` about 53 s after the first request. No refresh RPC was needed.
- The node name given in the task (`aiur-everdred-a5aba22aad`) was wrong. The
  live node is `aiur-everdred-f79e54e461`. Read it from
  `/proc/<pid>/cmdline` (`-name`). Helper: `~/.aiur/review-scratch/bo/rpc.sh`.

## 5. Page load at the current size (41 members)

Headless Chromium 1243, 1600x1000, basic auth, `waitUntil: load`:

| Page | HTTP | load | network idle | DOM elements | SVG nodes | HTML | page height |
|---|---|---|---|---|---|---|---|
| `/build-orders` | 200 | 1.20 s | 1.76 s | 289 | 58 | 36 KB | 1000 px |
| `/build-orders/3042` | 200 | 0.39 s | 0.97 s | 1,656 | 365 | 312 KB | 3,489 px |

No console errors. Extrapolated linearly to 647 members: about 25,000 DOM
elements, about 4.8 MB of HTML in one LiveView render, and about 50,000 px of
page height. This is an extrapolation, not a measurement.

The selected page shows "Phase label is invalid." and one lane "TBD" (72
tickets, including 31 ad-hoc) for the promoted members. The pack phases
(0..6) are not used by the GitHub path. Phase there comes from issue labels.

## 6. Pack and schema

- Two schemas disagree. The skill validator
  (`aiur-build/scripts/validate_build_order.py`) wants the planning-baseline
  shape: `decisions`, `requirements`, `label_projection`, a 40-character SHA,
  and no `title`/`icon`. The runtime reader needs `title`, `icon`, `ticket` and
  `doc`. One file cannot satisfy both. The generator writes the runtime shape.
- The runtime reader ignores `workstreams`, `external_gates` and `phases`. Lane
  ids are shown raw, so the generator uses readable lane ids such as
  `command-delivery`.
- 71 external gates: 21 design, 34 owner, 12 research, 2 prior-unit (U6, U7), 1
  external issue, 1 unparsed (`AIUR-STYLE-DONE`). Gates are not graph nodes, so
  the page cannot show that every implementation ticket waits on its DESIGN
  gate.
- 547 of 647 members have no `complexity` field. The generator estimates
  complexity from document size (≤4 KB → 1 … >14 KB → 5) and marks those
  members with `complexity_estimated: true`. U0/U8 tickets carry a real value.
- `PlanningSource.draft_body/2` drops documents over 64,000 bytes. The largest
  document is 17 KB, so none is dropped.
- 38 relative links in 26 copied ticket documents (`](../…`) point into the
  research pack and do not resolve from `tickets/`.
- Generator: 0.35 s for 647 members; `build-order.json` 284 KB; `tickets/`
  5.0 MB. Declared edges 1,840 → 1,266 after transitive reduction.

## Decisions made without the owner

1. Epics = 20 `workstreams` (lanes), mapped by chunk with ticket-level
   exceptions. See `epics.md`.
2. Phases 0..6 map waves 0, 0b, 1, 2, 3, 4, 5. No wave-barrier edges.
   Ticket-level wave moves from graph-check (RC-29, RC-31, E1-C3-T08) are kept.
3. `U0-T01` is a hard prerequisite of every MP-R1..R7 and U1..U7 ticket, as
   `U0-T01.md` states. MP-E1 and MP-E8 are not gated (RC-19).
4. `prior_units` front matter is provenance, not a dependency. Only
   `blocked_by` entries create edges. A bare unit reference (`U5`) becomes an
   edge to that unit's final tickets once the unit exists, and an external gate
   until then.
5. Chunk-level and unit-level references resolve to the group's final tickets;
   the whole graph is then transitively reduced. Readiness is unchanged.
6. One acceptance member per MP feature, one for all U-units together and one
   for U8 (23 in total). Each depends on its feature's final tickets. The three
   small members (#3032, #3033, login --share-history) have no separate
   acceptance member.
7. #3032 goes to `command-delivery` and #3033 to `listener`, by content. The
   login draft is the only member of `operator-cli`.
8. The #3032 issue body now holds only the agent workpad, so `GH-3032.md` is
   written from the title and the workpad.
9. Complexity is estimated from document size where the ticket has none.
10. Member ids keep their pack ids. `ticket_prefix` is `MP`.
