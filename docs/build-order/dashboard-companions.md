# Standalone Dashboard Companion Tickets

These eight tickets implement the delta between current dashboard scope and the
refreshed prototype. They are intentionally not members, dependencies, or
acceptance requirements of the Build Order root.

| ID | Requirement | Outcome | Cx | Depends on |
|---|---|---|---:|---|
| [DASH-001](companion-tickets/DASH-001-responsive-shell.md) | DREQ-001 | Responsive route-aware shell | 3 | — |
| [DASH-002](companion-tickets/DASH-002-units-read-model.md) | DREQ-002 | Units read model and exact filters | 4 | — |
| [DASH-003](companion-tickets/DASH-003-unit-capacity-controls.md) | DREQ-003 | Real unit and max-agent controls | 4 | DASH-002 |
| [DASH-004](companion-tickets/DASH-004-commands-catch-up.md) | DREQ-004 | Commands presentation parity | 3 | — |
| [DASH-005](companion-tickets/DASH-005-usage-observations.md) | DREQ-005 | Durable attributed observations | 4 | — |
| [DASH-006](companion-tickets/DASH-006-usage-accounting.md) | DREQ-006 | Cost/coverage/grouping projection | 4 | DASH-005 |
| [DASH-007](companion-tickets/DASH-007-provider-meters.md) | DREQ-007 | Subscription/API account meters | 4 | — |
| [DASH-008](companion-tickets/DASH-008-usage-summary.md) | DREQ-008 | Shared run/build summary UI | 3 | DASH-006, DASH-007 |

## Why eight

- Navigation/shell and Units state/filtering have separate reusable outcomes.
- Per-unit and capacity controls cross an authenticated mutation boundary and
  cannot be treated as visual acceptance inside the read-only Units ticket.
- Commands composes the durable Decision domain and has its own regression
  boundary.
- Durable observation ingestion and versioned financial aggregation differ in
  storage, correctness, security, and verification. Keeping them together
  would hide a complexity-5 program in one issue.
- Provider quota meters are account state, not ticket attribution.
- Summary UI joins accounting and meters but owns no ingestion.

## Scheduling and conflicts

- DASH-001 owns the shared shell and navigation. BO-009 registers its route.
- DASH-002 owns Units rows/filter policy. DASH-003 owns writes and capacity.
- BO-008 owns reusable ticket context; Units consumes it when available.
- DASH-002, DASH-003, DASH-004, DASH-008, and BO-009 may touch dashboard
  composition/CSS and must be sequenced or rebased rather than run as
  conflicting writers.
- DASH-005 and DASH-007 can run in parallel. DASH-006 follows DASH-005;
  DASH-008 follows DASH-006 and DASH-007.

## Publication

After review, create these as standalone issues with one `complexity:N` and
`model:codex`. Do not add `agent:todo`, `phase:N`, `build-lane:*`, or the Build
Order parent. A later planning run may organize them into their own bounded
order if desired.
