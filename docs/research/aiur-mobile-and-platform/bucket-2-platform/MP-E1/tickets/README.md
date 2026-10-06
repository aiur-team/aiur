# MP-E1 build queue: implementation tickets

Researched 2026-10-06 at base `45a290e3`. Feature plan: [../plan.md](../plan.md)
(§11 lists the Phase C design changes); chunks and research-question
resolutions: [../chunks.md](../chunks.md); contract:
[../../../contracts/queue-readiness-and-build-progress.md](../../../contracts/queue-readiness-and-build-progress.md).

**Status.** All 40 tickets are `blocked` on the owner gate
[DESIGN-E1](../../../owner-design-tasks/DESIGN-E1.md) (MP-REQ2). No ticket is
blocked on an open research question: RQ-1..RQ-8 are resolved; RQ-9 (pacing
census) is non-blocking and is settled by C9-T04. Wave 0 for every ticket (D2):
they ship before the refactor and carry a plan-refresh note. Binding rulings
applied: RC-08, RC-10, RC-11, RC-19, RC-20, RC-23.

## Ticket table

`Level` is the longest predecessor chain inside MP-E1 (L0 = only the design
gate). Tickets on the same level with no edge between them may run at the same
time, subject to the file conflicts below.

| ID | Title | Status | Blocked by | Wave | Level |
| --- | --- | --- | --- | --- | --- |
| [MP-E1-C1-T01](MP-E1-C1-T01.md) | Register the queue marker label and expose Issue.queued | blocked | DESIGN-E1 | 0 | L0 |
| [MP-E1-C1-T02](MP-E1-C1-T02.md) | Treat the queue marker as deliberate parking in the zero-label heal and strand sweep | blocked | DESIGN-E1, C1-T01 | 0 | L1 |
| [MP-E1-C1-T03](MP-E1-C1-T03.md) | Keep open-issue labels from the existing poll and expose them through the tracker contract | blocked | DESIGN-E1 | 0 | L0 |
| [MP-E1-C1-T04](MP-E1-C1-T04.md) | Conditional promotion: expected_state :none on the existing state writer | blocked | DESIGN-E1 | 0 | L0 |
| [MP-E1-C1-T05](MP-E1-C1-T05.md) | Hints table and the DispatchPolicy rank and hold hook | blocked | DESIGN-E1 | 0 | L0 |
| [MP-E1-C1-T06](MP-E1-C1-T06.md) | ClaimProbe behaviour and its orchestration implementation | blocked | DESIGN-E1 | 0 | L0 |
| [MP-E1-C1-T07](MP-E1-C1-T07.md) | Source-scan test that keeps build_queue/ off orchestration and GitHub | blocked | DESIGN-E1, C1-T05 | 0 | L1 |
| [MP-E1-C2-T01](MP-E1-C2-T01.md) | Queue domain model and versioned JSON codec | blocked | DESIGN-E1 | 0 | L0 |
| [MP-E1-C2-T02](MP-E1-C2-T02.md) | Prerequisite verdicts and item readiness | blocked | DESIGN-E1, C2-T01 | 0 | L1 |
| [MP-E1-C2-T03](MP-E1-C2-T03.md) | Downstream counts and the start-order rank | blocked | DESIGN-E1, C2-T01 | 0 | L1 |
| [MP-E1-C2-T04](MP-E1-C2-T04.md) | Pure action planner (desired vs observed labels) | blocked | DESIGN-E1, C2-T02, C2-T03 | 0 | L2 |
| [MP-E1-C3-T01](MP-E1-C3-T01.md) | build_queue config section, state path key and their docs | blocked | DESIGN-E1 | 0 | L0 |
| [MP-E1-C3-T02](MP-E1-C3-T02.md) | Durable queue store that fails closed | blocked | DESIGN-E1, C2-T01, C3-T01 | 0 | L1 |
| [MP-E1-C3-T03](MP-E1-C3-T03.md) | Queue server - supervision, triggers, reconcile loop and Hints ownership | blocked | DESIGN-E1, C3-T02, C2-T04, C1-T03, C1-T05, C1-T06 | 0 | L3 |
| [MP-E1-C3-T04](MP-E1-C3-T04.md) | Write protocol - intents, conditional promotion, marker writes, pacing and budget pause | blocked | DESIGN-E1, C3-T03, C1-T01, C1-T04 | 0 | L4 |
| [MP-E1-C3-T05](MP-E1-C3-T05.md) | Withdrawal protocol after a dependency change (D8) | blocked | DESIGN-E1, C3-T04, C1-T02, C1-T05, C1-T06 | 0 | L5 |
| [MP-E1-C3-T06](MP-E1-C3-T06.md) | Competing writers - manual promotion, external hold, marker removal | blocked | DESIGN-E1, C3-T04 | 0 | L5 |
| [MP-E1-C3-T07](MP-E1-C3-T07.md) | Restart recovery and marker-based rebuild | blocked | DESIGN-E1, C3-T04 | 0 | L5 |
| [MP-E1-C4-T01](MP-E1-C4-T01.md) | ExecutorList source - ordered list with "after #N" edges | blocked | DESIGN-E1, C2-T01, C3-T03 | 0 | L4 |
| [MP-E1-C4-T02](MP-E1-C4-T02.md) | Build Order source - adopt a root as an optional dependency input | blocked | DESIGN-E1, C4-T01, C3-T05 | 0 | L6 |
| [MP-E1-C4-T03](MP-E1-C4-T03.md) | Native blocked_by of ExecutorList items through a tracker callback | blocked | DESIGN-E1, C4-T01, C2-T02 | 0 | L5 |
| [MP-E1-C4-T04](MP-E1-C4-T04.md) | Closed-prerequisite state_reason through a tracker callback | blocked | DESIGN-E1, C2-T02, C3-T03 | 0 | L4 |
| [MP-E1-C4-T05](MP-E1-C4-T05.md) | Closed-unmerged ticket PR as a failed prerequisite (webhook mode) | blocked | DESIGN-E1, C2-T02, C3-T03 | 0 | L4 |
| [MP-E1-C4-T06](MP-E1-C4-T06.md) | Merged PR but issue still open - grace timer and attention | blocked | DESIGN-E1, C4-T04, C4-T05, C3-T03, C3-T01, C5-T01 | 0 | L5 |
| [MP-E1-C5-T01](MP-E1-C5-T01.md) | Attention module - single Alerts caller, durable latches, Executor bindings | blocked | DESIGN-E1, C3-T02, C3-T03 | 0 | L4 |
| [MP-E1-C5-T02](MP-E1-C5-T02.md) | The queue attentions - failed prerequisite and the six other causes | blocked | DESIGN-E1, C5-T01, C3-T05, C4-T06 | 0 | L6 |
| [MP-E1-C5-T03](MP-E1-C5-T03.md) | Live ticket.<id>.queue.* events | blocked | DESIGN-E1, C3-T04, C3-T06 | 0 | L6 |
| [MP-E1-C5-T04](MP-E1-C5-T04.md) | Promoted but unauthorized - detect the dispatcher's decline | blocked | DESIGN-E1, C5-T01, C1-T06, C3-T04 | 0 | L5 |
| [MP-E1-C6-T01](MP-E1-C6-T01.md) | aiur queue show - read model, human and JSON output | blocked | DESIGN-E1, C3-T03 | 0 | L4 |
| [MP-E1-C6-T02](MP-E1-C6-T02.md) | aiur queue add/remove/reorder/hold/release with the agent-workspace guard | blocked | DESIGN-E1, C6-T01, C4-T01, C4-T02, C3-T06 | 0 | L7 |
| [MP-E1-C6-T03](MP-E1-C6-T03.md) | aiur queue recover and clear --remove-markers (rollback runbook) | blocked | DESIGN-E1, C6-T02, C3-T07 | 0 | L8 |
| [MP-E1-C7-T01](MP-E1-C7-T01.md) | Aiur.BuildProgress - progress facts, read API, change signal and milestones | blocked | DESIGN-E1 | 0 | L0 |
| [MP-E1-C7-T02](MP-E1-C7-T02.md) | Queue progress producer | blocked | DESIGN-E1, C7-T01, C3-T03 | 0 | L4 |
| [MP-E1-C7-T03](MP-E1-C7-T03.md) | Build Order progress observer | blocked | DESIGN-E1, C7-T01 | 0 | L1 |
| [MP-E1-C8-T01](MP-E1-C8-T01.md) | Read-only build-queue dashboard view with every state | blocked | DESIGN-E1, C6-T01, C7-T02 | 0 | L5 |
| [MP-E1-C8-T02](MP-E1-C8-T02.md) | Queue view navigation, docs page and browser check | blocked | DESIGN-E1, C8-T01 | 0 | L6 |
| [MP-E1-C9-T01](MP-E1-C9-T01.md) | Skill conventions - create waiting members with the marker; queue usage | blocked | DESIGN-E1, C6-T02, C4-T02 | 0 | L8 |
| [MP-E1-C9-T02](MP-E1-C9-T02.md) | Concept docs - queue states, marker, Build Order queueing | blocked | DESIGN-E1, C5-T02, C6-T02 | 0 | L8 |
| [MP-E1-C9-T03](MP-E1-C9-T03.md) | End-to-end acceptance (AC12) through aiurdev --test3, and a clean test reset | blocked | DESIGN-E1, C3-T05, C3-T06, C3-T07, C4-T03, C5-T02, C6-T02, C9-T01 | 0 | L9 |
| [MP-E1-C9-T04](MP-E1-C9-T04.md) | Measure queue GitHub cost and census Build Order sizes (instrumentation, no saving claimed) | blocked | DESIGN-E1, C9-T03 | 0 | L10 |

## Dependency order


- **L0:** C1-T01, C1-T03, C1-T04, C1-T05, C1-T06, C2-T01, C3-T01, C7-T01
- **L1:** C1-T02, C1-T07, C2-T02, C2-T03, C3-T02, C7-T03
- **L2:** C2-T04
- **L3:** C3-T03
- **L4:** C3-T04, C4-T01, C4-T04, C4-T05, C5-T01, C6-T01, C7-T02
- **L5:** C3-T05, C3-T06, C3-T07, C4-T03, C4-T06, C5-T04, C8-T01
- **L6:** C4-T02, C5-T02, C5-T03, C8-T02
- **L7:** C6-T02
- **L8:** C6-T03, C9-T01, C9-T02
- **L9:** C9-T03
- **L10:** C9-T04

Critical path (11 merges): C2-T01 → C2-T02 → C2-T04 → C3-T03 → C3-T04 →
C3-T05 → C4-T02 → C6-T02 → C9-T01 → C9-T03 → C9-T04.

## What may run concurrently

- **L0 (eight tickets) all at once** once DESIGN-E1 is approved: the core seams
  (C1-T01, T03..T06), the model (C2-T01), config (C3-T01) and `BuildProgress`
  (C7-T01). They touch different files.
- **C7 is independent of the queue core**: C7-T01 and C7-T03 can ship before
  the server exists (Build Order milestones need no queue).
- **After C3-T03**, the sources (C4-T01, T04, T05), attention (C5-T01), the read
  CLI (C6-T01) and queue progress (C7-T02) run in parallel.
- **After C3-T04**, C3-T05, C3-T06 and C3-T07 run in parallel.

## File conflicts (serialize these)

| File | Tickets | Rule |
| --- | --- | --- |
| `src/lib/aiur/tracker.ex`, `github/tracker.ex`, `memory/tracker.ex`, `linear/tracker.ex` | C1-T03, C3-T04 (`ensure_labels`), C4-T03, C4-T04, C4-T05 | one optional callback per PR; rebase in level order |
| `src/lib/aiur/build_queue/server.ex` | C3-T03..T07, C4-*, C5-*, C7-T02 | small, additive wiring per ticket; rebase onto the previous merge |
| `src/lib/aiur/build_queue/observer.ex` | C4-T03..T06 | same |
| `packaging/npm/aiur-cli/libexec/aiur-engine.sh` | C6-T01..T03 | in order |
| `src/lib/aiur/github/issues.ex` | C1-T01, C1-T03, C4-T04 | U8 size debt: ≤ 15 lines each |
| `src/lib/aiur.ex` (children) | C3-T03, C7-T01, C7-T03 | one line each |

## Release constraints

- **C1-T01 ships in a release before C3-T04 merges.** A release without the
  marker registration reads `agent:queued` as a state label (plan §8).
- **C1-T02 ships no later than C3-T05** (otherwise the zero-label heal undoes
  every withdrawal).
- **C9-T01** (skill conventions) ships only after a release has the queue
  enabled by default.

## Prior refactor coordination (RC-19, RC-20)

MP-E1 is not gated on U0. Its core edits are the C1 hooks
(`labels.ex`, `issues.ex`, `issue_sync.ex`, `dispatch_policy.ex`,
`pause_resume.ex`, `orchestrator.ex`, `issue_state.ex`) plus the tracker
callbacks (C1-T03, C3-T04, C4-T03..T05) and the progress observer (C7-T03). U2 and U5
tickets rebase over them and keep them. The queue writes labels only through
the existing label-writer seam, and through U2's writer after U2 lands.

