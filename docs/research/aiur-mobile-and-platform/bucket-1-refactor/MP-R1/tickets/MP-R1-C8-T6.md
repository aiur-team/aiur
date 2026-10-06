---
ticket_id: MP-R1-C8-T6
feature_id: MP-R1
chunk_id: MP-R1-C8
bucket: 1-refactor
title: Conversations component — read facade (`Aiur.Conversations`) over transcripts, bus log and anchors
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C8-T5, MP-R6-C1 (neutral anchor module; ticket IDs per MP-R6 README), MP-R1-C1-T3]
prior_units: [U4, U6]
prior_boundaries: [PRJ #28, RUN #18, SD #35, WEB #34]
prior_features: []
prior_findings: []
size_owner: OPENCODE (live_conversation.ex 691, not edited), DECK_WEB (streamdeck_logs.ex 637; this ticket changes ≤4 lines) — U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T2
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C8-T6 — Conversations read facade

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C8 (steps S10/S12, path-map row PR-14).
- **User value:** none visible. One read entry point for conversation data, so MP-E4
  (dashboard conversations), MP-E3 (Executor conversation) and MP-N6 (phone "open in
  context") add their durable journal behind it instead of reaching into device-named
  or agent-runner modules.
- **Deliverable:** `Aiur.Conversations` (PROPOSED `src/lib/aiur/conversations.ex`), a
  read-only facade delegating to `Aiur.LiveConversation` (resolve/subscribe by opaque
  handle), `Aiur.AgentEventFeed` (`list/2`, `bus_events/2`), `Aiur.AgentLog`
  (`read_workspace/1`, `read/1`, `parse/1`, `workspace_log_path/1`), and the neutral
  anchor module created by MP-R6-C1 (provisional name `Aiur.Conversation.EventAnchors`).
  Web callers switched to the facade. Manifest entry `conversations` set.
- **Non-goals:** no new behaviour, no durable journal (MP-E4-C1), no anchor change
  (RC-06: R6-C1 extracts, E4-C3 extends; RC-07: E4 journal position is the address).
  This ticket does **not** re-extract anchoring or edit `StreamdeckLogs` beyond its
  two `AgentEventFeed` calls. No write API (D15 writes go through listener mode, MP-E7).

## Dependencies and blockers

- DESIGN-R1 §1.
- MP-R1-C8-T5 (sanitizer out of build-orders; otherwise `conversations` would inherit a
  required→optional edge through `live_conversation/normalizer.ex:4`).
- MP-R6-C1 merged (neutral anchor module exists). If R6-C1 has not merged at pickup,
  ship the facade without the `anchors` delegate and leave
  `streamdeck_live.ex`/`streamdeck_logs.ex` untouched; R6-C1's ticket then calls the
  facade. Either order is acceptable; the PR states which.
- Contract: `contracts/conversations-transcripts-anchors.md` (MP-E4 owner). Facade
  function names here are internal Elixir names, not the wire contract (§7 History API
  stays E4's).
- May run concurrently with C8-T1..T4, T7, T8.

## Verified starting point (45a290e3)

- Read call sites outside the conversation modules:
  - `aiur_web/live/dashboard_live.ex:2254,2260,2267` — `LiveConversation.subscribe_handle/1`,
    `unsubscribe_handle/1`, `resolve/1` (each behind an endpoint-config override, e.g.
    `:live_conversation_resolve_fun`).
  - `aiur_web/build_order/context_runtime.ex:285` — `LiveConversation.resolve/1` default.
  - `aiur_web/components/operator_control_center/agent_log_modal.ex:148,154,159,162` —
    `AgentLog.read/1`, `parse/1`, `read_workspace/1`, `workspace_log_path/1`.
  - `aiur_web/controllers/observability_api_controller.ex:39` — `AgentEventFeed.list/2`.
  - `aiur_web/live/streamdeck_live.ex:1461,1466` and `aiur_web/streamdeck_logs.ex:630,635` —
    `AgentEventFeed.list/2`, `bus_events/1`.
- Write call sites (stay as they are): `agent_runner/message_handler.ex:123,138,212,227,246,269,373`
  call `LiveConversation.observe*/activate/end_generation/mark_degraded`;
  `claude/display_tailer.ex:31` and `agent_runner/session_lifecycle.ex:7` build
  `LiveConversation.Source`; `orchestrator/lifecycle.ex:164` subscribes to restarts;
  `orchestrator/state.ex:651` validates handles.
- Outgoing deps: `agent_log.ex` → `Aiur.Jsonl`; `agent_event_feed.ex` → `Aiur.IssueLog`,
  `Aiur.Events.Publisher`; `live_conversation.ex` → `Aiur.Boot`, `Aiur.PubSub`;
  `live_conversation/normalizer.ex:4` → build-order sanitizer (cured by C8-T5).
- Child spec: `aiur.ex:422-425` (comment: "LiveConversation is projection-only").
- Tests: `src/test/aiur/live_conversation_test.exs`, `live_conversation_restart_test.exs`,
  `agent_event_feed_test.exs`, `agent_log_test.exs`,
  `src/test/aiur/orchestrator/live_conversation_runtime_test.exs`,
  `src/test/aiur_web/streamdeck_logs_test.exs` (R6's oracle; must pass unmodified),
  `src/test/aiur_web/live/dashboard_live_test.exs`.

## Chosen design

- **Placement decision (correction to component-map.md `conversations` paths):**
  `live_conversation*.ex` is the **write-side live store** fed by agent-runner
  (seven call sites above). Putting it in `conversations` (L3) would make agent-runner
  (L2) depend upward. It is therefore assigned to **`agent-runner`** as "live session
  evidence". `conversations` (L3) owns `agent_log.ex`, `agent_event_feed.ex`, the
  R6-C1 anchor module and the new facade, and reads the live store downward.
  Same rule for MP-E4-C1's durable journal: its writer must sit at or below
  agent-runner (contract request to MP-E4 owner).
- **Facade surface** (pure `defdelegate`):
  `live_resolve/1`, `live_subscribe/1`, `live_unsubscribe/1` (→ `LiveConversation.resolve/subscribe_handle/unsubscribe_handle`),
  `transcript/2` (→ `AgentEventFeed.list/2`), `bus_events/1,2`,
  `workspace_log/1` (→ `AgentLog.read_workspace/1`), `read_log/1`, `parse_log/1`,
  `workspace_log_path/1`, and `anchor/2`, `load_anchors/2` (→ R6-C1 module, if merged).
- Existing endpoint-config overrides in `dashboard_live.ex` keep working: only the
  default function captures change (`&Aiur.Conversations.live_resolve/1`).
- **Manifest:** `conversations` paths = `agent_log.ex`, `agent_event_feed.ex`,
  `conversations.ex`, R6-C1 module path; facades = `Aiur.Conversations`;
  requires = `agent-runner`, `event-bus`, `kernel`. `agent-runner` gains
  `live_conversation*.ex` with facade `Aiur.LiveConversation` and
  `Aiur.LiveConversation.Source` (handle validation is used by orchestration).

## Implementation steps

1. Add `src/lib/aiur/conversations.ex` (≈60 lines).
2. Switch the default captures/calls at the read sites listed (≈12 lines across 4–6 files).
3. Update `components.json` (both entries) and remove cured allowlist entries.
4. Record checker counts in the PR body.

## Non-happy paths

- **Unknown/expired handle:** `LiveConversation.resolve/1` returns its existing
  error (`:restart_unknown` after a BEAM restart, contract §4); the facade passes it
  through unchanged — never an empty transcript.
- **LiveConversation not running** (e.g. a future lean composition): the GenServer
  call exits as today; the facade adds no `catch`. The dashboard's existing handling
  stays the only handling.
- **Privacy:** no new read path; the same auth gates (dashboard basic auth, Stream
  Deck token) apply at the callers.

## Compatibility and rollout

No config, no data change. Revert is a plain revert.

## Verification

- Existing suites, unmodified:
  `env -C src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/live_conversation_test.exs test/aiur/live_conversation_restart_test.exs test/aiur/agent_event_feed_test.exs test/aiur/agent_log_test.exs test/aiur/orchestrator/live_conversation_runtime_test.exs test/aiur_web/streamdeck_logs_test.exs test/aiur_web/live/dashboard_live_test.exs`.
- New `src/test/aiur/conversations_test.exs`:
  `test "live_resolve/1 returns the store's error for an unknown handle, not an empty transcript"`
  — start `LiveConversation` under a test name, resolve a syntactically valid unknown
  handle, assert the same error term `LiveConversation.resolve/1` returns. Future-
  regression guard for the unknown branch (AGENTS.md); it passes on main via the
  delegate and is **not** counted as covering a behaviour change.
- Checker mutation: in a scratch branch, put `live_conversation.ex` back under
  `conversations` in the manifest → `check-components.py` reports seven agent-runner →
  conversations upward edges. This is the witness for the placement decision.
- `make -C src fmt-check lint`; `python3 scripts/check-components.py`.
- Manual (AGENTS.md): foreground `scripts/aiurdev --test`; open the dashboard
  conversation drawer for a running agent, the agent log modal, and
  `GET /api/v1/<id>/events`; capture before/after — identical.

## Completion and handoff

- [ ] Web read sites call `Aiur.Conversations`; no `AiurWeb.*` module is a conversation read source.
- [ ] `streamdeck_logs_test.exs` passes unmodified (R6 oracle).
- [ ] Manifest placement (live store → agent-runner) recorded; C11 refresh updates component-map.md.
- **Docs:** none (internal).
- **Dependents:** MP-E4-C1/C3 (journal and extended anchors plug in behind the facade),
  MP-E3 read chunks, MP-N6. Plan-refresh row PR-14 target becomes
  "`Aiur.Conversations` facade; live store stays in agent-runner".
