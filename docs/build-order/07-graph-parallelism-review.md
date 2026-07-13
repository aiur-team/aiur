# Graph parallelism and phasing review

Current authoritative analysis of the consolidated 54-member graph in
`build-order.json`: 20 BO tickets and 34 DASH tickets, with 105 internal
`depends_on` edges. Publication adds two external skill blockers, producing
107 native `blockedBy` relations across the 56-issue publication boundary
(root + 54 members + skill-delivery issue).

The schedule below is computed by longest dependency path under infinite
capacity. These waves are execution-readiness levels, not manifest
`phase_hint` values; phases remain rollout/display hints under DEC-010.

## Graph health

- 54 members, 184 complexity points, no cycles, and no dangling references.
- 105 internal hard edges plus two external skill blockers.
- Critical-path depth: 10 dependency waves.
- 101 unique, symmetric `serializes_with` pairs; 34 pairs land in the same
  wave and therefore reduce practical concurrency.
- Five members are ready at the start: BO-004, BO-008, DASH-006, DASH-017,
  and DASH-018.

## Dependency-wave profile

| Wave | Width | Points | Tickets |
|---:|---:|---:|---|
| 1 | 5 | 16 | BO-004, BO-008, DASH-006, DASH-017, DASH-018 |
| 2 | 7 | 25 | BO-001, BO-016, BO-017, DASH-001, DASH-004, DASH-012, DASH-019 |
| 3 | 10 | 35 | BO-002, BO-005, BO-009, DASH-002, DASH-007, DASH-008, DASH-013, DASH-020, DASH-021, DASH-026 |
| 4 | 9 | 30 | BO-003, BO-006, BO-010, BO-019, DASH-009, DASH-010, DASH-011, DASH-016, DASH-029 |
| 5 | 4 | 15 | BO-007, BO-018, DASH-014, DASH-024 |
| 6 | 5 | 17 | BO-011, DASH-003, DASH-025, DASH-030, DASH-032 |
| 7 | 8 | 25 | BO-012, DASH-005, DASH-015, DASH-022, DASH-027, DASH-028, DASH-031, DASH-034 |
| 8 | 4 | 13 | BO-013, BO-020, DASH-023, DASH-033 |
| 9 | 1 | 4 | BO-014 |
| 10 | 1 | 4 | BO-015 |

Waves 1–4 retain useful breadth. The tail intentionally narrows around graph
hardening, plan-summary rendering, parity proof, and the BO-015 capstone.

## Critical path and staffing

The serial critical path is:

`BO-004 → BO-001 → BO-002 → BO-003 → BO-007 → BO-011 → BO-012 → BO-013 → BO-014 → BO-015`

Keep that path staffed continuously. The highest direct fan-out nodes are
DASH-003 (8), BO-008 (6), BO-004 (5), BO-017 (5), then BO-005, BO-003,
DASH-001, and DASH-008 (4 each). A stall on these nodes removes more runnable
work than a stall elsewhere.

Wave 7 still contains a practical shared-dashboard serialization clique.
Executors must respect `serializes_with` ownership and requery changed files
before dispatch rather than assuming all eight tickets can land concurrently.
BO-020 shares the Build Order route/CSS with BO-013 and BO-014 in wave 8; its
summary-only boundary must remain intact.

## Review disposition

Earlier review drafts proposed changing hard dependencies and merging tickets
to shorten the schedule. Those proposals were not adopted and are
non-authoritative historical analysis. This review does not authorize graph,
scope, membership, dependency, or serialization changes. Any such change
requires an explicit operator decision and a new approved planning receipt.
