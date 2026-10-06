# Contract requests from MP-R1 chunks C6–C11

Written by the C6–C11 ticket researcher on 2026-10-06 (base `45a290e3`). These are
requests to the owner of each contract. The researcher did not edit any contract.
`contracts/identity-and-capabilities.md` is owned by MP-R1 part A (the C1–C5
researcher), per the assignment.

## CR-C6-1 — `run_shape` must separate the listener from the pages

- **Contract:** `contracts/identity-and-capabilities.md` §2.2 (capability report shape,
  v1). Owner: MP-R1 (part A).
- **Today:** `run_shape` has one boolean, `dashboard` (contract line 132).
- **Problem:** MP-R1-C6-T3 adds an internal run shape in which the HTTP listener and the
  JSON API are on but the LiveView pages are off (`dashboard_pages?`). One boolean
  cannot describe that shape. A client would read `dashboard: true` and offer page links
  that return 404.
- **Request:** add `run_shape.http_listener` (boolean) and `run_shape.dashboard_pages`
  (boolean). Keep `dashboard` as a deprecated alias of `http_listener` in v1, so v1
  clients still work. MP-R1-C3-T2 then reports `run_shape.dashboard_pages`.
- **Raised by:** MP-R1-C6-T3, and MP-R1-C6-T4 if DESIGN-R1 S4 approves an operator flag.

## CR-C8-1 — Conversations: journal writer layer and the in-daemon read facade

- **Contract:** `contracts/conversations-transcripts-anchors.md`. Owner: MP-E4.
- **Problem:** MP-R1-C8-T6 creates `Aiur.Conversations` (L3 read facade). The E4
  durable journal (RC-07: journal position is the anchor address) is written from
  agent-runner call sites. If the writer lives in the L3 `conversations` component,
  agent-runner (L2) gets an upward edge, which the R-down rule forbids.
- **Request:** state that the journal **writer** sits at or below agent-runner (L2), or
  behind a sink port that agent-runner calls and conversations implements; and name
  `Aiur.Conversations` as the in-daemon read facade that every surface uses.
- **Raised by:** MP-R1-C8-T6.

## CR-C8-2 — Events: record `Aiur.ObservabilityPubSub` as internal invalidation

- **Contract:** `contracts/events-and-replay.md`. Owner: MP-R2.
- **Problem:** MP-R1-C8-T4 moves `Aiur.ObservabilityPubSub` out of the web namespace
  into the core. MP-Q5 says PubSub carries internal invalidation only, but the contract
  does not list this topic, so its ownership is unstated.
- **Request:** list `Aiur.ObservabilityPubSub` as an internal-invalidation PubSub topic
  owned by `event-bus`, never exported. Live bug #3009 (`CurrentRunProjections` ignores
  the broadcast) must be fixed first or explicitly deferred (C8-T4 blocker).
- **Raised by:** MP-R1-C8-T4.

## CR-C8-3 — Command answer delivery is synchronous (correction for MP-E2 and MP-R1 plan)

- **Contract:** `contracts/command-request-and-resolution.md`. Owner: MP-E2.
- **Finding:** the event `ticket.<id>.agent.decision.answered` already exists and only
  wakes the orchestrator (`src/lib/aiur/orchestrator/event_topics.ex:31-36,174,181-186`, subscribed in `orchestrator/lifecycle.ex:40`, at `45a290e3`). The
  answer text goes through an outbox that needs a synchronous result
  (`src/lib/aiur/decision_store.ex:3827-3870`, `maybe_start_dispatch/4`). So "answer delivery by event" (MP-R1
  plan §5 and component-map §3 `commands` row) is not behaviour-preserving.
- **Request:** the contract states that delivery stays a synchronous call through a
  delivery-target port that orchestration implements (MP-R1-C8-T2); the event is a
  wake-up signal only. Also: `commands` is **required**, not optional, because the
  dispatch gate fails closed when the store is unreadable
  (`src/lib/aiur/orchestrator/dispatcher.ex:480-491`, `refresh_blocked_ticket_ids/1`). Open question RQ-C8-1 (whether
  "not installed" should leave dispatch open) is for MP-E2 and DESIGN-R1.
- **Raised by:** MP-R1-C8-T1, C8-T2.
