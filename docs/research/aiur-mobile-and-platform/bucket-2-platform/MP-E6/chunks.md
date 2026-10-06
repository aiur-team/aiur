---
feature_id: MP-E6
base_main_sha: 45a290e3
date: 2026-10-06
parent: plan.md
---

# MP-E6 — Chunks

Every ticket carries `Base-SHA: 45a290e3`, `Prior-units: none`, `Prior-boundaries: VOX` (+
`WEB` for channel/UI work, `DEC` for Command tools). **[gate]** = blocked on DESIGN-E6.
**[spike]** = blocked on MP-E6-C1 results.

## MP-E6-C1 — Paid provider validation spike (proposal; needs owner authorization)

- **Outcome:** a throwaway script (outside `src/`, not merged) proving the recommended
  provider shape and answering RQ-E6-1..6: daemon-side websocket with signed URL, client-tool
  round trip, `record_voice=false`, retention `0` and `DELETE` semantics, override prompt size
  and time-to-first-audio, partial transcripts. Output: a findings note with measured numbers.
- **Depends on:** E6-OQ9 (authorization; it spends agent minutes and LLM tokens on the owner's
  ElevenLabs account).
- **Tickets:** MP-E6-C1-T01 spike script + findings note; MP-E6-C1-T02 update
  `provider-research.md` and the contract with the answers.
- **Test strategy:** n/a (experiment). Record request/response shapes as fixtures for C2.

## MP-E6-C2 — Conversation provider boundary and ElevenLabs Agents adapter

- **Outcome:** `ConversationProvider` behaviour (contract §4), a fake provider for tests, and
  the `ElevenLabsAgents` adapter: fetch signed URL with the daemon key, open the websocket
  (reusing the `Realtime.MintTransport` approach), send `conversation_initiation_client_data`
  with overrides, relay `user_audio_chunk`, normalise server events, answer `client_tool_call`
  with `client_tool_result`, answer `ping`, close.
- **Depends on:** MP-R5 credential access (or in-core `Aiur.Config.elevenlabs_api_key/0`);
  C1 for T3.
- **Tickets:**
  - MP-E6-C2-T01 Behaviour, normalized event structs, fake provider.
  - MP-E6-C2-T02 Adapter connect/auth/close; signed URL never logged or stored (log redaction test).
  - MP-E6-C2-T03 **[spike]** Event mapping and tool round trip from C1 fixtures.
  - MP-E6-C2-T04 `DELETE /v1/convai/conversations/{id}` with a retry queue.
- **Tests:** fixture-driven adapter tests; property: no event name from the provider escapes
  the adapter; key/URL absent from every log line and crash reason.

## MP-E6-C3 — Provisioning, configuration and privacy preflight

- **Outcome:** config keys (namespace per MP-R5; proposed `voice.conversation.agent_id`,
  `.llm`, `.roles_dir`, `.max_session_seconds`, `.idle_timeout_seconds`, `.daily_minutes_cap`),
  `aiur voice setup [--repair]` creating/updating the provider agent with
  `record_voice=false`, shortest retention, overrides enabled for prompt/first message/voice;
  preflight `GET` of the agent before each session.
- **Depends on:** C2; DESIGN-R5 for key setup UX; E6-OQ6/OQ7 for defaults.
- **Tickets:**
  - MP-E6-C3-T01 Config schema + `.aiur/examples/config.example` + `scripts/check-config-docs.py`
    passing (configuration reference entries).
  - MP-E6-C3-T02 `aiur voice setup` CLI (CLI reference page).
  - MP-E6-C3-T03 Preflight with a short cache; `privacy_preflight_failed` refusal.
- **Tests:** schema tests; preflight refuses on a fixture with `record_voice: true`; mutation
  check on the refusal branch.

## MP-E6-C4 — Session manager and context builder

- **Outcome:** `VoiceConversation.Session` (one process per session, supervised), state machine
  contract §6, limiter lease, `ContextBuilder` with read ports, budget, redaction,
  `observed_at` stamps, live `contextual_update` from bus subscriptions, role registry.
- **Depends on:** C2, C6-T01 (transcript writes); read ports from MP-E2/E3/E4 (each optional).
- **Tickets:**
  - MP-E6-C4-T01 Session process and supervision; end reasons; idle and max-duration timers.
  - MP-E6-C4-T02 Read-port behaviours + host wiring for worker targets (LiveConversation,
    StatusReport, DecisionStore reads).
  - MP-E6-C4-T03 ContextBuilder: blocks from plan §5, token budget, SecretRedactor.
  - MP-E6-C4-T04 Role registry: role files, hash recorded per session (E6-OQ3 decides location).
  - MP-E6-C4-T05 Live context updates from `ticket.<id>.*` / `executor.*` (needs MP-R2 API).
  - MP-E6-C4-T06 Executor target wiring (needs MP-E3).
- **Tests:** context block present/absent per port; budget truncation keeps newest messages;
  redaction applied before both provider and store (fake provider records payloads).

## MP-E6-C5 — Tools and drafts

- **Outcome:** tool router for `get_status`, `read_recent_conversation`, `list_open_commands`,
  `consult_agent`, `propose_instruction`, `propose_command_answer`, `end_conversation`; draft
  lifecycle (contract §5.3); confirm/discard events; delivery through MP-E7 and MP-E2 with
  `draft_id` idempotency; stale detection.
- **Depends on:** C4; MP-E7 send with `source` tag; MP-E2 answer; E6-OQ1, E6-OQ2 for T3/T4.
- **Tickets:**
  - MP-E6-C5-T01 Read tools.
  - MP-E6-C5-T02 Draft store (in the transcript file; projection in session state).
  - MP-E6-C5-T03 **[gate]** Confirm/discard handling and delivery mirror.
  - MP-E6-C5-T04 **[gate]** `consult_agent` framing, one outstanding consult, reply capture.
  - MP-E6-C5-T05 `propose_command_answer` with version capture and stale detection.
- **Tests:** unconfirmed draft never calls the send port; double confirm sends once; Command
  resolved event marks the draft stale; consult send carries the framing and `source`.

## MP-E6-C6 — Transcript store, review API and CLI

- **Outcome:** contract §9 store (append + fsync before notify, root-contained path like
  `decision_state_dir/0`), `list/get` read API, `aiur voice transcripts [--target] [id]
  [--json]`.
- **Depends on:** none (can start first after C2-T01).
- **Tickets:**
  - MP-E6-C6-T01 Path resolution and append/fsync writer with torn-line recovery.
  - MP-E6-C6-T02 Index, boot reconciliation of unfinished sessions (Phase D M1), cap accounting incl. crashed sessions (M8), read API (pagination).
  - MP-E6-C6-T03 CLI command + CLI reference docs.
  - MP-E6-C6-T04 Deletion only if E6-OQ5 allows it (otherwise not built).
- **Tests:** crash between append and notify leaves a readable file; torn last line is
  skipped and reported; path traversal refused; tests use a temp state dir (AGENTS.md "reading
  real state").

## MP-E6-C7 — Dashboard conversation UI **[gate]**

- **Outcome:** the Converse panel opened from the D16 choice (MP-E5-C3): full-duplex audio
  relay over `voice:converse`, playback with barge-in stop on `interrupted`, echo-cancelled
  capture, live transcript, draft cards with Confirm/Edit/Discard, state display, End.
- **Depends on:** C4, C5, MP-E5-C1 (capture/transport modules), MP-E5-C3, DESIGN-E6, RQ-E6-5.
- **Tickets:**
  - MP-E6-C7-T01 Channel topic `voice:converse` and bidirectional relay (RQ-E6-7 frame budget).
  - MP-E6-C7-T02 Panel UI and states.
  - MP-E6-C7-T03 Draft cards and confirmation per E6-OQ1.
  - MP-E6-C7-T04 Playback queue with interruption.
- **Tests:** browser test with a fake provider: states, interruption stops playback, draft
  confirm sends once; no `getUserMedia` before the Converse click.

## MP-E6-C8 — Transcript review UI and resume **[gate]**

- **Outcome:** per-target list of past sessions, full transcript view (turns, context blocks,
  tool calls, drafts and their outcomes), "Continue" seeding a new session.
- **Depends on:** C6, C4; DESIGN-E6; MP-E4 for linking into the agent conversation anchor.
- **Tickets:** MP-E6-C8-T01 list and detail views; MP-E6-C8-T02 Continue/resume seeding;
  MP-E6-C8-T03 link a delivered draft to its position in the agent transcript (E4 anchor).
- **Tests:** a 2,000-turn transcript paginates; Continue includes open drafts in context.

## MP-E6-C9 — Docs and manual verification

- **Outcome:** `website/docs-app/apis/elevenlabs.md` (Agents permission, privacy table from
  contract §10), a concepts page section on the voice assistant's relationship to agents
  (edit an existing concepts page if one fits), configuration and CLI references; manual test
  via the AGENTS.md wrapper-tmux recipe for the agent side plus a real browser.
- **Depends on:** C3, C6, C7.

## Dependency summary

```text
C1 (owner-authorized spike) ─► C2-T03
C2-T01 ─► C6 ─┐
C2 ─► C3 ────┼─► C4 ─► C5 ─► C7 ─► C8 ─► C9
             │   (E2/E3/E4/R2 ports optional; E7 required for C5 sends)
DESIGN-E6 gates C5-T03/T04, C7, C8. DESIGN-E5 owns the mic choice used by C7.
```

## Phase C changes (2026-10-06)

Ticket docs: [tickets/README.md](tickets/README.md) (31 tickets, 14 ready, 17 blocked).

- **C1** is one ticket (old T1+T2): the paid spike with budget, steps and pass/fail
  criteria, blocked on E6-OQ9.
- **C3-T01 is blocked** on E6-OQ6/OQ7 (defaults are owner numbers); **C3-T03 is blocked** on
  the spike (retention semantics, RQ-E6-3) and now also owns the `voice.conversation`
  capability.
- **C2-T04** persists its retry queue and raises `Aiur.Alerts.emit_custom/3` on give-up.
- RQ-E6-7 resolved by calculation (voice-session §3.6); RQ-E6-8 resolved by the
  conversations contract §7 (`list_entries` `tail`/`after`, with the required `principal:`
  option: `:internal` for provider context, `{:device, id}` for anything shown on a device).
- Config namespace fixed by RC-13: `voice.conversation.*`; `elevenlabs.*` unchanged.
- C7-T01 serves `voice:converse` on both the dashboard socket and the MP-E5-C8 device socket.
