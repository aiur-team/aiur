# Graph parallelism and phasing review

Independent review of the 53-ticket dependency graph (19 BO from
`build-order.json` + 34 DASH from the provisional `companion-tickets/*.md`
headers, which supersede the stale 25-ticket `dashboard-companions.json`).
Computed by longest-path wave scheduling under infinite capacity; hard
`depends_on` edges only, with declared `serializes_with` pairs evaluated
separately as soft parallelism loss.

## Graph health

- 53 tickets, **no cycles, no dangling dependency references** (every
  `depends_on` target resolves to an existing BO/DASH ticket).
- Critical path depth: **10 waves**.
- Total declared serialization pairs: 102 (deduplicated, symmetric); **33 land
  in the same wave**, i.e. genuinely reduce parallelism rather than merely
  documenting ordering that dependencies already impose.

## Wave profile

| Wave | Width | Points | Tickets |
|---:|---:|---:|---|
| 1 | 5 | 16 | BO-004, BO-008, DASH-006, DASH-017, DASH-018 |
| 2 | 7 | 25 | BO-001, BO-016, BO-017, DASH-001, DASH-004, DASH-012, DASH-019 |
| 3 | 10 | 35 | BO-002, BO-005, BO-009, DASH-002, DASH-007, DASH-008, DASH-013, DASH-020, DASH-021, DASH-026 |
| 4 | 9 | 30 | BO-003, BO-006, BO-010, BO-019, DASH-009, DASH-010, DASH-011, DASH-016, DASH-029 |
| 5 | 4 | 15 | BO-007, BO-018, DASH-014, DASH-024 |
| 6 | 5 | 17 | BO-011, DASH-003, DASH-025, DASH-030, DASH-032 |
| 7 | 8 | 25 | BO-012, DASH-005, DASH-015, DASH-022, DASH-027, DASH-028, DASH-031, DASH-034 |
| 8 | 3 | 11 | BO-013, DASH-023, DASH-033 |
| 9 | 1 | 4 | BO-014 |
| 10 | 1 | 4 | BO-015 |

Waves 1–4 are healthy (fleet stays saturated). The tail narrows as expected
for hardening/capstone work.

## Finding 1 (high): the BO critical path is fully serial

`BO-004 → BO-001 → BO-002 → BO-003 → BO-007 → BO-011 → BO-012 → BO-013 →
BO-014 → BO-015` is a 10-ticket single-file chain. The Build Order page has
essentially no internal parallelism on its own critical path; it is the
wall-clock floor for the whole program.

**Recommendation:** decouple BO-012 (ship minimum graph) from BO-011 (ticket
context adapter). Ship the graph with a named-but-stubbed context action
(same seam DASH-003 already uses for DASH-027), and let BO-011 integrate
afterwards as an already-parallel follow-up. This removes one wave from the
serial backbone at the cost of an explicitly temporary "context unavailable"
state behind a named action — consistent with how the pack already treats
DASH-027's seam in DASH-003.

## Finding 2 (high): wave 7 is false parallelism — a DashboardLive clique

Seven of wave 7's eight tickets (DASH-005, 015, 022, 027, 028, 031, 034)
pairwise serialize on shared `DashboardLive` composition — 21 of the 33
same-wave serialization pairs sit inside this one wave. On paper the wave is
8 wide; in practice those seven land one at a time, each rebase staling the
next (the same shared-file cascade the OCC wave hit on `decision_store.ex`).

**Recommendation:** dissolve the clique structurally instead of sequencing
it. Make each page its own LiveView module (for example `UnitsLive`,
`CommandsLive`, `BuildOrderLive`) mounted by the DASH-001 route shell,
rather than composing every region into one `DashboardLive`. Give DASH-001
explicit ownership of that split so later UI tickets write disjoint files.
The serialization pairs then collapse to the small set that genuinely shares
a region (e.g. DASH-031/DASH-034 if both write the same summary surface).

## Finding 3 (medium): DASH-003 couples the companion pack to the BO track

DASH-003 (Units interface) has the highest fan-out in the graph — **8 direct
dependents** — yet sits in wave 6 because it hard-depends on BO-018 (base
ticket context), which itself waits on BO-008/BO-016/BO-019. The companion
pack's most load-bearing ticket is gated on Build Order backend progress.

**Recommendation:** downgrade the BO-018 edge to a contract dependency:
DASH-003 consumes BO-018's *interface* (component name, assigns, navigation
capabilities — publishable as soon as BO-018's contract review lands) while
keeping the existing running-agent log modal as the documented temporary
path (the ticket already specifies exactly this compatibility behavior).
BO-018's proven implementation then swaps in without reopening DASH-003.
If the two-incompatible-modal-contracts risk is judged to outweigh the
schedule gain, at minimum note the coupling explicitly in
`dashboard-companions.md` so the Executor staffs BO-016/018/019 first.

## Finding 4 (low): top fan-out nodes deserve first-slot staffing

Fan-out ranking: DASH-003 (8), BO-008 (6), BO-004 (5), BO-017 (5), BO-005
(4), DASH-001 (4), DASH-008 (4), BO-001 (3). The Executor should treat these
as the always-staffed spine; a stall on any of them starves more of the
fleet than any other ticket.

## Method note

Waves here are longest-path levels, not the pack's `phase_hint` values;
phase remains a display/rollout hint per DEC-010. Serialization pairs were
read from ticket headers and deduplicated symmetrically; asymmetric
declarations exist and are flagged in the coherence review.
