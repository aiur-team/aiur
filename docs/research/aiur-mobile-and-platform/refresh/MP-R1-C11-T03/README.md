# Final refresh checkpoint

Status: **incomplete; no wave-2 or directory-publish sign-off**.

This checkpoint preserves the reconstructed evidence for #3340 after workspace
recreation removed the earlier scratch draft. It is not the final refresh.

## Inputs and provenance

- Research pack: `de341053cc16d2e6096a3a0d0fbacb43ef9f6eb0` (research/refactor-findings).
- Current-main overlay and report target: `4fbe109541ba1e279d3eb315d8455c4d139c92ba`.
- Range start: `45a290e3053423100a73b534c620fdd12ebe11ad`.
- Ledger publication: `c96025161f1688888de4159d8c31fb117a989b6a`; actual CSV read from report target.
- Source pack was exported from research, then current main's merged owner docs
  were overlaid. This preserves MP-R2's accepted refresh rather than restoring
  its older research copy. See [pins](pins.json).
- MP-R2 owner refresh #3368 merged through PR #6255, merge
  `75bb894d20f9401fddc8c0257b7c7a6fb9a3dbc1`. It is no longer an outstanding
  dependency. Native unblock attempted once but returned
  coordination_operation_exception; its existing dependency edge is already closed.

## Pre-edit report

60 file moves; 9086 citations: GONE 260, LINES-CHANGED 1136,
LINES-SHIFTED 489, MOVED 65, OK 3008, UNRESOLVED 4128.
16 migration rows and 665 candidate size-owner outcomes.

These are tool classifications before this turn's draft edits. Proposed paths,
globs, directories, sibling-repository references and coordinates already stamped
by C11-T02 need interpretation; they are not automatically invalid designs.
The tool's same-range replay does not prove all-OK semantics for mixed baselines.

The 25 parts below concatenate exactly to the 9857-line raw report.
SHA256: `f0ccef0102a15c29380d4b41656cffcb0a5b777858076b3a33da591c4687280c`. Every part is at most 400 lines.

## Recovered preparation

- [Current manifest paths](component-paths.md), measured from the target, without
  asserting that conditional physical-package promotions have occurred.
- [Prospective first-frontier admissions](admissions.md), measured from current
  blobs rather than the historical release_lines column. These do not establish
  complete implementation scope, predicted final sizes or admission.
- Private draft restores the prior plan's RC-19–RC-22 closures, C9-T10–T14 and
  synchronous delivery wording. First three E2 implementation candidates have
  re-read code-owner starting points: Codec/Reducers/Persistence/Requests,
  Config schema, and the serialized Revisions guard. Whole-ticket audits remain open.

## Validation at this checkpoint

- `python3 scripts/test_plan_refresh.py`: all 17 existing fixtures pass.
- `python3 scripts/check-components.py`: passes with existing baselines;
  all 2919 source files owned. No zero-violation claim.
- `python3 scripts/check-components.py --docs`: docs references valid.
- Locked TypeScript dependency installed with
  `npm ci --prefix scripts/components --ignore-scripts` before component checks.
- No production changes or new tests. No manual CLI/TUI acceptance applies here.
- Earlier 102-edit/116-file draft and its checksum are historical and absent from
  this recreated workspace. They are not claimed recovered or newly validated.

## Remaining acceptance

1. Confirm destination: original ticket specifies research-only with coordinator
   commits; agent workflow specifies canonical branch and main PR. Keep the
   source pack unpublished until that sequencing question is answered.
2. Complete Procedure A across waves 2–5 and unfinished wave-1 tickets. Preserve
   accepted owner refreshes; re-read changed/gone/split citations, add named
   REFRESH items only for concretely invalidated designs, and retain old base_sha
   unless every citation is verified. Update canonical and build-order mirrors.
3. Complete RC-23 admissions for first-ready E2 work with actual edited tests,
   new files, predicted final sizes and no-growth constraints.
4. Finish all 16 migration rows with actual targets and merge receipts; finalize
   component-map section 3; list relevant unmerged R2/R5/R6/R7 work without
   blocking on unrelated R3/R4 work.
5. Compare all cited contract states, run the post-edit report and manually inspect
   five wave-2 citations. Only explicitly blocked tickets may retain unresolved
   wave-2 GONE/LINES-CHANGED citations.
6. Commit accepted report and edits together; coordinator signs off only when the
   conditions are met. No ready PR or CI/review handoff is warranted by this checkpoint.

## Raw report

- [Part 1](raw-01.md)
- [Part 2](raw-02.md)
- [Part 3](raw-03.md)
- [Part 4](raw-04.md)
- [Part 5](raw-05.md)
- [Part 6](raw-06.md)
- [Part 7](raw-07.md)
- [Part 8](raw-08.md)
- [Part 9](raw-09.md)
- [Part 10](raw-10.md)
- [Part 11](raw-11.md)
- [Part 12](raw-12.md)
- [Part 13](raw-13.md)
- [Part 14](raw-14.md)
- [Part 15](raw-15.md)
- [Part 16](raw-16.md)
- [Part 17](raw-17.md)
- [Part 18](raw-18.md)
- [Part 19](raw-19.md)
- [Part 20](raw-20.md)
- [Part 21](raw-21.md)
- [Part 22](raw-22.md)
- [Part 23](raw-23.md)
- [Part 24](raw-24.md)
- [Part 25](raw-25.md)
