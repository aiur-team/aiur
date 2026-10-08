# MP-E6-ACC — MP-E6 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-E6-C4-T04, MP-E6-C4-T06, MP-E6-C5-T04, MP-E6-C6-T04, MP-E6-C8-T02, MP-E6-C8-T03, MP-E6-C9-T01

## Outcome

The Executor proves MP-E6 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-E6/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (31)

- MP-E6-C1-T01 — PAID spike — validate ElevenLabs Agents as the conversational voice provider (RQ-E6-1..6)
- MP-E6-C2-T01 — Conversation provider behaviour, normalized event structs and a fake provider
- MP-E6-C2-T02 — ElevenLabs Agents adapter — connect, authenticate, relay audio, close (daemon-held websocket)
- MP-E6-C2-T03 — ElevenLabs Agents event mapping and client-tool round trip, pinned to spike fixtures
- MP-E6-C2-T04 — Delete each provider conversation after the local transcript is durable, with a persistent retry queue
- MP-E6-C3-T01 — voice.conversation.* configuration schema, example and reference entries (RC-13)
- MP-E6-C3-T02 — aiur voice setup [--repair] creates or repairs the private ElevenLabs agent
- MP-E6-C3-T03 — Privacy preflight before every conversation and the voice.conversation capability
- MP-E6-C4-T01 — Conversation session process, supervision, state machine, limits and end reasons
- MP-E6-C4-T02 — Read-port behaviours and host wiring for worker targets
- MP-E6-C4-T03 — ContextBuilder — redacted, budgeted, time-stamped context blocks recorded in the transcript
- MP-E6-C4-T04 — Role registry for assistant pre-context, with a hash recorded per session
- MP-E6-C4-T05 — Live, non-interrupting context updates from the event bus during a conversation
- MP-E6-C4-T06 — Executor target — project-level conversations with the Executor read port
- MP-E6-C5-T01 — Read-only assistant tools — get_status, read_recent_conversation, list_open_commands, end_conversation
- MP-E6-C5-T02 — Draft store — propose_instruction and the draft lifecycle recorded in the transcript
- MP-E6-C5-T03 — Confirm and discard drafts; deliver instructions through the listener-mode send with draft_id idempotency
- MP-E6-C5-T04 — consult_agent — ask the real agent a framed, non-instruction question asynchronously
- MP-E6-C5-T05 — propose_command_answer — Command-answer drafts with version capture, stale detection and E2 delivery
- MP-E6-C6-T01 — Transcript store — state directory, append+fsync writer and torn-line recovery
- MP-E6-C6-T02 — Transcript index, boot reconciliation of unfinished sessions, cap accounting and list/get read API
- MP-E6-C6-T03 — aiur voice transcripts — list and show voice conversation transcripts from the CLI
- MP-E6-C6-T04 — Operator-initiated deletion of a whole voice conversation (only if E6-OQ5 allows it)
- MP-E6-C7-T01 — voice:converse channel — full-duplex audio relay between clients and the session
- MP-E6-C7-T02 — Converse panel component and its states
- MP-E6-C7-T03 — Draft cards with Confirm, Edit and Discard
- MP-E6-C7-T04 — Assistant audio playback queue with barge-in stop and echo-cancelled capture
- MP-E6-C8-T01 — Voice conversation history — per-target list and full transcript view
- MP-E6-C8-T02 — Continue a past conversation — seed a new session with the previous tail and open drafts
- MP-E6-C8-T03 — Link a delivered draft to its position in the agent conversation (E4 anchor)
- MP-E6-C9-T01 — Voice assistant docs (privacy disclosure, concepts, references) and end-to-end manual verification

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
