# Current seven-wave execution plan

**Status:** binding operational schedule for the Build Order run on `develop`.

This document replaces the older ten-row dependency-wave presentation and all
published phase hints for current execution. GitHub's `phase:1` through
`phase:7` labels are the materialized execution-wave metadata. The machine
readable source is [`execution-waves.json`](execution-waves.json), and the
static plan preview must render that file's seven-wave partition without a
legacy/history mode.

Execution-wave labels are ordering and presentation guidance, not readiness
edges. Native GitHub `blockedBy` relations remain authoritative. Within the
set of ready work, staff the critical path first, then the earliest execution
wave, and use later-wave work only when higher-value work is blocked and its
file/seam owner is free.

## Wave partition

| Wave | Tickets | Purpose |
|---|---|---|
| W1 | BO-004, BO-008, DASH-006, DASH-017, DASH-018 | Identity, harness, retained decisions, and provider generation foundations |
| W2 | BO-001, BO-016, BO-017, DASH-001, DASH-004, DASH-012, DASH-019 | Domain, detail/event, shell, controls, and provider transport contracts |
| W3 | BO-002, BO-005, BO-009, DASH-002, DASH-007, DASH-008, DASH-013, DASH-020, DASH-021, DASH-026 | Graph fetch, shared projections, layout platform, commands, accounting envelopes, auth, and conversations |
| W4 | BO-003, BO-006, BO-010, BO-019, DASH-009, DASH-010, DASH-011, DASH-016, DASH-029 | Atomic graph/activity consumers, layout adapter, history, ledger/pricing, Units policy, and headless usage |
| W5 | BO-007, BO-018, DASH-014, DASH-024, DASH-025, DASH-030, DASH-032 | Lane anchors plus complete runtime-summary and usage-query/storage lanes |
| W6 | BO-011, BO-012, BO-013, BO-014, BO-020, DASH-003, DASH-005, DASH-015, DASH-022, DASH-023, DASH-027, DASH-028, DASH-031, DASH-034 | Consolidated Build Order graph surface and companion dashboard surface |
| W7 | DASH-033, BO-015 | One parity and program-acceptance tail |

## Reconciliation gate

Before Aiur starts or restarts, the Executor must verify all of the following:

1. The seven arrays form an exact 54-ticket partition with no duplicate or
   missing logical ID.
2. Every mapped GitHub issue has exactly its declared `phase:<wave>` label and
   no other `phase:*` label.
3. The preview renders exactly W1–W7 from the same partition.
4. Every open ticket still carries its DEC-015 current-`develop` ownership
   amendment; issue bodies and native dependency edges are not rewritten.
5. No ticket is dispatched solely because of its wave label: blockers,
   lifecycle, current `develop`, and single-writer constraints are re-queried.

Do not mark the planning gate complete or restart execution if any check
fails.
