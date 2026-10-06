---
feature_id: MP-R2
doc: chunk decomposition
base_main_sha: 45a290e3
date: 2026-10-06
parent: plan.md
---

# MP-R2 chunks and candidate tickets

Every ticket below is blocked by **DESIGN-R2** (C1–C4 by §1, C5–C7 by §2) and
carries `Prior-units`, `Prior-boundaries`, `Size-owner`, `Base-SHA` fields per
the pack conventions. Every test added follows AGENTS.md "Tests must fail
without the production change they guard": revert the production hunk in a
clean worktree, see the test fail, restore, see it pass, and record the
command in the PR body. Characterization tests in C1 guard *existing*
behaviour, so they are named `*_characterization_test.exs` and say so in a
comment (they are deliberately green on `main`).

Size: every file touched that is already over 500 lines (`subscription_store.ex`
748, `publisher.ex` 539, `issue_log.ex` 1049, `executor_wake_inbox.ex` 619,
`executor_events.ex` 525, `streamdeck_channel.ex` 609) must not grow; the U8
size owner for `EVENTS` paths is cited per ticket.

## Dependency graph

```text
C1 ──► C2 ──► C4 ──► (MP-R1 package layout gate)
 │      └──► C5 ──┐
 └──► C3 ─────────┴──► C6 ──► C7
U3 event-delivery ticket ──► C2-T01        Identity contract ──► C5-T04
Signal port (#11, MP-R1) ──► C2-T08 (Alerts callers)    MP-N2 pairing ──► C7-T05
```

## MP-R2-C1 — Characterize today's bus (no production change)

- **Outcome.** A test suite that pins the current semantics the refactor must
  preserve, plus witnesses for the two source-reachable risks.
- **Depends on.** nothing (can start after DESIGN-R2 §1).
- **Tickets.**
  - `MP-R2-C1-T01` IssueLog persistence matrix: publish through `Publisher`
    with joinable vs unattributed observation, with and without a registered
    writer, for `ticket.N.agent.*`, `ticket.N.pr.merged`, `ticket.N.ci.failed`,
    `system.main.branch.push`; assert which reach `event_history/2` (settles RQ-1).
  - `MP-R2-C1-T02` Out-of-order id witness: two processes, ids 10 and 11
    reserved, 11 delivered first to a `SubscriptionStore` and to
    `ExecutorListener`; record whether 10 is dropped (RQ-2). Outcome is a
    finding handed to U3, not a fix.
  - `MP-R2-C1-T03` Wake gap witness: publish an allowlisted `ticket.N.pr.merged`
    while `ExecutorListener` is unbound, restart it, assert the wake is absent
    (documents F5).
  - `MP-R2-C1-T04` Supervision order and Exchange-crash re-bind test (plan
    AC4) in `src/test/aiur/application_test.exs` style.
  - `MP-R2-C1-T05` Placement-rule test (plan AC5): topic prefixes, and the
    allowlist of Exchange→PubSub bridges (`TicketActivity`,
    `TicketHistoryProvider`, `DecisionMetrics`, `DecisionStore`, `Alerts`).
  - `MP-R2-C1-T06` Boundary xref baseline: record today's outbound edges of the
    future `aiur_events` members (expected to include ORC, CodeOwners,
    IssueLog, PubSub) so C2/C4 can prove each removal.
- **Test strategy.** ExUnit with temp `runtime_state_dir`/`decision_state_dir`
  (never `~/.aiur`; AGENTS.md "Reading real state"), injected `IdGenerator`
  and `set_enqueue_fn/1`; no sleeps (use monitors and `:sys.get_state`).
- **Phase C questions.** RQ-1, RQ-2; exact injection points for T02 without
  adding production hooks.

## MP-R2-C2 — In-place seams (no moves, defaults equal today)

- **Outcome.** The bus members no longer call orchestrator, CodeOwners,
  IssueLog or PubSub directly; each is a behaviour with today's
  implementation as default.
- **Depends on.** C1 (all characterization green); `MP-R2-C2-T01` also on the
  U3 event-delivery ticket (`events-webhooks-executor-01`) to avoid a
  conflicting edit of `subscription_store.ex`; `C2-T08` on the signal port
  for the Alerts call sites (or it leaves Alerts callers for MP-R1).
- **Tickets.**
  - `MP-R2-C2-T01` `Aiur.Events.Delivery` behaviour; `SubscriptionStore`
    calls the configured sink; default adapter wraps
    `GenServer.call(Aiur.Orchestrator, {:enqueue_event_digest, id, event})`
    with identical timeout/error classification (`subscription_store.ex:494-498,594-610`).
  - `MP-R2-C2-T02` `Aiur.Events.TrustClassifier` behaviour; `Sanitizer`
    uses it; CodeOwners implementation registered by GHD; move
    `codeowners_refresh_seconds` documentation ownership.
  - `MP-R2-C2-T03` `Aiur.Events.HistoryStore` behaviour for
    `record_event/3` and `event_history/2`; Publisher, SubscriptionStore,
    BootstrapDigest, AgentEventFeed and TicketHistoryProvider call it;
    IssueLog is the default implementation (F1 semantics unchanged).
  - `MP-R2-C2-T04` Re-home `Orchestrator.EventTopics` and
    `Orchestrator.AutoSubscriptions` to the ORC boundary; remove any
    bus→ORC alias.
  - `MP-R2-C2-T05` Move `Events.BranchRefStore` to the ingestion boundary
    (ING #9).
  - `MP-R2-C2-T06` Resolve `Webhooks.EventSource` (RQ-6): delete if dead,
    otherwise route through `Publisher.publish/3`.
  - `MP-R2-C2-T07` `DebugLog` behind an optional debug sink so the bus core
    has no `Phoenix.PubSub` dependency; default sink keeps
    `aiur:events:debug[:<id>]` byte-identical.
  - `MP-R2-C2-T08` `Aiur.Events` facade (`publish/3`, `publish_persisted/4`,
    `subscribe/1`, `unsubscribe/1`, `bindings_for/1`); migrate callers in
    batches by area (events/, orchestrator/, agent_runner/, executor/,
    build_order/, web) — one PR per batch.
- **Test strategy.** C1 suite unchanged and green; per-behaviour unit tests
  with a fake implementation proving the bus calls only the behaviour
  (mutation: re-introduce the direct call → xref test fails).
- **Phase C questions.** Whether `HistoryStore` should also own `read_tail`
  (transcript) — recommended **no** (transcript belongs to MP-E4); batch
  boundaries for T08 against open PRs at implementation time.

## MP-R2-C3 — Journal and durable-consumer primitives

- **Outcome.** One reusable journal (prepare/append/replay with corrupt-tail
  detection) and a `DurableConsumer` that generalizes the ExecutorListener
  pattern (subscribe, replay from cursor, then live, dedupe by id/seq).
- **Depends on.** C1; MP-R1 kernel decision on where `DecisionLog` lives (RQ-3).
- **Tickets.**
  - `MP-R2-C3-T01` `Aiur.Events.Journal` over the existing `DecisionLog`
    primitive (no format change), used by `ExecutorEvents` journal append
    and replay.
  - `MP-R2-C3-T02` `Aiur.Events.publish_journaled/3` (reserve id → append →
    `publish_persisted`) extracted from `ExecutorEvents.publish/3`
    (`executor_events.ex:64-75`); ExecutorEvents stays in EXE and calls it.
  - `MP-R2-C3-T03` `Aiur.Events.DurableConsumer` module + behaviour with a
    fake-journal test suite (cursor persistence, crash between deliver and
    cursor write → at-least-once, corrupt tail → stop + alert). Not wired to
    ExecutorListener (behaviour preservation); first users are C6 and N4.
- **Test strategy.** Golden-file test: a journal written before T01 replays
  identically after; fault injection on fsync and partial line.
- **Phase C questions.** RQ-3; whether `ExecutorListener` should later adopt
  `DurableConsumer` (separate Bucket 2 ticket if it closes the F5 gap).

## MP-R2-C4 — Physical package and docs

- **Outcome.** `aiur_events` exists as the package boundary chosen by MP-R1,
  with config registration, a CI boundary gate and updated concept docs.
- **Depends on.** C2 (all), C3-T01/T02; MP-R1 package-layout decision (RQ-8);
  KTD3 evidence that the package is warranted.
- **Tickets.**
  - `MP-R2-C4-T01` Create the package, move members (plan §4.1), keep module
    names (no rename churn), keep supervision order.
  - `MP-R2-C4-T02` Register `events.*` config schema from the package;
    `scripts/check-config-docs.py` stays green.
  - `MP-R2-C4-T03` CI gate: xref test from C1-T06 inverted into an allowlist
    (plan AC1), run in the required lint job.
  - `MP-R2-C4-T04` Plan-refresh: rewrite paths in all MP-R2 tickets and in
    consumer plans that cite `src/lib/aiur/events/*` (plan §11).
  - `MP-R2-C4-T05` Docs: `website/docs-app/concepts/message-bus.md` adds the
    placement rule and durability classes (existing behaviour, no new UI).
- **Test strategy.** Full suite on the merge ref (memory: CI builds the merge
  ref); release build via `scripts/aiurdev build` and a manual `aiurdev --test`
  run proving agents still receive comment/CI digests and `executor-wait`
  still wakes (AGENTS.md manual-testing definition).
- **Phase C questions.** RQ-8.

## MP-R2-C5 — Topic catalog and external envelope (Bucket-2-enabling, inert)

- **Outcome.** A code-level catalog (class, export flag, allowlists,
  payload_version, owner) and a pure serializer to the external envelope v1.
  Nothing is exported yet.
- **Depends on.** C2-T08; Identity contract for `instance` (T04 only).
- **Tickets.**
  - `MP-R2-C5-T01` `Aiur.Events.Catalog` with entries for every topic in
    inventory §2 (class from contract §6); test fails if an exported topic
    lacks allowlists or if a published topic prefix is unknown.
  - `MP-R2-C5-T02` `Aiur.Events.Envelope.to_external/2`; property test: no
    output key outside the allowlist; `occurred_at: nil` preserved; atom and
    string payload keys both handled (`publisher.ex:298-304`).
  - `MP-R2-C5-T03` Reserve namespaces `ticket.<id>.queue.*`,
    `system.queue.*`, `system.build_order.<root>.*` in the catalog with owner
    features; note them in `message-bus.md`.
  - `MP-R2-C5-T04` `instance`/`machine` provider adapter (blocked on the
    Identity contract owner).
- **Test strategy.** Pure-function tests; catalog census test reads the
  producer list via `git grep`-equivalent fixtures, not the live log.
- **Phase C questions.** Final allowlists per topic (needs KQ-R2-3);
  whether `ticket.<id>.agent.custom.*` is ever exportable (recommended no).

## MP-R2-C6 — Export journal and durable consumer (disabled by default)

- **Outcome.** With `events.export.enabled: true`, a single exporter writes
  allowlisted envelopes with a dense `seq`, `gap` on boot, bounded
  retention, and a `DurableConsumer` that daemon-side features (N4/N5,
  optionally E1) use.
- **Depends on.** C3, C5; DESIGN-R2 S1/S4 answers.
- **Tickets.**
  - `MP-R2-C6-T01` Config keys `events.export.enabled` (false) and
    `events.export.retention` (KQ-R2-1) + configuration docs rows.
  - `MP-R2-C6-T02` Exporter process: binds catalog patterns before producers
    start (`:rest_for_one` placement like `aiur.ex:455-463`), assigns `seq`,
    appends via `Journal`, writes `gap(scope:"*")` on boot, corrupt tail →
    `events_unavailable` + one `needs_attention` alert.
  - `MP-R2-C6-T03` Retention trim keeping `seq` dense; `export.meta.json`
    (`epoch`, `oldest_seq`, `head_seq`); `epoch` changes only on journal
    re-creation.
  - `MP-R2-C6-T04` `DurableConsumer` over the export journal:
    `replay(after) → records | reset`, persisted cursor per named consumer.
  - `MP-R2-C6-T05` Mailbox alarm sized from RQ-4 census.
- **Test strategy.** Temp dirs; fault injection (kill exporter mid-append);
  restart test asserts exactly one `gap`; retention test asserts `reset`;
  disabled-mode test asserts no process/file (plan AC6).
- **Phase C questions.** RQ-4; whether `gap` scope can be narrowed per ticket
  (needs a producer-side signal; default `*`).

## MP-R2-C7 — External subscriber API

- **Outcome.** Authenticated, read-only pull and live access to the export
  feed, a catalog route, capability advertisement and (if approved) a CLI.
- **Depends on.** C6; Capabilities contract (MP-R1); DESIGN-R2 S2/S3;
  MP-N2 for T05.
- **Tickets.**
  - `MP-R2-C7-T01` `GET /api/v1/events` and `/api/v1/events/catalog` under
    `:dashboard_auth`, placed before the `:issue_identifier` routes
    (`router.ex:186-199`, RQ-7); 404 `feature_disabled` when off.
  - `MP-R2-C7-T02` `/events` socket and `events:feed` channel: token
    issuance reusing the `StreamdeckAuth` Phoenix.Token pattern
    (`router.ex:183`), join `{after}`, backlog then live, heartbeat 25 s,
    `reset`/`gap` records.
  - `MP-R2-C7-T03` Capability `events.export {v, retention}` in the
    Capabilities contract surface.
  - `MP-R2-C7-T04` `aiur events tail` and the `aiur status` line (only if
    KQ-R2-2/S3 approved) + `reference/cli.md`.
  - `MP-R2-C7-T05` Paired-device read scope (blocked on MP-N2 Pairing
    contract).
- **Test strategy.** Controller and channel tests with temp journals:
  resume returns exactly records after `seq`; stale cursor → one `reset`;
  unauthenticated → 401 with no body content; non-exported topic filter →
  422; manual `aiurdev --test` check of `aiur events tail` output.
- **Phase C questions.** RQ-7; token lifetime for long-lived mobile channels
  (coordinate with MP-N2).
