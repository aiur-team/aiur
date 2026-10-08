---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-E6
bucket: 2-platform
base_main_sha: 45a290e3
date: 2026-10-06
blocked_by: DESIGN-E6 (owner), owner authorization of the paid validation spike (MP-E6-C1), MP-R5, MP-E7 (send path). MP-E2, MP-E3 and MP-E4 are optional ports (§2) and block only the chunks that use them (C5 Command tools on MP-E2; Executor target and full history on MP-E3/MP-E4) — Phase D, X-53
owns_contracts: contracts/voice-session.md (owner; §4 conversation provider, §5.3 drafts, §6, §9, §10)
consumes_contracts: listener mode (MP-E7), command request (MP-E2), conversations/transcripts (MP-E4), identity, capabilities (MP-R1), events (MP-R2)
research_resolved: MP-Q3 (see provider-research.md)
---

# MP-E6 — Independent conversational voice component — Plan

## Goal capsule

- **Objective:** a separately reusable **voice assistant** for fast back-and-forth discussion.
  It understands a brain dump, asks useful questions, clarifies intent and helps the operator
  formulate instructions. It talks *about* a worker's ticket or, with the Executor, about the
  project. It is not a coding model behind a microphone.
- **Hard rules:** D16 (explicit Converse choice, no default), D17 (no raw audio; full local
  transcripts, reviewable), V5 (nothing reaches an agent without a human Confirm).
- **Readiness:** provider chosen (MP-Q3). Implementation past C2 waits on the paid spike
  (C1) and DESIGN-E6.

## 1. Repository findings (extends baseline §E6)

| Area | Evidence at `45a290e3` |
| --- | --- |
| What "voice conversation" is today | `voice:conversation` topic (`voice_socket.ex:18`), half-duplex: stop → `requestSubmit` to the **worker** (`conversation-voice-controller.js:354-366`), watch for the next completed agent reply (`:379-396`), `speak` → `Aiur.ElevenLabs.TTS` streams `pcm_44100` back (`voice_channel.ex:118-144,169-182`; `tts.ex:13-17`). The voice conversation *is* the worker conversation. |
| No assistant | `grep convai\|conversational` finds nothing in `src/lib`, `packages/streamdeck/src`, docs (baseline §6). No persona, no pre-context, no separate transcript. |
| TTS limits | text ≤ 16,000 bytes, audio ≤ 8 MB, 60 s per reply (`tts.ex:15-17`) |
| Daemon-held provider sockets | `Aiur.ElevenLabs.Realtime` + `Realtime.MintTransport` keep the key in a header, never in state (`realtime.ex:14-35`). This is the pattern for the Agents websocket. |
| Sidecar voice seam | Provider-agnostic `stt.ts`/`tts.ts` contracts; the relay keeps the provider call in aiur (`packages/streamdeck/src/audio/stt.ts:1-15`). Unwired sidecar TTS needs an `apiKey` (`elevenlabs-tts.ts:48,56`) and must stay unwired (contract §4). Sidecar playback `createPacatPlayback` (`node-playback.ts:77`) is also unwired. |
| Context sources that exist | Worker transcript: `Aiur.LiveConversation` (80 messages / 64 KB, `live_conversation.ex`), `Aiur.AgentLog`, `Aiur.IssueLog`; status: `Aiur.Orchestrator.StatusReport` (`orchestrator/status_report.ex`); Commands: `Aiur.DecisionStore` reads; bus: `Aiur.Events.Exchange` (`events/exchange.ex`); agent bootstrap replay `agent_runner/bootstrap_digest.ex`. |
| Missing sources | Executor conversation (MP-E3, NEW). Full-history conversation read API (MP-E4). |
| Redaction | `Aiur.SecretRedactor.redact/1` (`secret_redactor.ex:49-50`) — shared pattern set |
| Durable-store precedent | `DecisionStore` append + fsync before notify; `Config.Paths.decision_state_dir/0` (`paths.ex:61-66`) |
| Dictation hint for agents | `.claude/skills/aiur-agent/dictated-input.md` (Aiur mis-transcriptions). The assistant's pre-context reuses this list. |
| Parked spec | `docs/voice-mode/spec.md` §3 "voice is a transport, not a separate agent". E6 is the brief's explicit exception: the assistant is a separate *conversational* agent, but it holds no Aiur write tools; all writes go through confirmed drafts, which keeps the spec's §18 safety rule ("mutating requests require explicit confirmation… button confirmation"). |

## 2. Proposed boundaries

```text
browser / phone / watch ──/voice socket, voice:converse──► VoiceConversation.Session (daemon)
                                                             │  ├─ ContextBuilder ──► read ports: conversation (E4), commands (E2),
                                                             │  │                     status, events (R2), executor (E3)
                                                             │  ├─ ToolRouter ─────► draft store; consult/instruct via E7; answers via E2
                                                             │  ├─ TranscriptStore ─► local ndjson (contract §9)
                                                             │  └─ ConversationProvider (behaviour)
                                                             │        └─ ElevenLabsAgents adapter ──wss──► ElevenLabs Agents (+ built-in LLM)
```

| Component (proposed) | Public interface | Required deps | Optional deps |
| --- | --- | --- | --- |
| `aiur_voice_conversation` (in-monorepo package; Elixir app or namespace per MP-R1) | `start_session(target, role_id, client)`, `end_session/1`, `confirm_draft/2`, `discard_draft/2`, `list_transcripts/1`, `get_transcript/1`; capability `voice.conversation` | ConversationProvider impl, TranscriptStore, read port for its target | E2 (Command tools), E3 (Executor target), E4 (history), R2 (live context updates) |
| `ConversationProvider` behaviour | contract §4 | — | — |
| `ElevenLabsAgents` adapter | implements the behaviour; owns signed-URL fetch, websocket, event normalisation | MP-R5 config/credential access | — |
| Role registry | `roles/0`, `role(id)` → `{id, title, prompt, hash}` | role files | — |
| Read ports | `ConversationRead`, `CommandRead`, `StatusRead`, `ExecutorRead` — thin behaviours the host app supplies | — | each port may be absent → that context is omitted and stated |

Independence: the package depends on behaviours, not on orchestrator modules. Without E2 it
has no Command tools; without E3 it cannot target the Executor; without E4 it uses the bounded
`LiveConversation` window; without R2 it refreshes context only on tool calls. Each absence is
reported in the session's `context` record and to the assistant ("Command data unavailable").

Prior mapping — `Prior-units: none` (new capability; it must not land inside U-owned files).
`Prior-boundaries: VOX #36` (voice package, extended), `WEB #34` (channel and UI), `DEC #27`
(read only). `Prior-features: ui-07, ui-08, integrations-51`. `Size-owner:` BROWSER for any
JS that touches the existing controller.

## 3. Alternatives and recommendation

| Decision | Options | Recommendation and reason |
| --- | --- | --- |
| Provider (MP-Q3) | ElevenLabs Agents; OpenAI Realtime; cascade on existing STT/TTS | **ElevenLabs Agents, built-in LLM, client tools, daemon-held websocket.** Reuses key/voice/account, gives turn-taking and barge-in, works with no public URL. Details and sources: [provider-research.md](provider-research.md). |
| Where the provider socket lives | browser (signed URL / WebRTC) vs daemon relay | **Daemon relay.** Keeps V4, lets the daemon execute tools and persist the transcript before the client sees it, and works for phone/watch unchanged. Cost: one extra hop of latency (RQ-E6-4). |
| Assistant's power | (a) direct write tools; (b) drafts + human Confirm | **(b).** "What becomes an instruction" must be explicit (brief E6); V5. |
| Consulting the real agent | (a) assistant reads only logs; (b) assistant can ask the agent a question | **(b) behind a rule** (§6): a consult is a framed question, visible in the agent transcript, sent through E7, and asynchronous. Owner decides whether it needs a confirm (E6-OQ2). |
| Context recovery | running summary vs retrieved transcript | **Retrieved transcript** (last session tail + open drafts) seeded at resume; an optional generated recap is derived and disposable, never a replacement (brief §3). |
| Agent provisioning | operator creates the agent by hand vs aiur creates it via API | **aiur creates/updates it** (`aiur voice setup`, `POST /v1/convai/agents/create`) with privacy and override settings fixed in code; operator may supply an existing `agent_id`, which the preflight still checks. |

## 4. Contracts

- **Owns:** [contracts/voice-session.md](../../contracts/voice-session.md) — whole document;
  §2/§3/§5.2/§7/§8 shared with MP-E5.
- **Consumes MP-E7 listener mode:** `send(conversation_ref, text, client_request_id, opts)` →
  `delivery_id` and receipts (voice-session §11). Consult and instruction drafts use the
  agent's configured mode (default sync, D13). `opts[:origin] = :voice_assistant` labels the
  entry in the agent transcript (accepted, E6 R-1); every surface shows a "via voice" tag.
- **Consumes MP-E2 command request:** read open Commands for the target; `answer` with
  `idempotency_key = draft_id`; a `resolved` event to mark drafts `stale`.
- **Consumes MP-E4 conversations:** read the last N messages and anchor positions for a
  worker/Executor session; assumption: a bounded "tail" read and a "since cursor" read exist.
- **Consumes MP-E3:** an Executor read port (status, recent conversation) and send target.
- **Consumes MP-R2 events:** subscribe to `ticket.<id>.*` and `executor.*` for live context.
- **Consumes capabilities (MP-R1):** publishes `voice.conversation`.

## 5. What context the assistant receives

Built by `ContextBuilder` at session start, redacted, size-budgeted (proposed default 8,000
tokens; RQ-E6-4), each block stamped with `observed_at`:

| Block | Worker-ticket session | Executor-project session |
| --- | --- | --- |
| Role pre-context | selected role file (E6-OQ3) + the dictated-input glossary | same |
| Target identity | ticket id, title, repo, current phase/state | instance, repo, Executor state |
| Work summary | ticket body excerpt; last 20 conversation messages | status snapshot: active agents, blockers, queue, build-order % |
| Open Commands | that ticket's open Commands (question, options) | all open Commands (count + top 5) |
| Recent events | last 10 milestones (PR, CI, phase) | last 10 fleet milestones |
| Prior voice sessions | tail of the last session with this target + open drafts | same |

Live updates during the session: new Command, agent reply to a consult, phase change, Command
resolved → `contextual_update` (non-interrupting). Every block sent is also written to the
transcript as a `context` record (contract §9), so a reviewer sees exactly what the assistant
knew.

## 6. Relationship to the real agent

| Question | Rule |
| --- | --- |
| Does the assistant talk to the agent? | Only through `consult_agent(question)`. The message is framed: *"Question from the operator's voice assistant. Answer briefly. This is not an instruction; do not change your plan."* It goes through E7 with `opts[:origin] = :voice_assistant`, appears in the agent transcript, and its reply returns as a context update. The assistant tells the operator it has asked and continues. |
| When does it consult? | Only when the operator asks it to, or after it proposes to and the operator agrees (E6-OQ2 decides whether a button is required). Never to fill silence. Max one outstanding consult per session. |
| What becomes an instruction? | Only a **draft** created by `propose_instruction` or `propose_command_answer` **and** confirmed by the operator (contract §5.3). |
| What stays discussion? | Everything else: every spoken turn, every assistant answer, discarded and unconfirmed drafts. Stored locally, never sent to the agent. |
| What if the target changes while a draft is open? | Command resolved elsewhere, agent ended, ticket closed → draft `stale`; confirm is refused with the reason; text stays copyable. |
| Can it pause, resume, spawn, merge? | No tools for that. Out of scope (brief §3 watch rule, E4 D15 write scope). |

Tools (client tools executed by the daemon; `expects_response: true`): `get_status`,
`read_recent_conversation(n)`, `list_open_commands`, `consult_agent(question)`,
`propose_instruction(text)`, `propose_command_answer(decision_id, option_id | custom_text)`,
`end_conversation`. Tool results are summaries; full payloads stay local.

## 7. Session lifecycle, turn-taking and activation

- Start: the operator picks **Converse** (D16) on a target's surface → join `voice:converse`
  with `{target, role_id}` → privacy preflight (agent `record_voice=false`, overrides enabled)
  → context built → provider session opened with the role prompt as an override.
- Turn-taking: provider VAD, interruptions **on** (barge-in), turn eagerness `Normal`, turn
  timeout 10 s (provider defaults are configurable; values are proposals for DESIGN-E6).
- End: End button, `end_conversation` tool, idle 120 s of silence, max 20 min (proposed, owner
  E6-OQ6), target gone, auth change. On end: flush transcript, `DELETE` the provider
  conversation, release the limiter lease.
- One target per session. Switching from a worker to the Executor ends one session and starts
  another (E6-OQ8).
- Resume later: the transcript list shows past sessions per target; "Continue" starts a new
  provider session seeded with the previous tail and open drafts (§5).

## 8. Non-happy paths

| Case | Behaviour |
| --- | --- |
| No key / package absent / provider not configured | `voice.conversation` unavailable with reason; Converse button absent or disabled (DESIGN-E5); dictation and typing unaffected. |
| Preflight finds `record_voice` true or overrides disabled | refuse with `privacy_preflight_failed`; `aiur voice setup --repair` fixes it. |
| Provider drops mid-session | state `reconnecting`, one retry with a new signed URL and the context re-seeded from the local transcript; then `error`. Transcript so far is already persisted. |
| Provider `DELETE` fails | record `provider_delete_failed` in the transcript and retry from a daemon queue; surfaced as an attention, not silently dropped. |
| Daemon restart, crash or OOM | live clients see `transport_lost`; transcripts intact (fsynced); at the next boot C6-T02 closes each unfinished transcript with `session_ended{daemon_restart}`, counts its minutes toward the daily cap, and enqueues the provider deletion from the recorded provider conversation id (Phase D, M1/M8). Undelivered drafts stay `proposed` and reappear on "Continue". |
| Consult reply never arrives | after 5 min the assistant says so; the consult record stays open in the transcript. |
| Duplicate confirm (two tabs, double tap) | `message_id`/`idempotency_key = draft_id` makes it idempotent. |
| Two devices converse on the same target | allowed; separate sessions and transcripts; drafts are per session. Both confirm → two distinct instructions (each was explicitly confirmed). |
| Conflicting Command answer | the E2 first-answer rule applies; draft goes `stale` with E2's reason. |
| Secrets in context | `SecretRedactor` before provider and before storage. |
| Cost runaway | max duration + per-day minute cap, **on by default** (proposed 60 min/day, owner choice E6-OQ6; Phase D, M8); crashed sessions count; limiter shares `VoiceSessionLimiter` caps. Ends with `cost_cap`, no retry offered. |
| Quota exhausted | `provider_quota`; session ends with the text transcript intact; distinct from `cost_cap` and `provider_error` on every client (voice-session §8.1). |

## 9. Acceptance criteria

1. Starting Converse requires an explicit button; no page load or notification opens a session.
2. A session's transcript file contains every user and assistant turn, every context block and
   every tool call before the client receives the matching event (test: kill the client after
   each event, file already has the record).
3. No audio bytes are written anywhere by aiur (test with a fake provider; filesystem spy).
4. The daemon refuses to start when the provider agent reports `record_voice: true` (adapter
   test with a fixture agent config).
5. After session end, the adapter issues `DELETE /v1/convai/conversations/{id}`; a failure is
   retried and recorded (fake HTTP).
6. A `propose_instruction` draft is not sent until `confirm_draft`; confirming twice sends once;
   a draft whose Command was resolved returns `target_stale`.
7. `consult_agent` produces exactly one E7 send with `opts[:origin] = :voice_assistant` and the framing
   text; its reply appears as a context update.
8. With E2 absent, Command tools are not offered and the context says "Command data
   unavailable" (mutation check: replace that branch with an empty list and the test fails).
9. The transcript review UI and `aiur voice transcripts` list and show full sessions; nothing
   offers to summarise-and-delete.
10. Docs: `website/docs-app/apis/elevenlabs.md` privacy table (contract §10), configuration
    reference entries for every new key, CLI reference for `aiur voice setup` / `transcripts`.

## 10. UX gate

[DESIGN-E6](../../owner-design-tasks/DESIGN-E6.md) blocks C7–C8 and every user-visible part of
C5. The mic choice itself is shared with [DESIGN-E5](../../owner-design-tasks/DESIGN-E5.md).

## 11. Decomposition

[chunks.md](chunks.md): C1 paid validation spike, C2 provider boundary and ElevenLabs adapter,
C3 provisioning, config and privacy preflight, C4 session manager and context builder, C5 tools
and drafts, C6 transcript store and review API/CLI, C7 dashboard conversation UI, C8 transcript
review UI and resume, C9 docs.

## 12. Open questions

**Owner (DESIGN-E6):** E6-OQ1 confirmation modality (button only vs speech); E6-OQ2 consult
needs confirm?; E6-OQ3 role pre-context authoring location and default roles; E6-OQ4 assistant
voice and name; E6-OQ5 may the user delete transcripts?; E6-OQ6 cost caps (session length,
daily minutes; Phase D proposal: daily cap 60 min, crashed sessions count); E6-OQ7 accept the cloud disclosure and choose the LLM; E6-OQ8 one target per
session; E6-OQ9 authorize the paid spike.

**Research (Phase C / spike):** RQ-E6-1..6 in [provider-research.md](provider-research.md) §6;
RQ-E6-7 the Phoenix channel frame budget for bidirectional PCM (400,000-byte max frame,
`endpoint.ex:27`) at 16 kHz in + 16 kHz out; RQ-E6-8 whether E4 exposes a tail/since read.

## 13. Plan refresh

- After **MP-R5**: the adapter lives in (or beside) the voice package; config keys move under
  the namespace RC-13 settled (`elevenlabs.*` for STT/TTS; `voice.conversation.*` for converse).
- After **MP-R1**: read ports are wired by the composition root R1 defines, not by direct calls.
- After **MP-E7**: the consult/instruction send uses the listener package API.
- After **MP-E3/E4**: Executor and full-history read ports become available; until then the
  Executor target is not offered and worker history uses `LiveConversation`.

## 14. Phase C resolutions (2026-10-06)

- Contract voice-session is draft-2: RC-13 (§12 config namespaces), RC-14 (§4 R5 names),
  RC-16 (§3.5 device path), §3.6 frame budget, §6 transition table, §7 MP-R1 capability IDs
  (`voice.conversation` replaces `voice.converse`).
- RQ-E6-7 and RQ-E6-8 resolved (see chunks.md Phase C). RQ-E6-1..6 remain with the spike.
- Websocket field names verified against
  <https://elevenlabs.io/docs/agents-platform/api-reference/agents-platform/websocket> and
  override paths (`conversation_config_override.agent.prompt.prompt`, `agent.first_message`,
  `tts.voice_id`) against the overrides page, both accessed 2026-10-06. The documented
  `user_transcript` event has no partial/final flag, which makes RQ-E6-6 a real question.
- Contract requests to MP-E7 (`origin` option), MP-E4, MP-E2, MP-R1, MP-R5:
  [tickets/CONTRACT-REQUESTS.md](tickets/CONTRACT-REQUESTS.md).

## 15. Phase D fix pass (2026-10-06)

- **M1 crash cleanup:** C4-T01 records the provider conversation id before `listening`; C6-T02
  reconciles unfinished sessions at boot (`daemon_restart`) and enqueues deletion; C2-T04 accepts
  the boot caller. Contract voice-session §6, §9.
- **M7 typed client errors:** voice-session §8.1 table (split file
  `contracts/voice-session-client-errors.md`), `cost_cap` one spelling,
  `Aiur.VoiceConversation.ClientErrors` (C4-T01).
- **M8 cap:** proposed default 60 min/day (C3-T01); crashed and open sessions count (C6-T02).
- **m2:** signed-URL lifetime documented (15 minutes); RQ-E6-1 narrowed (provider-research §2, C1-T01).
- **m5:** the adapter synthesizes `user_transcript.final` (C2-T03); `thinking` may be brief.
- **Security m4:** confirmation only from the client socket (V8, C5-T02); "via voice" tag.
- **X-26:** C5-T05 answers through `Aiur.Commands.Answering`.

## 16. Realtime conversation over a slow agent (2026-10-08)

Kevin, 2026-10-08 (verbatim, also at the top of the research file): "when i use voice mode with
heavier, higher effort agents, the convo is extremely slow and broken up. i love how chat
GPT's newest convo mode works … my fear is that if we separate the voice conversation agent
from the real aiur coding agent, it may only add additional latency while the convo agent asks
the coding agent and acts as a dumb relay." He proposed: click Converse → the coding agent
halts and dumps a full summary → the summary goes to the voice agent → the operator talks →
the voice agent answers from it and relays to the coding agent when needed.

Research: [realtime-convo-research.md](realtime-convo-research.md).

**New requirement (context handoff).** When Converse opens, the voice assistant must already
hold a current, agent-authored briefing of the target — what the agent is doing and why, next
steps, what it waits on, what it asks the operator, PR/CI/review state, open Commands, recent
milestones — so that it answers most questions in about one second **without stopping or
waiting for the coding agent**. The briefing is the **status card** (MP-E6-C10-T02) built from
the agent's **status note** (MP-E6-C10-T01) plus data aiur holds, and it is kept current by
deltas during the conversation. Halting the agent for a full briefing is available only as an
explicit "Pause and brief me" (MP-E6-C10-T04, E6-OQ12).

Changes:

- §3 provider: no longer final. The spike is a two-provider bake-off, **OpenAI GPT-Live 1**
  (ChatGPT Voice model, native delegation) vs ElevenLabs Agents (MP-E6-C1-T01 amendment,
  E6-OQ13).
- §5 context: the status card is the first block; start budget 4,000 tokens; raw message tail
  becomes `get_details` (C4-T03, C5-T01 amendments).
- §6 consult: `ask_agent`, non-blocking, delivered at the agent's checkpoint, spoken when it
  lands; a forked read-only side query answers "why" questions without disturbing the agent
  (C5-T04 amendment, C10-T03 spike, C10-T05).
- New chunk C10 (5 tickets); latency targets in research §7: answer-from-card ≤ 0.8 s median,
  Converse → listening ≤ 1 s.
- New owner questions E6-OQ12..OQ15 in DESIGN-E6 §3.1.
