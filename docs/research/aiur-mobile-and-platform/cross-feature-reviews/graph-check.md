# Dependency graph integrity check

Generated on 2026-10-06 by `depgraph.py` (kept in the Phase D scratchpad; run with `python3 -I`) from the YAML frontmatter of every `bucket-*/MP-*/tickets/MP-*.md` file. Pack base: `45a290e3`. The machine-readable graph is [../dependency-graph.json](../dependency-graph.json); the delivery sequence is [../dependency-map.md](../dependency-map.md).

Phase D applied decisions RC-28 to RC-35 ([phase-b-reconciliation.md](phase-b-reconciliation.md)) and the fixes below, then re-ran the script. Re-run it after any ticket edit.

## Phase D fixes

| Check | Before | After |
|---|---|---|
| Dangling references | 7 | 0 |
| Cycles | 1 | 0 |
| Tickets missing their own DESIGN gate | 7 | 0 |
| Wave inversions | 9 | 0 |
| Non-canonical ticket IDs | 62 | 0 |
| Chunk- or feature-level references | 57 | 11 |
| Frontmatter wave conflicts | 1 | 0 |
| Longest chain (tickets) | 28 | 27 |

- **RC-34.** MP-R1 ticket files renamed `T<n>` to `T0<n>` (64 files; C9-T10 to T14 already had two digits); every ticket ID in the pack padded to two digits; `blocked_by` entries without the `MP-` prefix given it. 220 files rewritten by one script; a grep finds no single-digit `C<n>-T<n>` ID left.
- **Dangling.** MP-N2-C10-T01: `MP-R3-C1-T02` -> MP-R3-C1-T01 (bind-guard tests; R3-C1 has one ticket). MP-N2-C2-T01: `MP-R1-C2-T03` -> MP-R1-C3-T02 (the `repository` section provider). MP-N3-C1-T04: `MP-R1-C2-T04` -> MP-R1-C3-T02 (the `executor` state projection). MP-N4-C5-T02: `MP-N1-C6-T02` -> MP-N1-C6-T01 (candidate T02 folded into MP-N4-C5; T01 keeps the FCM build plumbing). MP-N6-C2-T02: `MP-N1-C6-T03` -> MP-N1-C6-T01 (candidate T03 retired in favour of N6-C2-T02, MP-N1 CONTRACT-REQUESTS B5). MP-N4-C4-T05 and C5-T05 (retired candidate `N1-C6-T04`) had been fixed to MP-N1-C6-T01 before this pass; their prose now says so too.
- **RC-28.** MP-E5-C3-T02 no longer lists MP-E6-C7-T02; E6-C7-T02 keeps its edge to E5-C3-T02. Cycle gone.
- **RC-29.** MP-E5-C8-T01/T02 carry `wave: 5`; E5 README, plan and chunks say wave 5, after MP-N2-C6.
- **RC-30.** MP-E6-C7-T01 no longer lists MP-E5-C8-T01; the `/voice/device` route and its test come with E5-C8 (E5-C8-T01 already serves `voice:converse` once E6-C7-T01 lands).
- **RC-31.** MP-R2-C5 is placed at the start of wave 4; R2-C6/C7 stay in wave 5 (R2 tickets README, value-and-sequencing.md).
- **RC-32.** MP-E2-C4-T00, MP-E2-C5-T00, MP-E3-C3-T01, MP-E4-C1-T00 carry `design_gate: "n/a — research spike"`.
- **RC-33.** MP-N6-C4-T02, T03, T04 list DESIGN-N6.
- **RC-35.** MP-E2-C1-T01, C2-T05, C3-T01 list MP-R1-C11-T03.

## Summary

| Check | Count |
|---|---|
| Ticket files | 525 |
| Ticket-to-ticket edges (after expanding chunk and feature references) | 1328 |
| Edges from gates, research, owner, prior-unit and external items | 737 |
| Dangling references | 0 |
| Cycles | 0 |
| Tickets missing their own feature's DESIGN gate | 0 |
| Wave inversions | 0 |
| Non-canonical ticket IDs (resolved, but the spelling differs) | 0 |
| Chunk- or feature-level references (expanded to every ticket) | 11 |
| Frontmatter `wave` that disagrees with the sequencing | 0 |
| Status `ready` with an open ticket predecessor | 104 |
| Status `blocked` with only DESIGN gates | 21 |
| Longest chain overall (tickets) | 27 |

## Counts per feature

| Feature | Wave | Tickets | Ready | Blocked | Longest chain inside the feature |
|---|---|---|---|---|---|
| MP-E1 | 0/1 | 41 | 0 | 41 | 11 |
| MP-E2 | 2 | 36 | 2 | 34 | 8 |
| MP-E3 | 3 | 20 | 1 | 19 | 7 |
| MP-E4 | 3 | 20 | 1 | 19 | 8 |
| MP-E5 | 4/5 | 19 | 8 | 11 | 5 |
| MP-E6 | 4 | 31 | 14 | 17 | 11 |
| MP-E7 | 3/4 | 33 | 13 | 20 | 9 |
| MP-N1 | 5 | 31 | 0 | 31 | 11 |
| MP-N2 | 5 | 39 | 0 | 39 | 15 |
| MP-N3 | 5 | 16 | 0 | 16 | 6 |
| MP-N4 | 5 | 34 | 23 | 11 | 10 |
| MP-N5 | 5 | 17 | 12 | 5 | 5 |
| MP-N6 | 5 | 20 | 7 | 13 | 7 |
| MP-N7 | 5 | 25 | 0 | 25 | 12 |
| MP-R1 | 1 | 69 | 0 | 69 | 11 |
| MP-R2 | 1 | 38 | 26 | 12 | 11 |
| MP-R3 | 1 | 2 | 0 | 2 | 1 |
| MP-R4 | 1 | 1 | 0 | 1 | 1 |
| MP-R5 | 1 | 9 | 0 | 9 | 4 |
| MP-R6 | 1 | 3 | 0 | 3 | 3 |
| MP-R7 | 1 | 21 | 14 | 7 | 9 |
| **Total** | | **525** | **121** | **404** | |

Waves come from [../value-and-sequencing.md](../value-and-sequencing.md); MP-E7 is split by RC-05 (C1-C3 wave 3, C4-C7 wave 4); MP-E5-C8 is wave 5 (RC-29). A frontmatter `wave` value wins where present. The table shows the nominal wave; MP-R2-C5 is scheduled in wave 4 and MP-R2-C6/C7 in wave 5 (RC-09, RC-31).

## 1. Dangling references

A `blocked_by` entry that names a ticket ID with no ticket file.

| Ticket | Reference | Note |
|---|---|---|
| none | | |

## 2. Cycles

None. The MP-E5-C3-T02 / MP-E6-C7-T02 cycle was removed by RC-28.

## 3. Tickets missing their feature's DESIGN gate (MP-REQ2)

| Ticket | Gates cited | Note |
|---|---|---|
| none | | |

Research spikes with `design_gate: n/a — research spike` (RC-32, counted as compliant): MP-E2-C4-T00, MP-E2-C5-T00, MP-E3-C3-T01, MP-E4-C1-T00.

Gates marked waived in the reference text (counted as present): MP-E5-C1-T01, MP-E5-C1-T02, MP-E5-C1-T03, MP-E5-C2-T01, MP-E5-C2-T02, MP-E5-C2-T03, MP-E5-C8-T01, MP-E5-C8-T02, MP-E6-C2-T01, MP-E6-C2-T02, MP-E6-C2-T03, MP-E6-C2-T04, MP-E6-C3-T03, MP-E6-C4-T01, MP-E6-C4-T02, MP-E6-C4-T03, MP-E6-C4-T05, MP-E6-C4-T06, MP-E6-C5-T01, MP-E6-C5-T02, MP-E6-C5-T05, MP-E6-C6-T01, MP-E6-C6-T02, MP-E6-C6-T03.

## 4. Wave inversions

A ticket in an earlier wave blocked by a ticket in a later wave. MP-R2-C5 is placed at the start of wave 4 (RC-31); MP-R2-C6 and C7 in wave 5, just before MP-N4/N5 (RC-09).

| Ticket (wave) | Blocked by (wave) | Note |
|---|---|---|
| none | | |

Resolved in Phase D:

| Inversion (before) | Decision |
|---|---|
| MP-E5-C8-T01 (4) <- MP-N2-C1-T03, MP-N2-C6-T01 (5) | RC-29: E5-C8 moves to wave 5. |
| MP-E5-C8-T02 (4) <- MP-N2-C7-T01 (5) | RC-29: E5-C8 moves to wave 5. |
| MP-E6-C4-T05 (4) <- MP-R2-C5-T01..T04 (5) | RC-31: R2-C5 moves to the start of wave 4. The edge is now C5-T01 and C5-T03 only. |
| MP-E7-C2-T05 (3 by chunk, 4 by frontmatter) <- MP-R2-C5-T01, T03 (5) | RC-31 plus the ticket's own `wave: 4`: R2-C5 and E7-C2-T05 are both wave 4. The frontmatter conflict is closed by recording E7-C2-T05 as wave 4; no wave-3 ticket depends on it. |
| MP-E1-C3-T08 (0) <- MP-R1-C3-T01 (1) (new ticket from X-21, final pass) | Rule applied: the provider needs the MP-R1-C3-T01 capability registry, so the ticket carries `wave: 1` in its frontmatter; no wave-0 ticket depends on it (dependents MP-N3 queue tile and MP-N5 queue progress are wave 5, soft). |
| MP-E5-C7-T01 (4) <- MP-E5-C8-T02 (5) (new after RC-29) | Rule applied: E5-C8-T02 also waits on MP-N2-C7-T01 (wave 5), so it cannot move earlier. The dependent E5-C7-T01 (end-to-end check and docs audit) moves to wave 5 (`wave: 5` in its frontmatter). |

Explained by RC-09, not an inversion: MP-R2-C7-T05 depends on MP-N2-C6-T01 and MP-N2-C7-T01; both sit in wave 5.

Frontmatter wave conflicts: none.

## 5. Non-canonical ticket IDs

The reference resolves, but with different zero-padding or no `MP-` prefix. RC-34 normalized every ID to `MP-<feature>-C<n>-T<nn>`.

None.

## 6. Chunk- and feature-level references

These name a chunk or a feature, not a ticket. The script expands them to every ticket in it. Phase D replaced 32 of them with the specific tickets the dependent needs (read from each ticket body), 12 had already been narrowed before this pass, and removed two that the ticket itself calls optional (MP-N4-C3-T00 -> MP-R2-C6, 'landed or explicitly deferred'; MP-R2-C6-T01 -> MP-R1-C4, 'if landed first, follow it'). The ones below are kept on purpose: the whole chunk is required.

- MP-R1-C10-T05: `MP-R1-C9 (all tickets merged, migration step S16)` (chunk -> 14 tickets) — every C9 ticket must be merged (migration step S16) before the directory page goes live and before the final plan refresh
- MP-R1-C11-T03: `MP-R1-C9 (all tickets merged, migration step S16)` (chunk -> 14 tickets) — every C9 ticket must be merged (migration step S16) before the directory page goes live and before the final plan refresh
- MP-R1-C7-T01: `MP-E1-C1` (chunk -> 7 tickets) — the ticket rebases over all E1-C1 hooks (labels, ingestion, state writer, Hints, ClaimProbe) and must leave every one unchanged (RC-19/RC-20)
- MP-R1-C7-T08: `MP-E1-C1` (chunk -> 7 tickets) — the ticket rebases over all E1-C1 hooks (labels, ingestion, state writer, Hints, ClaimProbe) and must leave every one unchanged (RC-19/RC-20)
- MP-R1-C8-T09: `MP-E1 C1–C7 merged (ticket IDs per MP-E1 README; incl. MP-E1-C1-T05 Hints hook, MP-E1-C1-T06 ClaimProbe, MP-E1-C1-T07 seam test)` (chunk range -> 35 tickets) — MP-E1 must have shipped (C1 to C7) before the build queue becomes a checked component
- MP-R1-C9-T01: `MP-E1-C1` (chunk -> 7 tickets) — the ticket rebases over all E1-C1 hooks (labels, ingestion, state writer, Hints, ClaimProbe) and must leave every one unchanged (RC-19/RC-20)
- MP-R1-C9-T02: `MP-E1-C1` (chunk -> 7 tickets) — the ticket rebases over all E1-C1 hooks (labels, ingestion, state writer, Hints, ClaimProbe) and must leave every one unchanged (RC-19/RC-20)
- MP-R1-C9-T03: `MP-E1-C1` (chunk -> 7 tickets) — the ticket rebases over all E1-C1 hooks (labels, ingestion, state writer, Hints, ClaimProbe) and must leave every one unchanged (RC-19/RC-20)
- MP-R1-C9-T04: `MP-E1-C1` (chunk -> 7 tickets) — the ticket rebases over all E1-C1 hooks (labels, ingestion, state writer, Hints, ClaimProbe) and must leave every one unchanged (RC-19/RC-20)
- MP-R1-C9-T08: `MP-E1-C1` (chunk -> 7 tickets) — the ticket rebases over all E1-C1 hooks (labels, ingestion, state writer, Hints, ClaimProbe) and must leave every one unchanged (RC-19/RC-20)
- MP-R1-C9-T09: `MP-E1-C1` (chunk -> 7 tickets) — the ticket rebases over all E1-C1 hooks (labels, ingestion, state writer, Hints, ClaimProbe) and must leave every one unchanged (RC-19/RC-20)

## 7. Status field semantics

`status` is not used one way across features. 104 tickets say `ready` but have an open ticket predecessor; 21 say `blocked` with nothing but DESIGN gates in front of them. Read `ready` as 'specification complete', not 'startable'.

- `ready` with ticket predecessors, per feature: MP-E5 8, MP-E6 13, MP-E7 13, MP-N4 22, MP-N5 12, MP-N6 7, MP-R2 18, MP-R7 11
- `blocked` with only gates: MP-E1-C1-T01, MP-E1-C1-T03, MP-E1-C1-T04, MP-E1-C1-T05, MP-E1-C1-T06, MP-E1-C2-T01, MP-E1-C3-T01, MP-E1-C7-T01, MP-E7-C4-T01, MP-N2-C2-T03, MP-N2-C3-T01, MP-R1-C1-T01, MP-R1-C2-T01, MP-R2-C6-T01, MP-R3-C1-T01, MP-R3-C2-T01, MP-R5-C1-T01, MP-R5-C4-T01, MP-R5-C4-T02, MP-R6-C1-T01, MP-R7-C5-T02

## 8. Non-ticket blockers

| Kind | Item (tickets it blocks) |
|---|---|
| DESIGN | DESIGN-E1 (41), DESIGN-E2 (46), DESIGN-E3 (24), DESIGN-E4 (22), DESIGN-E5 (29), DESIGN-E6 (36), DESIGN-E7 (35), DESIGN-N1 (42), DESIGN-N2 (47), DESIGN-N3 (21), DESIGN-N4 (43), DESIGN-N5 (17), DESIGN-N6 (27), DESIGN-N7 (32), DESIGN-R1 (72), DESIGN-R2 (38), DESIGN-R3 (2), DESIGN-R4 (1), DESIGN-R5 (9), DESIGN-R6 (5), DESIGN-R7 (22) |
| RQ | N1-RQ3 (1), RQ-E3-5 (1), RQ-N4-2 (1), RQ-N4-5 (1), RQ-N4-7 (1), RQ-N4-8 (1), RQ-N4-9 (1), RQ-N7-6 (2), RQ-R7-5 (1), RQ-TRANSPORT (31), RQ-U2-TRANSITION (2), RQ-U6-STATUS-MODEL (1) |
| OWNER | D-N1-7 (2), E5-OQ1 (1), E5-OQ2 (1), E5-OQ3 (2), E5-OQ4 (1), E5-OQ5 (1), E5-OQ6 (1), E6-OQ1 (2), E6-OQ2 (1), E6-OQ3 (1), E6-OQ4 (1), E6-OQ5 (1), E6-OQ6 (1), E6-OQ7 (3), E6-OQ8 (1), E6-OQ9 (2), E7-D1 (5), E7-D5 (1), MP-E1 owner review (1), MP-E7 contract request (2), OQ-E3-6 (1), OQ-N1-1 (6), OQ-N1-4 (7), OQ-N4-1 (7), OQ-N4-3 (2), OQ-N7-2 (1), OQ-N7-3 (1), OQ-N7-4 (2), OWNER-AUTH-N1-PROTO (1), OWNER-NPM-FIRST-PUBLISH (1), owner authorization (1) |
| PRIOR | U2 (4), U3 (2), U5 (7), U6 (3), U8 (4) |
| EXTERNAL | #3009 (1) |

## 9. Longest chain

27 tickets: MP-R1-C2-T01 -> MP-R1-C2-T02 -> MP-R1-C3-T01 -> MP-R1-C3-T02 -> MP-N2-C2-T01 -> MP-N2-C2-T02 -> MP-N2-C2-T04 -> MP-N2-C3-T03 -> MP-N2-C10-T02 -> MP-N2-C5-T01 -> MP-N2-C5-T02 -> MP-N2-C5-T03 -> MP-N2-C6-T01 -> MP-N6-C1-T00 -> MP-N6-C1-T01 -> MP-N6-C1-T03 -> MP-N7-C1-T03 -> MP-N7-C1-T05 -> MP-N7-C3-T02 -> MP-N7-C3-T03 -> MP-N7-C3-T05 -> MP-N7-C4-T01 -> MP-N7-C4-T03 -> MP-N7-C4-T04 -> MP-N7-C4-T05 -> MP-N7-C6-T01 -> MP-N7-C2-T06.

Every edge in it names a ticket; no chunk- or feature-level reference is involved.
