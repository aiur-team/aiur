# Synthesis status — 2026-09-29

The frozen-source research has a corrected 60-claim, two-lens audit, all 32
planned review units, a lossless 986-finding synthesis of 1,033 raw source IDs,
and a 216-feature inventory. The two independent skeptic lenses covered all
182 inherited P0/P1 source findings. See `claim-question-audit.md`,
`../review/code-review.md`, `../features/feature-inventory.md`, and
`final-research-audit.md` for the evidence and its limits.

The source-anchor audit checked all 986 canonical findings against pinned
`main` (`3339b887`). It corrected 30 of 32 defective location references;
two remain freeform or negative claims without a direct positive source anchor.
This proves static citation integrity, not live failure incidence. All 889
provisional P2/P3 findings now have source-level triage in three disjoint
parts under `../review/`: 691 source-supported mechanisms, 197 unknown and
one unsupported overclaim; 235 provisional fixes and 654 deferrals. The
partition coverage checker passes exactly. An independent cross-review found
material differences in `fix`/`defer` thresholds, so those proposals still
need reconciliation before becoming an implementation queue.

All 359 rows of the proposed oversized-file owner map have an audit against
the clean pre-release integration candidate. Four paths disappear with the
user-requested GitHub cache dashboard removal; the other 355 still exceed
500 lines, and no new tracked candidate path exceeds 500. Owner corrections,
action conditions and the final merged-main recount remain open. The
17,944-line candidate footprint is gross and conditional; no net saving has
been measured. The deletion guard and GitHub cache dashboard removals belong
to the preceding release, not to refactor savings.

The causal-gap audit identifies a few point causes but cannot allocate the
historical duration shares from retained evidence. The contextual privacy
review and lexical scan are complete for the published research tip; scan and
review any new public evidence before pushing it. The detailed plan is
`docs/plans/2026-09-29-001-refactor-production-readiness-plan.md`.
