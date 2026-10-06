# aiur modular platform, mobile and watch — research pack

This pack is the research and planning for three buckets of work on aiur (brief §10):

1. **Refactor (MP-R1–R7):** a modular platform with a component map, a shared event bus,
   optional Tailscale, the `hooks.aiur.dev` boundary, an optional voice package, Stream
   Deck projections and harness adapters.
2. **Platform features (MP-E1–E7):** the build queue, Commands and escalation, Executor
   communication, dashboard conversations, dashboard voice, a conversational voice
   assistant and a shared agent-listener package.
3. **Mobile and watch (MP-N1–N7):** a phone app, machine-level pairing, a meta-dashboard,
   end-to-end encrypted push, notification preferences, Command response on phone and
   watch, and watch apps.

It is **research only**. Nothing in it is implemented, and no implementation may start
until Kevin authorizes it (brief §10). The verdict and what blocks each feature are in
[readiness-report.md](readiness-report.md).

- **Repository base:** `45a290e3` (branch `research/refactor-findings`). Every ticket
  records this `base_sha`.
- **Research date:** 2026-10-06.
- **Size:** 21 features, 525 tickets (121 `ready`, 404 `blocked`), 14 contract files,
  21 owner design gates, 164 owner questions, each with a recommendation.

## How to read the pack

Read in this order. Each step assumes the one before it.

1. [brief.md](brief.md) — the request: goals, the settled decisions, the required ticket
   depth (§9) and the deliverables (§10).
2. [context-and-decisions.md](context-and-decisions.md) — the binding decisions D1–D20.
   Later documents apply them; they do not reopen them.
3. [feature-inventory.md](feature-inventory.md) — every feature, its scope and its
   non-goals. The verified baseline is in [baseline/](baseline/capability-baseline.md).
4. [value-and-sequencing.md](value-and-sequencing.md) — the value order and the waves
   (D1).
5. [dependency-map.md](dependency-map.md) — the one dependency graph and delivery
   sequence, with the first-eligible tickets per approval. Machine-readable:
   [dependency-graph.json](dependency-graph.json).
6. [contracts/](#contracts) — the shared interfaces between features.
7. **bucket → feature → chunk → ticket.** Each feature folder has `plan.md`, usually
   `chunks.md`, and `tickets/README.md` (MP-R1 splits it in two), which lists every ticket with its status,
   blockers and wave. Each ticket file has the nine brief §9 sections.
8. [owner-design-tasks/](owner-design-tasks/) — one DESIGN gate per feature. Each gate
   lists the decisions, states and acceptance conditions that Kevin approves.
9. [cross-feature-reviews/](cross-feature-reviews/) — reconciliation (RC-01..RC-42),
   the four Phase D reviews, the fix logs, the graph check and the single
   [owner-questions.md](cross-feature-reviews/owner-questions.md) list.
10. [readiness-report.md](readiness-report.md) — what is planned, what is blocked on
    Kevin, what is unverified, and what can start first.

**Status words.** A ticket with `status: ready` is **researched and fully specified**;
it still waits on everything in its `blocked_by` (gates, tickets, owner items). It does not
mean "can start now". Use [dependency-map.md](dependency-map.md), not the status field, to
decide what can start (review T-10).

## Features

Ticket counts are from the final [graph check](cross-feature-reviews/graph-check.md).
Waves are from [value-and-sequencing.md](value-and-sequencing.md); a split wave is
explained in the tickets README.

| Feature | Plan | Tickets | Gate | Ready | Blocked | Wave |
|---|---|---|---|---|---|---|
| MP-R1 Modular platform and component map | [plan](bucket-1-refactor/MP-R1/plan.md) | [C1–C5](bucket-1-refactor/MP-R1/tickets/README-C1-C5.md), [C6–C11](bucket-1-refactor/MP-R1/tickets/README-C6-C11.md) | [DESIGN-R1](owner-design-tasks/DESIGN-R1.md) | 0 | 69 | 1 |
| MP-R2 Shared event bus | [plan](bucket-1-refactor/MP-R2/plan.md) | [README](bucket-1-refactor/MP-R2/tickets/README.md) | [DESIGN-R2](owner-design-tasks/DESIGN-R2.md) | 26 | 12 | 1 (C5 in 4, C6/C7 in 5) |
| MP-R3 Optional Tailscale | [plan](bucket-1-refactor/MP-R3/plan.md) | [README](bucket-1-refactor/MP-R3/tickets/README.md) | [DESIGN-R3](owner-design-tasks/DESIGN-R3.md) | 0 | 2 | 1 |
| MP-R4 `hooks.aiur.dev` relay boundary | [plan](bucket-1-refactor/MP-R4/plan.md) | [README](bucket-1-refactor/MP-R4/tickets/README.md) | [DESIGN-R4](owner-design-tasks/DESIGN-R4.md) | 0 | 1 | 1 |
| MP-R5 Optional voice package | [plan](bucket-1-refactor/MP-R5/plan.md) | [README](bucket-1-refactor/MP-R5/tickets/README.md) | [DESIGN-R5](owner-design-tasks/DESIGN-R5.md) | 0 | 9 | 1 |
| MP-R6 Stream Deck projections | [plan](bucket-1-refactor/MP-R6/plan.md) | [README](bucket-1-refactor/MP-R6/tickets/README.md) | [DESIGN-R6](owner-design-tasks/DESIGN-R6.md) | 0 | 3 | 1 |
| MP-R7 Harness adapter package | [plan](bucket-1-refactor/MP-R7/plan.md) | [README](bucket-1-refactor/MP-R7/tickets/README.md) | [DESIGN-R7](owner-design-tasks/DESIGN-R7.md) | 14 | 7 | 1 |
| MP-E1 Build queue | [plan](bucket-2-platform/MP-E1/plan.md) | [README](bucket-2-platform/MP-E1/tickets/README.md) | [DESIGN-E1](owner-design-tasks/DESIGN-E1.md) | 0 | 41 | 0 (C3-T08 in 1) |
| MP-E2 Commands, Executor awareness, escalation | [plan](bucket-2-platform/MP-E2/plan.md) | [README](bucket-2-platform/MP-E2/tickets/README.md) | [DESIGN-E2](owner-design-tasks/DESIGN-E2.md) | 2 | 34 | 2 |
| MP-E3 Executor communication | [plan](bucket-2-platform/MP-E3/plan.md) | [README](bucket-2-platform/MP-E3/tickets/README.md) | [DESIGN-E3](owner-design-tasks/DESIGN-E3.md) | 1 | 19 | 3 |
| MP-E4 Dashboard conversations and anchors | [plan](bucket-2-platform/MP-E4/plan.md) | [README](bucket-2-platform/MP-E4/tickets/README.md) | [DESIGN-E4](owner-design-tasks/DESIGN-E4.md) | 1 | 19 | 3 |
| MP-E5 Dashboard voice input | [plan](bucket-2-platform/MP-E5/plan.md) | [README](bucket-2-platform/MP-E5/tickets/README.md) | [DESIGN-E5](owner-design-tasks/DESIGN-E5.md) | 8 | 11 | 4 (C7-T01 and C8 in 5) |
| MP-E6 Conversational voice assistant | [plan](bucket-2-platform/MP-E6/plan.md) | [README](bucket-2-platform/MP-E6/tickets/README.md) | [DESIGN-E6](owner-design-tasks/DESIGN-E6.md) | 14 | 17 | 4 |
| MP-E7 Shared agent-listener package | [plan](bucket-2-platform/MP-E7/plan.md) | [README](bucket-2-platform/MP-E7/tickets/README.md) | [DESIGN-E7](owner-design-tasks/DESIGN-E7.md) | 13 | 20 | 3 (C1–C3) / 4 (C4–C7) |
| MP-N1 Phone app architecture | [plan](bucket-3-mobile-watch/MP-N1/plan.md) | [README](bucket-3-mobile-watch/MP-N1/tickets/README.md) | [DESIGN-N1](owner-design-tasks/DESIGN-N1.md) | 0 | 31 | 5 |
| MP-N2 Machine pairing and instance discovery | [plan](bucket-3-mobile-watch/MP-N2/plan.md) | [README](bucket-3-mobile-watch/MP-N2/tickets/README.md) | [DESIGN-N2](owner-design-tasks/DESIGN-N2.md) | 0 | 39 | 5 |
| MP-N3 Phone meta-dashboard | [plan](bucket-3-mobile-watch/MP-N3/plan.md) | [README](bucket-3-mobile-watch/MP-N3/tickets/README.md) | [DESIGN-N3](owner-design-tasks/DESIGN-N3.md) | 0 | 16 | 5 |
| MP-N4 Encrypted rich notifications | [plan](bucket-3-mobile-watch/MP-N4/plan.md) | [README](bucket-3-mobile-watch/MP-N4/tickets/README.md) | [DESIGN-N4](owner-design-tasks/DESIGN-N4.md) | 23 | 11 | 5 |
| MP-N5 Notification preferences and progress | [plan](bucket-3-mobile-watch/MP-N5/plan.md) | [README](bucket-3-mobile-watch/MP-N5/tickets/README.md) | [DESIGN-N5](owner-design-tasks/DESIGN-N5.md) | 12 | 5 | 5 |
| MP-N6 Command response on phone and watch | [plan](bucket-3-mobile-watch/MP-N6/plan.md) | [README](bucket-3-mobile-watch/MP-N6/tickets/README.md) | [DESIGN-N6](owner-design-tasks/DESIGN-N6.md) | 7 | 13 | 5 |
| MP-N7 Watch apps | [plan](bucket-3-mobile-watch/MP-N7/plan.md) | [README](bucket-3-mobile-watch/MP-N7/tickets/README.md) | [DESIGN-N7](owner-design-tasks/DESIGN-N7.md) | 0 | 25 | 5 |
| **Total** | | | 21 gates | **121** | **404** | |

Feature folders with extra evidence: MP-R1 (component map, capability matrix, component
directory, migration plan), MP-R2 (inventory), MP-E1 (findings), MP-E6 (provider
research), MP-N1 (framework evidence, surface boundary, device validation), MP-N4
(platform evidence, device-validation plan).

## Contracts

| Contract | Owner feature |
|---|---|
| [identity-and-capabilities.md](contracts/identity-and-capabilities.md) | MP-R1 |
| [events-and-replay.md](contracts/events-and-replay.md) | MP-R2 |
| [harness-adapter.md](contracts/harness-adapter.md) | MP-R7 |
| [queue-readiness-and-build-progress.md](contracts/queue-readiness-and-build-progress.md) | MP-E1 |
| [command-request-and-resolution.md](contracts/command-request-and-resolution.md) | MP-E2 |
| [conversations-transcripts-anchors.md](contracts/conversations-transcripts-anchors.md) | MP-E4 |
| [voice-session.md](contracts/voice-session.md) and [voice-session-client-errors.md](contracts/voice-session-client-errors.md) | MP-E6 (co-owned with MP-E5 for §2–§5; MP-R5 implements the STT/TTS roles) |
| [listener-mode.md](contracts/listener-mode.md) | MP-E7 |
| [client-capability-model.md](contracts/client-capability-model.md) | MP-N1 |
| [pairing-and-instance-registry.md](contracts/pairing-and-instance-registry.md), [-security](contracts/pairing-and-instance-registry-security.md), [-reconciliation](contracts/pairing-and-instance-registry-reconciliation.md) | MP-N2 (MP-N3 owns the §7 instance summary) |
| [notification-destination-and-payload.md](contracts/notification-destination-and-payload.md) | MP-N4 |

How contract requests between features were settled:
[contract-requests-resolution.md](cross-feature-reviews/contract-requests-resolution.md).

## Owner work

- **Design gates:** [owner-design-tasks/](owner-design-tasks/), one per feature. A gate
  is approved when Kevin answers every decision in it and records "approved" with a date.
- **All owner questions, de-duplicated:**
  [owner-questions.md](cross-feature-reviews/owner-questions.md). §0 lists the nine to
  answer first.

## Cross-feature reviews

- [phase-b-reconciliation.md](cross-feature-reviews/phase-b-reconciliation.md) — RC-01..RC-42,
  the binding cross-feature decisions after the feature plans.
- Phase D reviews: [consistency and modularity](cross-feature-reviews/review-consistency-modularity.md),
  [feasibility and failures](cross-feature-reviews/review-feasibility-failures.md),
  [privacy and security](cross-feature-reviews/review-privacy-security.md),
  [UX gates and ticket depth](cross-feature-reviews/review-ux-and-ticket-depth.md).
- Fix logs: [platform](cross-feature-reviews/fix-log-platform.md),
  [security](cross-feature-reviews/fix-log-security.md),
  [mobile](cross-feature-reviews/fix-log-mobile.md), [ux](cross-feature-reviews/fix-log-ux.md);
  [handoffs](cross-feature-reviews/fix-handoffs.md) and their
  [final disposition](cross-feature-reviews/fix-handoffs-applied.md).
- [graph-check.md](cross-feature-reviews/graph-check.md) — integrity of the dependency
  graph (0 dangling references, 0 cycles, 0 missing gates, 0 wave inversions).

## Prior research (preserved)

This pack builds on, and does not replace, the earlier refactor research:

- [../refactor-2026-09-26/](../refactor-2026-09-26/) — the refactor census and findings.
- [docs/plans/2026-09-29-001-refactor-production-readiness-plan.md](../../plans/2026-09-29-001-refactor-production-readiness-plan.md)
  — the prior refactor plan (units U0–U8). RC-19 keeps its U0 review gate for all
  refactor work.
- [baseline/existing-refactor-research.md](baseline/existing-refactor-research.md) — how
  this pack maps to that research.

## Plan refresh

The refactor moves paths and contracts, so ticket citations at `45a290e3` go stale as it
lands. Implementers must not rediscover the mapping by hand:

- **MP-R1-C11-T01** builds the plan-refresh tool (path map, stale citations, size
  owners between two commits).
- **MP-R1-C11-T02** is the recurring runbook. It resolves each ticket's size owner when
  the ticket starts, against the then-current U8 ledger (**RC-23**: the U8 ledger is
  pinned at `465aca643`, the pack at `45a290e3`).
- **MP-R1-C11-T03** is the final refresh after MP-R1-C9 and the gate before wave 2
  (RC-35).

Details: [dependency-map.md § Plan refresh](dependency-map.md#plan-refresh).

## In progress: MP-E8 Continuous build history

This feature was added on 2026-10-06, after the readiness report, and is still in brainstorm. It merges the Build Order and Units pages into a single scrollable history: past tickets first, then planned, then not queued. It adds feature tagging with focus and compact modes, a Gantt mode, and general plus feature epics. Implementation is gated on a Claude Design task (DESIGN-E8). See [bucket-2-platform/MP-E8/decisions.md](bucket-2-platform/MP-E8/decisions.md), `baseline.md`, `options.md` and `questions.md`. MP-E8 has no tickets yet.
