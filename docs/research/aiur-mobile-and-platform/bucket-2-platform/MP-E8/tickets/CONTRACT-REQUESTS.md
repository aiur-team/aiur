# MP-E8 contract requests (for the coordinator)

MP-E8 owns no shared contract. The items below touch documents and tickets that
other features own.

| # | Document or ticket (owner) | Request | Why |
| --- | --- | --- | --- |
| CR-E8-1 | MP-E1-C8-T01, MP-E1-C8-T02, `MP-E1/tickets/README.md`, DESIGN-E1 §4 (MP-E1) | Mark both tickets **superseded by MP-E8-C7-T01, the C9 board and C12-T07** (E8-D14). Remove them from E1's critical path and counts. | E8-D14 folds the view into MP-E8; no throwaway panel. |
| CR-E8-2 | MP-E7-C3-T03 (MP-E7) | Add the MP-E8 modal composer to the "unchanged callers (they go through `AgentChat.send/3`'s default)" list, next to the dashboard drawer. Its legacy-suite guard covers it. | E8's composer calls the same send helper as the drawer (MP-E8-C11-T06). |
| CR-E8-3 | MP-E4-C6-T01 (MP-E4) | Keep `AiurWeb.Conversation.DeliveryOverlay` a pure module that has no dependency on `ConversationLive`, so the E8 modal can use it (MP-E8-C14-T02), as MP-E3-C5-T01 does. | Reuse instead of a second overlay. |
| CR-E8-4 | DESIGN-E4 line 54 "Links in" (MP-E4) | Change "from the units table … build-order ticket context" to "from the MP-E8 ticket/agent modal ('Open in Conversations')". | Units and the Build Order modal retire (E8-D8). |
| CR-E8-5 | `contracts/queue-readiness-and-build-progress.md` §3 (MP-E1) | Confirm the read model carries, per item: hold actor and reason, promoted-at time, the failed prerequisite with the list of tickets it blocks, and queue position. If any is missing, add it. | The design shows "Held by Maya · release freeze until Thu", "promoted 6m ago", "Prereq #N failed · blocks #a #b" (J:853–858). |
| CR-E8-6 | MP-R1 `component-map.md` (MP-R1) | Place `Aiur.BuildOrder.History` and `Aiur.BuildOrder.Features` in `build-orders`; the home page in the build-orders web surface; and the edge build-orders page → dashboard-ui shared components (Units row, control policy, send helper, decision commands). | E8-D14: the refactor moves the page, it does not rewrite it. |
| CR-E8-7 | aiur-build label-family reconciliation test (MP-E1 F10 owner) | Accept the `feature:` family. | MP-E8-C6-T02. |
| CR-E8-8 | MP-E3 plan (MP-E3) | Record that the Executor conversation is not shown on the MP-E8 home page. DESIGN-E3 decides its own entry point. | Avoid two Executor chat surfaces. |
| CR-E8-9 | `dependency-graph.json`, `dependency-map.md`, `README.md` (coordinator) | Add the 76 MP-E8 nodes and their edges once the per-ticket docs exist; replace the README "MP-E8 has no tickets yet" note. | DESIGN-E8 acceptance step. |
