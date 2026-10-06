# Value and sequencing

The delivery order was settled by the operator on 2026-10-06 (decision D1 in [context-and-decisions.md](context-and-decisions.md)). It is ordered by day-to-day friction removed. The full ticket-level dependency graph is in `dependency-map.md`, written in Phase D.

## Delivery waves

| Wave | Features | User outcome | Why here |
| --- | --- | --- | --- |
| 0 | MP-E1 | The agent queue stays full without the Executor promoting each unblocked ticket. | Highest friction today: active agents drop from about 10 to a few. Ships before the refactor, on a seam (D2), so it is moved later, not rewritten. |
| 1 | MP-R1, MP-R2, MP-R7, then MP-R3–R6 | Independently reusable components; no user-visible change. The public component directory page publishes at the end of the wave. | Refactor before features (operator choice). R2 (bus) and R7 (harness adapters) are the substrates that E2, E3, E4 and E7 build on. R3–R6 are small, mostly confirmation and extraction. |
| 2 | MP-E2 | Blockers reach the right responder by authority; native agent questions become Commands; nothing is silently lost. | The blocker path is the core of "notice and steer". Every later surface (dashboard, voice, phone, watch) answers Commands. |
| 3 | MP-E7-C1–C3 (listener spec, mode store, send routing; flag keeps today's behaviour), then MP-E3, MP-E4 | Executor and worker conversations in the dashboard, with event jump points and message write access. | Removes the dependence on Claude Remote Control. N6's "open the conversation in context" reuses E4's anchors. |
| 4 | MP-E5, MP-E6, MP-E7-C4–C7 | Voice in the dashboard (dictate or converse), a conversational assistant, and steer, sync and async listener modes shared with Khala. | Voice reuses R5. E7 reuses R7 and fixes how a message lands in an agent, which every client's send path relies on. |
| 5 | MP-N1 → MP-N2 → MP-N3, MP-N4 → MP-N5, MP-N6 → MP-N7 | Phone and watch: paired machines, a meta-dashboard, encrypted push, and responding to blockers by tap or voice. | Mobile last (operator choice). It consumes the finished Command, conversation, voice and listener contracts, so it adds clients, not contracts. |

## Rejected orders and their consequences

- **Refactor first, then E1.** Delays the largest throughput win by the length of the refactor. Rejected (D2).
- **Mobile soon after the refactor.** The phone would ship against unfinished Command and conversation contracts, and either duplicate them or block on them. Rejected (D1).
- **Promote only up to free slots.** Duplicates the dispatcher's capacity logic inside the queue. Rejected (D4).

## What can run concurrently

- Inside wave 1: R3, R4, R5 and R6 are mostly independent of each other once R1's component map is fixed. R2 and R7 can run in parallel.
- Research and planning for every wave happens now. Parallel research does not mean the implementation tickets can run in parallel; each ticket names its predecessors.
- Every implementation ticket is blocked on its feature's `DESIGN-*` owner task (MP-REQ2). Pure refactor features still have a gate, which only confirms that no user-facing change is intended.

## Smallest prerequisite for each outcome

| Outcome | Smallest prerequisite set |
| --- | --- |
| Queue stays full | DESIGN-E1 + MP-E1 |
| Blocker reaches me reliably (dashboard) | MP-R2 event contract, MP-R7 adapters, DESIGN-E2, MP-E2 |
| Talk to the Executor without Remote Control | MP-R7, DESIGN-E3, MP-E3 |
| Answer a blocker from the phone | MP-E2, MP-E4 anchors, MP-N1, MP-N2, MP-N4, MP-N6, plus their design gates |
| Answer a blocker from the watch | Phone path + MP-N7 + DESIGN-N7 |

## Changes after Phase B

The listener-mode chunks E7-C1 to C3 moved into wave 3, because the E3/E4 send paths depend on them (decision D15). See [cross-feature-reviews/phase-b-reconciliation.md](cross-feature-reviews/phase-b-reconciliation.md) RC-05.
