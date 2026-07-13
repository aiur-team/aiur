# BO-005 — Migrate AgentList to shared activity

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Characterize and convert one existing UI consumer

**Risk:** medium

**Phase hint:** 3

**Depends on:** BO-004

**Serializes with:** none

**Requirements:** BOREQ-005

**Decisions:** DEC-006

**Design evidence:** DESIGN-002

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:3`, `model:codex`, `phase:3`, `build-lane:backend`; never `agent:todo`

## Outcome

The interactive AgentList consumes the shared ticket activity projection without losing existing event rendering, debug ticker behavior, roster visibility, progress, phase, or snapshot semantics.

## Context and evidence

Creating a shared projection is incomplete if AgentList keeps a second divergent progress/latest/phase fold. At the same time, the migration is a distinct compatibility outcome from BO-004 and can land or rework independently.

AgentList may still need direct debug-log events for its debug-only UI. The migration must preserve that presentation behavior while moving canonical state ownership.

## Scope

- Characterize current AgentList latest-event, progress, phase, roster pruning, debug ticker, and snapshot behavior with regression tests before conversion.
- Replace canonical activity reads/folds with the BO-004 projection and keep only view-specific selection, sorting, pruning, and rendering state in AgentList.
- Preserve direct debug event rows where they are presentation-only, without double-applying them to canonical activity.
- Remove obsolete duplicate reducers/state only after parity tests prove no semantic loss.
- Document the single ownership seam for future TUI/dashboard consumers.

## Non-goals

- Change AgentList visual design, sorting policy, key bindings, chat panes, or debug verbosity.
- Add Build Order UI, GitHub fetching, or new progress semantics.
- Expand projection retention based on incidental TUI discoveries; route those to BO-004 rework if required.

## Existing owner and reuse target

Migrate `Aiur.AgentList.EventIntake`, Roster, renderer/ticker consumers, and their tests to `TicketActivityProjection`. Preserve view-specific code in AgentList rather than over-generalizing it.

## Contract and invariants

- One canonical reducer owns shared activity facts after migration.
- AgentList roster pruning affects only visible TUI rows, not shared projection retention.
- Debug-only rendered rows remain available without becoming a second canonical latest/progress store.
- Existing public snapshot and operator-visible status behavior remain compatible unless an explicit tested correction is required.

## Refreshable implementation notes

- Use characterization tests first; current file/module names may move before pickup.
- Keep compatibility adapters small and delete them only when all call sites are converted.
- Any newly discovered domain mismatch belongs to BO-004 rework unless it is strictly AgentList presentation.

## Acceptance and verification

### Agent gate

- Existing AgentList regression/snapshot suites pass unchanged or with reviewed intentional evidence updates.
- New characterization proves progress, phase, latest event, debug ticker, roster pruning, queue/retry/completed rows, and no double counting.
- Headless TicketActivity tests remain independent of AgentList startup.

### At-merge gate

- Full interactive and headless focused suites plus current-base CI pass.
- Manual acceptance belongs to BO-011; this ticket records any snapshot/evidence changes for that capstone.

### Human/manual evidence

- No separate human evidence; BO-011 owns end-to-end operator proof.

## Failure, security, migration, and accessibility cases

- Security: do not broaden event content retained or rendered.
- Migration: run shared projection and compatibility reads safely during rollout; no state-file migration.
- Accessibility: preserve existing TUI-readable status phrasing and focus/navigation behavior.

## Surfaces

- Reads: TicketActivityProjection; AgentList event and roster behavior.
- Writes: AgentList activity consumers; characterization and compatibility tests.
- Contracts: single canonical activity ownership; AgentList presentation compatibility.

## Sibling boundaries and open gates

BO-004 owns projection semantics and fixes contained domain gaps. BO-011 waits for this migration before final acceptance. No dashboard ticket should edit AgentList activity ownership.

