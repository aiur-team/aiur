---
ticket_id: MP-R2-C4-T04
feature_id: MP-R2
chunk_id: MP-R2-C4
bucket: 1 (refactor; planning maintenance)
title: Refresh MP-R2 tickets and consumer citations after C1–C4 merge (with MP-R1-C11)
status: blocked
blocked_by: [DESIGN-R2 §1, MP-R2-C4-T03, MP-R1-C11-T1]
prior_units: [U0, U8]
prior_boundaries: [BUS #10]
prior_features: [MP-R1 (C11 plan refresh)]
prior_findings: [RC-23]
size_owner: n/a (docs)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C4-T04 — Plan refresh after packaging

## Identity and outcome

- **Bucket 1, MP-R2, chunk C4.** Planning maintenance, no production code.
- **Value.** C5–C7 and every consumer (MP-E1, E2, E4, E7, N3–N6) cite
  `45a290e3` line numbers and pre-seam call shapes (for example
  `GenServer.call(Aiur.Orchestrator, {:enqueue_event_digest, …})`,
  `Publisher.publish/3`, `IssueLog.record_event/3` from the bus). After
  C1–C4 those citations are wrong; a wrong doc is worse than a missing one
  (AGENTS.md).
- **Deliverable.** One docs PR on the research branch that updates:
  1. every not-yet-started MP-R2 ticket (C5-T*, C6-T*, C7-T*) "Verified
     starting point" to the merged head;
  2. plan.md §11 table "After refactor" column with the real outcome;
  3. consumer citations listed below;
  4. each touched ticket's `size_owner` against the then-current U8 ledger
     (RC-23).
- **Non-goals.** No change to decisions or designs; if refresh finds a
  design is now wrong, mark that ticket `blocked` with a named RQ and
  report it, do not redesign in this PR.

## Dependencies and blockers

- C4-T03 merged (the packaging is final).
- MP-R1-C11-T1 (path-map generator from `components.json` history). Since
  MP-R2 moved no files (RQ-8), the path map for the bus is identity; the
  refresh is mostly **symbol and line** changes, which the generator does
  not compute. Owner per MP-R1-C11: coordinator or Executor, not an agent
  alone.
- DESIGN-R2 §1.

## Verified starting point (45a290e3)

Citations that C1–C4 invalidate (grep targets on the research branch):

| Old citation | Becomes | Changed by |
| --- | --- | --- |
| `subscription_store.ex:594-610` orchestrator enqueue | `Aiur.Events.Delivery` + `Aiur.Orchestrator.EventDelivery` | C2-T01 |
| `sanitizer.ex:198-210` CodeOwners call | `Aiur.Events.TrustClassifier` over U5's authority | C2-T02 |
| `publisher.ex:355`, `subscription_store.ex:424,449` IssueLog writes | `Aiur.Events.HistoryStore.record/3` | C2-T03 |
| `publisher.ex:232,268`, `subscription_store.ex:425,450` DebugLog | `Aiur.Events.Trace.trace/3` | C2-T05 |
| `publisher.ex:188-246,405-504` gates | `Aiur.Events.SourcePolicy` + `Aiur.GitHub.EventSourcePolicy` | C2-T06 |
| `id_generator.ex:294-298,320-336` floor scan | `:floor_files` option, `Aiur.IdFloorSources` | C2-T07 |
| `Publisher.publish/3`, `Exchange.subscribe/1` as the public API | `Aiur.Events.publish/3`, `subscribe/1` | C2-T08..T10 |
| `executor_events.ex:63-75,416-452` journal code | `Aiur.Events.Journal`, `Aiur.Events.publish_journaled/3` | C3-T01, C3-T02 |
| "package `aiur_events`" | logical `event-bus` component in `components.json` | C4-T01 |

Files to sweep (research root): `contracts/events-and-replay.md` (owned by
MP-R2), `contracts/queue-readiness-and-build-progress.md`,
`contracts/command-request-and-resolution.md`, `contracts/listener-mode.md`,
`contracts/conversations-transcripts-anchors.md`,
`contracts/notification-destination-and-payload.md`,
`bucket-2-platform/MP-E1/plan.md` (`:440-441` cite `aiur_events` package
and C3/C5/C6), `MP-E7/chunks.md` (Delivery seam), `MP-E4/chunks.md` (history
read), `bucket-3-mobile-watch/MP-N4/chunks.md`, `MP-N3/plan.md`, and all
`tickets/` folders that cite `src/lib/aiur/events/*`.

## Chosen design

- Contracts owned by MP-R2 are edited directly; for contracts owned by
  others, write the corrections into
  `bucket-1-refactor/MP-R2/tickets/CONTRACT-REQUESTS.md` for the
  coordinator (Phase C rule: never edit a contract you do not own).
- Each refreshed ticket gets `base_sha: <merged head>` and a one-line
  "Refreshed <date> from 45a290e3" note; frontmatter `researched` keeps the
  original date.
- Re-run every citation with `git show <head>:<path>` and
  `git grep -n <pattern> <head>` (same method as Phase C).

## Implementation steps

1. `git grep -nE "events/(publisher|subscription_store|id_generator|sanitizer|debug_log)\.ex:[0-9]|executor_events\.ex:[0-9]|aiur_events" -- docs/research/aiur-mobile-and-platform`
   → work list.
2. Update MP-R2's own tickets C5–C7 and plan.md §11.
3. Update `contracts/events-and-replay.md` §4.1, §5, §7.1, §8 citations.
4. Write CONTRACT-REQUESTS entries for the other owners.
5. Re-read each edited ticket's "Verified starting point" against the head.

## Non-happy paths

- A consumer ticket already started on old citations: add a note to its
  PR thread rather than editing an in-flight ticket.
- A cited behaviour changed (not just moved): stop and raise it as a
  regression against the C2/C3 ticket that changed it.

## Compatibility and rollout

Docs only. n/a for config, migration and rollback beyond `git revert`.

## Verification

- Step 1's grep returns no stale hit in MP-R2-owned files.
- Spot check: 10 random refreshed citations resolve at the head with
  `git show <head>:<path> | sed -n '<a>,<b>p'`; record them in the PR body.
- No automated test (docs-only); no mutation check applies.

## Completion and handoff

- [ ] MP-R2 C5–C7 tickets and plan §11 refreshed; size owners re-checked.
- [ ] `events-and-replay.md` citations current.
- [ ] CONTRACT-REQUESTS lists every foreign-contract correction.
- Docs pages (`website/docs-app`): none; C4-T05 owns `message-bus.md`.
- Dependents: C5-T01 (first Bucket-2-enabling ticket starts from refreshed
  citations), MP-R1-C11-T2 (per-wave ticket sweep).
