---
ticket_id: MP-N5-C2-T00
feature_id: MP-N5
chunk_id: MP-N5-C2
bucket: 3-mobile-watch
title: Post-refactor path refresh for the notification policy
status: ready
blocked_by: [DESIGN-N5 (no-UI release), MP-N4-C3-T00, MP-R2-C5, MP-R2-C6, MP-E1-C7, MP-E2-C1-T3]
prior_units: [as landed by MP-R1]
prior_boundaries: [EXE #26, DEC #27, BO #30, new #41 candidate push-relay]
prior_features: [MP-R1, MP-R2, MP-E1, MP-E2]
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C2-T00 — Plan refresh

## Identity and outcome

Bucket 3, MP-N5, chunk C2. Documentation-only: map every pre-refactor symbol the N5
tickets cite to its post-refactor package and confirm the names that predecessor features
actually shipped (they are proposals today):

| Cited now | Confirm against |
| --- | --- |
| `Aiur.Events.Exchange.subscribe/2` (`src/lib/aiur/events/exchange.ex:70`, messages `{:event, event}` `:93-108`) | `event-bus` package (MP-R2) |
| `DurableConsumer.replay(after)` (MP-R2-C6-T04), `events.export.enabled` (MP-R2-C6-T01) | landed MP-R2-C6 |
| `Aiur.DecisionStore.list/1` (`decision_store.ex:393`), `get/2` (`:388`) | `commands` package |
| topics `ticket.<id>.agent.decision.human-needed`, `executor.decision.human-needed` (command contract §8; RC-08 wrote `ticket.<id>.decision.human-needed`) | MP-E2-C1-T3 as landed + MP-R2-C5 catalog |
| `Aiur.BuildQueue.progress/1` + progress-changed signal (RC-10) | MP-E1-C7 as landed |
| `src/lib/aiur/push/policy/**` (PROPOSED) | `push-relay` package path (MP-N4-C3-T00) |

## Dependencies and blockers

Listed in frontmatter; each predecessor must have landed (or been explicitly deferred).

## Verified starting point

As in the table (all `45a290e3`).

## Chosen design

Record the mapping in MP-N5 `plan.md` §10 and update each C2/C3 ticket's starting point.
A topic-name mismatch (the `.agent.` segment) is resolved by reading the MP-R2-C5 catalog
entry, not by guessing; CR-N5-3 asks the coordinator to fix the RC-08 spelling.

## Implementation steps

1. Read landed code; 2. edit tickets; 3. note deferrals (e.g. export journal off → live
mode only, C2-T01).

## Non-happy paths

A predecessor changed an interface shape → stop and file a CONTRACT-REQUEST.

## Compatibility and rollout

n/a — documentation.

## Verification

Reviewer checklist: every symbol in C2/C3 tickets resolves at the refresh SHA.

## Completion and handoff

- [ ] Mapping committed. Dependents: C2-T01..T04, C3-*.
