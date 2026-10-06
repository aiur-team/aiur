---
feature_id: MP-E4
base_main_sha: 45a290e3
date: 2026-10-06
parent: plan.md
---

# MP-E4 chunks

Every implementation ticket is **blocked on DESIGN-E4** (MP-REQ2). C1–C3 and C8
are backend, but their entry kinds, body bounds and jump-point catalogue are
fixed by DESIGN-E4 decisions (OQ-E4-2/3/5), so they wait for it too. Phase C
fills `Prior-units`, `Prior-boundaries`, `Size-owner`, `Base-SHA` per ticket.

## MP-E4-C1 — Durable conversation journal and worker tee

**Outcome.** Every worker message is written once, with a durable position, to
an append-only journal that survives restart and workspace removal.

- **Deps:** contract §3–§6; identity (`instance_id`); event ids (exist).
- **Prior:** U4 (`agent_runner/`), U6 (projections). Boundaries RUN, PRJ.
- **Design.**
  - `Conversation.Journal` GenServer per conversation (Registry +
    DynamicSupervisor, the `SubscriptionStore` pattern, baseline R2).
  - `append(conversation_ref, session_ref, [entry_input])` is a cast; the writer
    batches (≤ 50 entries or 200 ms), assigns `pos`, fsyncs, then broadcasts
    `{:entries_appended, …}`.
  - Session lifecycle from the existing source data: `LiveConversation.Source`
    fields (`attempt_id`, `backend`, `session_id` = thread id;
    `live_conversation/source.ex:8-15`; `message_handler.ex:402-418`).
  - Tee added in `MessageHandler` closure (`message_handler.ex:52-63`) next to
    `maybe_observe_live_conversation`. Skip `assistant_delta`.
  - Entry `id` derivation matches `LiveConversation.Normalizer`
    (`normalizer.ex:138-145`) so both views agree on identity.
- **Tickets.**
  - MP-E4-C1-T1 Journal store: segments, `head.json` rebuild, permissions, append-only API.
  - MP-E4-C1-T2 Session records and boundary rules (spawn/resume/takeover/restart-unknown).
  - MP-E4-C1-T3 Worker tee in `MessageHandler`, non-blocking.
  - MP-E4-C1-T4 Body bounds (64 KiB, head/tail) and gap entries.
  - MP-E4-C1-T5 Config/docs: journal location in `website/docs-app/concepts/` (no new config key unless DESIGN-E4 asks for one; if added, `reference/configuration.md`).
- **Tests.** Restart: `head.json` deleted → rebuilt equal; duplicate input →
  one entry; blocked writer → closure returns (no sync I/O); remote-worker
  message → entry written; file modes 0600/0700; static check: no function
  rewrites or truncates a segment. Use temp dirs only (AGENTS.md "Reading real state").

## MP-E4-C2 — History API

**Outcome.** One read API for dashboard, JSON clients, Stream Deck and later phone.

- **Deps:** C1.
- **Design.** Contract §7: `list_entries` (`before|after|around|from_start|tail`,
  limit 1..200), `list_sessions`, `subscribe`. JSON routes
  `GET /api/v1/conversations/:conversation_id/{entries,sessions,anchors}` under
  `dashboard_auth`, placed before `/api/v1/:issue_identifier` (router ordering
  note, `router.ex:77-80`). Lookup helpers `conversation_id_for(worker
  identity | :executor)`.
- **Tickets.**
  - MP-E4-C2-T1 `Conversation.History` with cursor semantics.
  - MP-E4-C2-T2 PubSub subscription + catch-up helper.
  - MP-E4-C2-T3 JSON controller + router + `reference/` API docs.
- **Tests.** Property: random appends, random page walks both ways cover every
  `pos` exactly once; `around` centers; unknown conversation → 404 with reason;
  method catch-alls as existing routes do.

## MP-E4-C3 — Anchor resolver

**Outcome.** Events point to conversation positions with honest precision.

- **Deps:** C1; event history read (`IssueLog.event_history/2` today, MP-R2
  later); event-publication records (`tool_executor.ex:423-503`); Decision
  `source` (MP-E2).
- **Design.** Contract §10 ladder. Inputs: bus events for the subject's ticket
  (and `executor.*` for the Executor). `exact`: the daemon tees publication
  records (`tool_call_id`, `event_id`) to the resolver in memory (the per-launch
  file is not read back, per its moduledoc). `causal`: command entries matched
  by a small rule table (RQ-E4-2). `observed`: shared "last entry at or before"
  function, extracted from `StreamdeckLogs.assign_entries/2`
  (`streamdeck_logs.ex:306-338`), keeping its nil-timestamp rules.
  Anchors are append-only lines in `anchors.jsonl`; re-resolution only adds.
- **Tickets.**
  - MP-E4-C3-T1 Neutral `Conversation.Anchors.at_or_before/2` (extracted rule, same tests).
  - MP-E4-C3-T2 Exact anchoring from publication records.
  - MP-E4-C3-T3 Causal rules for push / PR create / PR merge commands.
  - MP-E4-C3-T4 Resolver process: subscribe to bus events, persist anchors, backfill on boot.
- **Tests.** Exact beats observed when both exist; nil timestamps never claim
  everything (existing guard); event before first session → `unanchored`;
  re-run resolver → no duplicate anchors (same `anchor_id`).

## MP-E4-C4 — Jump-point catalogue and Command links

**Outcome.** The jump points the brief names exist as labelled, filterable kinds.

- **Deps:** C3.
- **Design.** Extend `AgentEventFeed @topic_labels` (`agent_event_feed.ex:52-72`)
  through a shared catalogue: add `branch.push` ("Pushed <short sha>"),
  `executor.*` kinds, `decision.*` with Command id. Commands page links "Open in
  conversation" → `around: anchor.pos`; conversation shows a Command chip at its
  position.
- **Tickets.**
  - MP-E4-C4-T1 Catalogue module (topic → kind, label, default visibility per DESIGN-E4).
  - MP-E4-C4-T2 Command ↔ conversation links (both directions).
  - MP-E4-C4-T3 Push jump points with sha and PR link.
- **Tests.** Every topic in the contract §10 table maps to a kind; unknown topic
  → humanized label (existing fallback); Command link resolves for worker and
  Executor requesters.

## MP-E4-C5 — Dashboard conversation view

**Outcome.** The DESIGN-E4 view: full chronology, event navigation, sessions,
states, for workers and (via MP-E3) the Executor.

- **Deps:** C2, C4, **DESIGN-E4 approved**.
- **Design.** New `AiurWeb.ConversationLive` (or component) — not in
  `dashboard_live.ex`. Routes proposed: `/chat/:owner/:repository/:identifier`
  keeps opening the quick drawer (OQ-E4-6), plus a full view
  `/conversations/:conversation_id[?pos=N]`. Virtualized list; loads `tail`
  then pages; anchor jump loads `around`. Session dividers from `list_sessions`.
  State vocabulary reused from the drawer presenter.
- **Tickets.**
  - MP-E4-C5-T1 Route + LiveView skeleton + states (loading, empty, unavailable, stale, restart-unknown, read-only).
  - MP-E4-C5-T2 Entry rendering parity with the drawer (message, reasoning, command, tool, diff).
  - MP-E4-C5-T3 Event rail / list with filters and jump.
  - MP-E4-C5-T4 Live tail + "new entries below" behaviour.
  - MP-E4-C5-T5 Browser tests (desktop + phone width) and `website/docs-app/guide/` page.
- **Tests.** LiveView tests per state; browser test: jump to a merged-PR anchor
  highlights the anchored entry; unknown/stale branches mutation-guarded.

## MP-E4-C6 — Write surface

**Outcome.** From the conversation the operator can send a message and answer
that agent's open Commands; nothing else.

- **Deps:** C5; MP-E2 Command contract; MP-E7 (step 2).
- **Design.** Step 1: composer calls `AgentChat.send/3` for workers (existing
  behaviour, gated by `observability.dashboard_writable`). Step 2: switch to the
  E7 service and render receipts as a delivery overlay keyed by `delivery_id`
  until the journal shows the `operator_message`. Inline Command card for open
  Commands whose `source` is this subject, answering through the existing
  answer path with `expected_version`.
- **Tickets.**
  - MP-E4-C6-T1 Composer on `AgentChat` (workers), read-only gate.
  - MP-E4-C6-T2 Inline answer of this agent's open Commands.
  - MP-E4-C6-T3 Switch composer to MP-E7 + delivery overlay reconciliation (shared with MP-E3-C5).
- **Tests.** Read-only → no composer/answer; stale `expected_version` → conflict
  shown, not overwritten; overlay never says "delivered" on `outcome_unknown`;
  no UI action edits or hides entries.

## MP-E4-C7 — Stream Deck logs on the shared anchor rule

**Outcome.** One anchor rule for deck and dashboard; deck behaviour unchanged.

- **Deps:** C2, C3; **coordinate with MP-R6** (same files; one of the two owns
  the move).
- **Design.** `StreamdeckLogs.load/1` reads `History` (tail page) and the
  shared `at_or_before` rule; the key-face projection stays deck-specific.
- **Tickets.** MP-E4-C7-T1 swap data source and rule; T2 parity fixtures.
- **Tests.** Existing `streamdeck_logs_test.exs` passes unchanged.

## MP-E4-C8 — Import, retention and privacy

**Outcome.** Conversations that existed before the journal are visible as far
as data allows, honestly marked; retention and privacy are documented.

- **Deps:** C1.
- **Tickets.**
  - MP-E4-C8-T1 One-shot importer per active ticket: workspace `agent.ndjson` then current-launch IssueLog JSONL, as an `import` session after a `pre_journal` gap.
  - MP-E4-C8-T2 Docs: where transcripts live, that they are kept, that they may contain secrets, and how to delete by hand.
  - MP-E4-C8-T3 Measurement ticket for RQ-E4-1 (bytes/hour per agent on the live fleet) recorded in the PR body.
- **Tests.** Import twice → no duplicates; malformed lines skipped and counted.

## Dependency sketch

```text
E4-C1 ─► E4-C2 ─┬─────────────► E4-C5 (DESIGN-E4) ─► E4-C6 ─(E7)─► C6-T3
      └► E4-C3 ─┴► E4-C4 ──────┘
         E4-C3 ─► E4-C7 (with MP-R6)
E4-C1 ─► E4-C8
E4-C1 ─► MP-E3-C1 … (Executor uses the same journal)
```

C2, C3 and C8 can run in parallel after C1.
