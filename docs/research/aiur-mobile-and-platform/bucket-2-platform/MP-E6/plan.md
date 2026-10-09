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
amended: 2026-10-09 (§17 independent package; read-only fork per harness)
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

**2026-10-09: superseded in part by §17.** The core is the standalone package `voice_converse` (no aiur dependency). The read ports below become the host ports `BriefingSource`, `AgentChannel`, `CommandSource` and `Credentials`. aiur is one host.

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

## 17. Independent package (2026-10-09)

Kevin, 2026-10-09 (verbatim): "I also want to make sure that we're planning to build this in
such a way that it's its own independent package that can be used separately from [aiur]."
Later the same day (verbatim): "I like the idea of not stopping the agent and forking it when
it needs additional context. Let's make sure that we have the fork feature wrapper model
specific so that we use the native fork for both Claude and Codex if they have those features
as well as other models."

This uses the same pattern as the GitHub access layer
([MP-R1 github-access](../../bucket-1-refactor/MP-R1/github-access/brainstorm.md)) and the
Experiments component (`docs/research/experiments/requirements.md`): a core package with no
host types, host adapters, an MP-R1 manifest entry, and the MP-R1 promotion test.
Nothing in MP-E6 is implemented or promoted, so this section changes the plan before any code
exists. Where §2–§16 name `Aiur.VoiceConversation.*` modules, §17.9 gives the new home.

### 17.1 Gaps in §1–§16 (verified against this plan and the tickets)

| # | Gap | Where | Fix |
| --- | --- | --- | --- |
| G1 | The target was "in-monorepo package; Elixir app or namespace per MP-R1". Nothing could be used without aiur. | §2 table, component-map `voice-conversation` row | A core Mix project with its own OTP app, born as a package (§17.2). |
| G2 | The only transport was aiur's `/voice` Phoenix socket (`voice:converse`) in the daemon. | §2 diagram, C7-T01 | The core has a transport-neutral session API and a wire codec. `/voice` is one adapter. A local WebSock transport is another (§17.5). |
| G3 | Credentials and settings came from aiur config (`Aiur.Config.elevenlabs_api_key/0`, `voice.conversation.*`, MP-R5 facade). | C2-T02, C3-T01, C4-T01 | A `Credentials` port and a `VoiceConverse.Config` struct that the host passes in. aiur maps its keys into the struct (§17.6). |
| G4 | The briefing (status card, status note) and the read ports used aiur words: ticket, worker, Executor, Command, `StatusReport`, `DecisionStore`, `LiveConversation`. `ask_agent`/consult and instructions went straight to aiur's E7 `Aiur.Listener.send/3`. | §5, §6, C4-T02, C5-T03/T04, C10-T02 | A generic `Briefing` and host ports `BriefingSource`, `AgentChannel` and `CommandSource`. The aiur status card, E7 and E2 are one implementation each (§17.4). |
| G5 | The transcript root was `Aiur.Config.Paths.decision_state_dir/0`; redaction was `Aiur.SecretRedactor`; give-up alerts used `Aiur.Alerts.emit_custom/3`; session children were started from `src/lib/aiur.ex`. | C6-T01, C4-T03, C2-T04, C4-T01 | An injectable `transcript_root`, a redactor hook, `:telemetry` events, and `VoiceConverse.child_spec/1` (§17.3). |
| G6 | The side query (C10-T03/T05) was specified for Claude only (`claude -p --resume --fork-session`), and only inside the voice code. | C10-T03, C10-T05 | A per-harness `fork_session` capability in the MP-R7 harness layer, with a native fork where one exists and a read-only replay where it does not (§17.7). |

### 17.2 Package shape and where it lives

```text
packages/elixir/voice_converse/            (new Mix project, OTP app :voice_converse; Hex name: E6-OQ18)
  lib/voice_converse.ex                    session API (start/push_audio/send_text/confirm/discard/end/subscribe)
  lib/voice_converse/config.ex             %VoiceConverse.Config{}  (validated struct, no global config)
  lib/voice_converse/ports/*.ex            BriefingSource, AgentChannel, CommandSource, Credentials (behaviours)
  lib/voice_converse/session*.ex           state machine (voice-session §6), timers, limits, persist-before-notify
  lib/voice_converse/turns.ex              turn-taking policy (barge-in, eagerness, announce at pause)
  lib/voice_converse/briefing.ex           %Briefing{} + render/2 + diff/2 + staleness (generic "status card")
  lib/voice_converse/context_builder.ex    budgeted, redacted, time-stamped context blocks
  lib/voice_converse/tools.ex              tool specs + router (get_status, get_details, ask_agent, propose_*, end)
  lib/voice_converse/drafts.ex             draft lifecycle (voice-session §5.3); the confirm rule lives here
  lib/voice_converse/transcript_store*.ex  ndjson writer, fsync, torn-tail recovery, index, minutes_today
  lib/voice_converse/provider.ex           behaviour (former C2-T01) + events
  lib/voice_converse/provider/eleven_labs_agents*.ex   adapter, preflight, provisioning, DELETE queue
  lib/voice_converse/provider/openai_realtime*.ex      adapter (GPT-Live 1 / Realtime)
  lib/voice_converse/wire.ex               transport-neutral frame codec (voice-session §3.3 converse frames)
  lib/voice_converse/transport/websock.ex  optional local transport (compiled only with :websock_adapter)
  lib/voice_converse/redact.ex             default redactor (bearer tokens, sk-/ghp_/xi- style keys, URLs with credentials)
  lib/voice_converse/testing/*.ex          FakeProvider, FakeBriefingSource, FakeAgentChannel (shipped, so hosts can test)
  lib/mix/tasks/voice_converse.{setup,transcripts}.ex
  priv/static/voice_converse_client.js     small browser client for the wire protocol (capture, playback, drafts)
  examples/local_host/                     standalone example host (separate Mix project, path dep "../..")
  guides/*.md, README.md, CHANGELOG.md, LICENSE

src/lib/aiur/voice_converse/host/*.ex      aiur adapter layer (thin; §17.8)
src/lib/aiur_web/channels/voice_converse_channel.ex   /voice transport adapter (C7-T01)
```

Decisions and reasons:

- **Born as a package, not promoted later.** The MP-R1 promotion test (migration-plan §5)
  is for code that already lives in `src/` and must prove it can leave. This code does not
  exist yet. Building it inside `src/` and moving it later costs a move and allows aiur
  calls to leak in. MP-R1-KD4 already takes the same route for the mobile app ("a separate
  package from day one … not promoted because it never lived in `src/`"). We use the
  physical form that migration-plan §5 fixes: an in-repo Mix project under
  `packages/elixir/<app>/`, a path dependency of `src/mix.exs`, and one `mix release` boot.
  If MP-R7-C4-T03 has not yet created `packages/elixir/`, MP-E6-C11-T01 creates it the same way.
- **Neutral namespace `VoiceConverse.*`, not `Aiur.*`.** No caller exists, so a neutral name
  costs nothing now and saves a rename at publish time. github-access deferred its rename
  because it has many callers today. The name is E6-OQ18.
- **Elixir, not a TypeScript package.** The provider socket must stay out of the client, with
  the key held server-side (§3 "daemon relay", V4). aiur's daemon is Elixir. The browser part
  is one small JS file shipped in `priv/` that speaks the wire protocol. It needs no npm
  package until a non-browser JS consumer exists (E6-OQ16).
- **The core has no aiur dependency, and two checks enforce it.** (1) A CI job compiles and
  tests `packages/elixir/voice_converse` with only its own `mix.exs` deps (`mint`,
  `mint_web_socket`, `jason`, `telemetry`; optional `websock_adapter`/`bandit` for the local
  transport). `src/` is not on the code path. (2) The same job runs
  `git grep -nE '\bAiur(Web)?\.' packages/elixir/voice_converse/lib` and fails on any match.
  The MP-R1 checker sees the package as component `voice-conversation-core` with an empty
  `requires` list (§17.10).
- **Shared helpers are copied, not imported.** The core carries its own small fsync and
  torn-tail code (about 60 lines, the `Aiur.DecisionLog` pattern) and its own default
  redactor, instead of calling `Aiur.Fs`/`Aiur.SecretRedactor`. A dependency on an aiur
  utility package would make the core unusable alone. The aiur host passes its stronger
  redactor through the hook.

### 17.3 Core (host-agnostic) — what it owns

| Concern | In the core | Host supplies |
| --- | --- | --- |
| Session state machine | voice-session §6 states, end reasons, idle/max/daily-cap timers, reconnect once, `ClientErrors` table | limits in `Config` |
| Turn-taking | barge-in on, eagerness, turn timeout, `announce(text, when: :idle \| :now)` for late results (C2-T01 amendment) | nothing (defaults in `Config.turn`) |
| Providers | behaviour + ElevenLabs Agents + OpenAI Realtime/GPT-Live adapters, preflight (`record_voice=false`, retention), provisioning, provider `DELETE` queue (persisted under `transcript_root`) | `Credentials` |
| Context | `ContextBuilder`: briefing first, 4,000-token start budget, `observed_at` stamps, gaps line per missing port | `BriefingSource`, optional `CommandSource` |
| Tools | `get_status`, `get_details(section)`, `list_open_commands` (only if `CommandSource`), `ask_agent`, `propose_instruction`, `propose_command_answer` (only if `CommandSource`), `end_conversation` | ports |
| Drafts | draft lifecycle, `draft_id` idempotency, stale detection, **the confirm rule** (§17.11) | delivery via `AgentChannel`/`CommandSource` |
| Transcript | ndjson store with injectable `transcript_root`, fsync before notify, torn-tail recovery, index, `minutes_today/1`, read API | `transcript_root` (default `./voice_converse_transcripts` only in the example host; required in `Config`) |
| Redaction | hook `redactor :: (String.t() -> String.t())`, applied before the provider and before the store; default `VoiceConverse.Redact` | aiur passes `&Aiur.SecretRedactor.redact/1` composed with `redact_urls/1` |
| Roles | `Config.roles` (list of `%{id, title, prompt}`) or `roles_dir`; hash recorded per session; `Config.glossary` appended | aiur: roles dir + `.claude/skills/aiur-agent/dictated-input.md` |
| Signals | `:telemetry` events `[:voice_converse, :session, :start \| :stop]`, `[:voice_converse, :provider_cleanup, :give_up]`, `[:voice_converse, :cost_cap, :reached]`, `[:voice_converse, :tool, :stop]` with durations | aiur maps give-up to `Aiur.Alerts.emit_custom/3` |
| Supervision | `VoiceConverse.child_spec(config)` starts one named instance (session supervisor, registry, cleanup queue, preflight cache) | the host adds it to its tree (MP-R1 promotion criterion 2) |
| Availability | `VoiceConverse.availability(config) :: :ok \| {:unavailable, reason}` | aiur turns it into capability `voice.conversation` |

### 17.4 Host ports

All ports are behaviours named in `Config`. Each call has a deadline. A timeout, an exit or
`{:error, _}` becomes a stated gap ("Briefing unavailable"), never an empty value that looks
like "idle" or "nothing open". This is the C4-T02 rule, now in the core. A target is an opaque
host term with `%{id, kind, title}` from `describe_target/1`. The core never branches on `kind`.
Worker and Executor are two aiur kinds.

| Port | Required? | Callbacks (sketch) | Latency budget | aiur implementation |
| --- | --- | --- | --- | --- |
| `BriefingSource` | yes | `describe_target(t)`; `brief(t) :: {:ok, %Briefing{}} \| {:error, :unavailable}`; `details(t, section, opts) :: {:ok, text}`; `sections(t) :: [%{id, description}]` (builds the `get_details` schema); `subscribe(t, pid) :: :ok \| :unsupported` → `{:briefing, t, %Briefing{}}`; `alive?(t) :: boolean \| :unknown` | `brief` ≤ 100 ms p95 (serve a cached briefing); `details` ≤ 300 ms | status card fields from the agent status note (C10-T01), `StatusReport`, PR/CI, milestones, E4/`LiveConversation` for `details("conversation")` |
| `AgentChannel` | no (absent → no `ask_agent`, no instruction drafts, stated) | `ask(t, question, ref, opts) :: {:ok, delivery_id}`; `instruct(t, text, idempotency_key, opts) :: {:ok, delivery_id}`; `fork_query(t, question, opts) :: {:ok, ref} \| {:error, :unsupported}` (§17.7); optional `request_briefing(t, :refresh \| :pause)` (C10-T04); `subscribe(t, pid)` → `{:agent_reply, ref, text}`, `{:receipt, delivery_id, :accepted \| :delivered \| :failed \| :unknown}`, `{:fork_answer, ref, text}`; `capabilities(t) :: %{fork: :native \| :history_copy \| :replay \| :none, …}` | `ask`/`instruct`/`fork_query` return ≤ 300 ms (asynchronous; answers arrive as messages) | E7 `Aiur.Listener.send/3` with `origin: :voice_assistant`, `:checkpoint` delivery; receipts mapped from listener-mode; `fork_query` via MP-R7 `fork_session` (§17.7) |
| `CommandSource` | no | `open(t) :: {:ok, [%{id, version, question, options}]}`; `answer(t, id, choice, idempotency_key) :: :ok \| {:error, :stale \| term}`; `subscribe(t, pid)` → `{:command_resolved, id, reason}` | ≤ 300 ms | E2 `DecisionStore` reads + `Aiur.Commands.Answering` |
| `Credentials` | yes | `fetch(provider :: atom, purpose :: :connect \| :provision \| :delete) :: {:ok, secret} \| {:error, :missing}`. Called at the moment of use; the secret is never kept in process state or logs (the `Realtime` precedent). | ≤ 50 ms | MP-R5 voice facade (`elevenlabs.api_key`), an OpenAI key from aiur config or env |
| Transport | — (a client of the session API, not a callback port) | uses `VoiceConverse.start_session/3`, `push_audio/2`, `send_text/2`, `confirm_draft/3`, `discard_draft/2`, `end_session/2`, `subscribe/1`; frames via `VoiceConverse.Wire` | one in-process hop | `/voice` channel `voice:converse` (C7-T01); standalone: `VoiceConverse.Transport.WebSock` |

**Generic `Briefing`** (the status card becomes one producer of it):

```elixir
%VoiceConverse.Briefing{
  version: pos_integer(),            # monotonic per target; diff/2 sends only changed lines
  summary: field(String.t()),        # what is going on, 1–3 sentences
  current_task: field(String.t()),   # doing now, and why
  next_steps: field([String.t()]),
  waiting_on: field(String.t()),     # CI, review, a person, nothing
  questions: field([String.t()]),    # what the agent asks the operator ("asks" in C10-T01)
  links: [%{label: String.t(), url: String.t()}],
  extra: [%{title: String.t(), text: String.t(), observed_at: DateTime.t()}],  # host-specific, e.g. PR/CI line
  gaps: [String.t()]                 # e.g. "no note from the agent yet"
}
# field(x) :: %{value: x, observed_at: DateTime.t(), max_age_s: pos_integer() | nil}
```

`Briefing.render/2` (≤ 1,500 tokens; drop order: extra, then links, then `next_steps` beyond 3;
it never drops `current_task`, `waiting_on` or `questions`). `Briefing.diff/2` produces the
changed lines for one non-interrupting `contextual_update`. A field past `max_age_s` is
rendered as "(as of 12 min ago)". All three are core code with core tests. aiur only fills
the fields (C10-T02 amendment).

### 17.5 Transports

- **Session API (core).** It is transport-neutral. Events reach the subscriber as
  `{:voice_converse, conversation_id, event}`. Audio crosses as base64 PCM 16 kHz in, provider
  format out (voice-session §3.6). `confirm_draft/3` requires `origin: :client` (§17.11).
- **Wire codec (core).** `VoiceConverse.Wire.encode/decode` implements the voice-session §3.3
  converse frames exactly. The contract stays the source. aiur's channel and the local
  socket use the same codec, so they cannot drift.
- **aiur adapter.** `voice:converse` on the `/voice` socket and on the MP-E5-C8 device
  socket (C7-T01). Auth, CSRF, the `VoiceSessionLimiter` lease and device identity stay in
  aiur, as voice-session §3 requires. The core never sees them.
- **Standalone transport (proof of use without aiur).** `VoiceConverse.Transport.WebSock` is
  a `WebSock` handler that any Plug/Bandit host can mount. It binds to `127.0.0.1` by
  default and requires a bearer token from `Config`. The example host (C11-T03) serves it
  with one HTML page that uses `voice_converse_client.js`. The browser gives echo
  cancellation for free. **A CLI mic/speaker demo is not in v1:** it needs platform audio
  tools (`pacat`, `sox`) and has no echo cancellation, and the browser page already proves
  standalone use (E6-OQ17).

### 17.6 Configuration

`%VoiceConverse.Config{}` is a validated struct (NimbleOptions-style schema in the core).
It holds `name`, `provider: {module, opts}` (agent id, LLM, voice), `credentials`,
`briefing_source`, `agent_channel`, `command_source`, `transcript_root`, `redactor`,
`roles`/`roles_dir`, `glossary`, and `limits` (`max_session_seconds`, `idle_timeout_seconds`,
`daily_minutes_cap` (60 by default, E6-OQ6), `context_token_budget` 4,000,
`briefing_token_budget` 1,500, `max_sessions`, `consult_timeout_seconds` 300). It also holds
`turn` (`interruptions: true`, `eagerness: :normal`, `turn_timeout_seconds: 10`) and
`privacy` (§17.11). The core reads no application env and no files except the roles directory
and `transcript_root`.

aiur keeps its `voice.conversation.*` keys (RC-13, C3-T01) and maps them in
`Aiur.VoiceConverse.Host.Config.build/1`. Config docs, `config.example` and
`scripts/check-config-docs.py` stay aiur concerns. The package documents the struct in its
own guide.

### 17.7 Read-only fork per harness (`fork_session`, MP-R7)

`ask_agent` routes as in C5-T04/C10-T05. A question that needs only the agent's existing
context ("why did you drop the retry?") goes to `AgentChannel.fork_query/3`. A question that
needs new work goes to the queued `ask` at the agent's checkpoint. The fork is how the
assistant gets more context without stopping the agent.

**Where it lives.** The voice core knows only `fork_query/3` and the `fork` capability value.
The mechanism belongs in the **harness adapter layer** (MP-R7, `aiur_harness`), because it
differs per harness and other features can reuse it (Executor side questions, Khala). New
optional callback on `Aiur.Harness.Adapter` (MP-E6-C11-T05; contract request R-6 to MP-R7):

```elixir
@callback fork_capability() :: :native | :history_copy | :replay
@callback fork_session(session_handle, %{prompt: String.t(), read_only: true,
                                         max_turns: pos_integer(), timeout_ms: pos_integer()}) ::
            {:ok, fork_ref} | {:error, term()}
@optional_callbacks fork_capability: 0, fork_session: 2
```

An adapter without the callbacks gets the shared **replay fallback**
(`Aiur.Harness.ForkReplay`). It starts a fresh session of the same harness and model with the
briefing, the last N redacted transcript entries (E4 `list_entries(…, principal: :internal,
tail: true)`, or `LiveConversation`) and the question, using the read-only tool set.

**Rules for every mode:** read-only (no edit or write tools, no shell that can write, no
`git` writes, no network beyond the model call); no write to the parent's session, transcript
or worktree; never pauses or interrupts the parent; ephemeral (the fork is discarded after
the answer; aiur records only the question and the answer in the voice transcript); at most
one fork per voice session at a time; hard timeout (default 60 s, then "the fork did not
answer"). The parent-untouched test (hash the parent transcript and `git status` of the
worktree before and after) is a required test for every mode.

**Capability matrix (evidence checked 2026-10-09):**

| Harness (MP-R7 registry key) | Mode | Mechanism | Read-only enforcement | Evidence | Status |
| --- | --- | --- | --- | --- | --- |
| `claude-repl` (interactive Claude Code; aiur knows the session id, `providers/claude.ex:117-122`) | **native** | `claude -p --resume <session_id> --fork-session` with the question as the prompt. The fork gets a new session id; the original's history is unchanged. | `--permission-mode plan` plus `--allowedTools Read,Grep,Glob` and `--disallowedTools "Bash Edit Write"`; the fork runs in the parent worktree, so write refusal is required (forking branches history, **not** the filesystem) | Local `claude --help` on Claude Code 2.1.295 lists `--fork-session` ("When resuming, create a new session ID instead of reusing the original"). Agent SDK docs, "Fork to explore alternatives": <https://code.claude.com/docs/en/agent-sdk/sessions> (`fork_session=True` / `forkSession: true` with `resume`; "the original's ID and history stay unchanged"; "Forking branches the conversation history, not the filesystem"), accessed 2026-10-09 | verified in docs and CLI help; **not yet run against a live mid-turn parent** (SQ-6) |
| `claude` (headless, sibling `aiur-claude` app-server; no resume today, `providers/claude.ex:34-40`) | **replay** until `aiur-claude` exposes a fork | `aiur-claude` is built on the Agent SDK, which supports `resume` + `forkSession`. A `thread/fork` method in `aiur-claude` would make this native. | as above, through SDK `allowedTools`/`permissionMode` | SDK docs above; `aiur-claude` support **unverified** (cross-repo; MP-R7-C5 protocol fixture is the place to add it) | replay now; native is a cross-repo follow-up |
| `codex` (`codex app-server`, `thread/resume` today, `codex/frames.ex:57-69`) | **native** | app-server `thread/fork` with `threadId`, `ephemeral: true` (in memory, not listed), then `turn/start` on the fork. `lastTurnId` must not be an in-progress turn. If it is omitted while the parent is mid-turn, the fork records an interruption marker and the parent is not touched. | fork params `sandbox: read-only` and `approvalPolicy: never` (present in the local 0.160.0 JSON schema; the docs page lists `sandbox` only on `thread/start`, so the turn also passes a read-only `sandboxPolicy`) | Docs: <https://learn.chatgpt.com/docs/app-server#start-or-resume-a-thread> ("fork a thread into a new thread id by copying stored history"; `ephemeral: true`; "App-server rejects an in-progress `lastTurnId`"), accessed 2026-10-09. Local: `codex app-server generate-json-schema` on codex-cli 0.160.0 → `v2/ThreadForkParams.json` with `threadId, ephemeral, lastTurnId, sandbox, approvalPolicy, model, cwd, …`. CLI also has `codex fork [SESSION_ID]` (interactive). | verified in docs and schema; **not yet run** (SQ-4) |
| `kimi`, `deepseek`, `openrouter` (`OpenAICompat`, in-process message list, `open_ai_compat/coding_agent.ex:51,121`) | **history_copy** | aiur owns the full message list, so the fork copies it into a new in-process loop with the read-only tool specs and appends the question. This is exact (the same history) and needs no vendor feature. | tool specs filtered to read tools; no tool executor for write tools | code at base (above) | design only; no vendor dependency |
| `muse` (Muse MSP stdio, resume yes, `providers/muse.ex:31`) | **replay** | no fork method found in `muse/protocol.ex` | replay fallback's read-only tool set | `grep -i fork src/lib/aiur/muse` finds nothing (base `e8dfd52ef`) | **unverified** whether MSP has a fork; replay until shown |
| `gemini` (conditional, RC-22; ACP `session/load`) | **replay** | no fork or branch found; Gemini CLI has save/resume and checkpoint/restore, which are not a fork of a live session | replay fallback | web search 2026-10-09 found no fork command; Gemini CLI checkpointing doc (restores files and history; not a fork) | **unverified**; replay |
| future harnesses | declare it | `fork_capability/0` or nothing → replay | — | MP-R7-C6 contributor docs add the callback | — |

The replay fallback is lower quality: the fork does not have the parent's full reasoning
trace, only the tail and the briefing. The voice assistant says so once per session ("this
answer comes from a summary, not the agent's full memory") when `capabilities.fork ==
:replay`. Spike C10-T03 measures speed and quality for all three modes.

### 17.8 aiur integration (thin adapter layer)

`src/lib/aiur/voice_converse/host/`: `Config` (maps `voice.conversation.*` and the MP-R5
voice facade into the struct), `Credentials`, `BriefingSource` (the status card, C10-T02),
`AgentChannel` (E7 send with `origin: :voice_assistant`, `:checkpoint` delivery, receipt
mapping, consult reply capture, `fork_query` via `fork_session`), `CommandSource` (E2), and
`Telemetry` (alerts bridge). It also holds `Capability` (`voice.conversation` from
`VoiceConverse.availability/1` plus aiur rules) and the composition-root entry that adds
`VoiceConverse.child_spec(config)`. The `/voice` channel (C7-T01), the dashboard panel (C7),
the review UI (C8) and the CLI verbs `aiur voice setup|transcripts` (which call the core's
provisioning and transcript functions) stay in aiur. **Size rule:** each host module is a
mapping with no session logic. A reviewer rejects a host module that holds state-machine,
draft or turn-taking code.

### 17.9 Module moves (applies to every ticket that names `Aiur.VoiceConversation.*`)

| Old (§2–§16, tickets) | New |
| --- | --- |
| `Aiur.VoiceConversation.Provider`, `.Events`, `FakeProvider` | `VoiceConverse.Provider`, `VoiceConverse.Events`, `VoiceConverse.Testing.FakeProvider` |
| `.Provider.ElevenLabsAgents`, preflight, `ProviderCleanup` | `VoiceConverse.Provider.ElevenLabsAgents{,.Preflight,.Provision}`, `VoiceConverse.ProviderCleanup` |
| `.Session`, `SessionSupervisor`, `Registry`, `ClientErrors` | `VoiceConverse.Session*`, `VoiceConverse.ClientErrors` |
| `.ContextBuilder`, `.Tools`, drafts, `.LiveContext` | `VoiceConverse.ContextBuilder`, `.Tools`, `.Drafts`, `.LiveContext` (subscribes to ports, not to `Aiur.Events.Exchange`) |
| `.TranscriptStore` + index, `Config.Paths.voice_conversation_state_dir/0` | `VoiceConverse.TranscriptStore*`; aiur keeps the path function and passes it as `transcript_root` |
| `Ports.{ConversationRead, CommandRead, StatusRead, ExecutorRead}` | replaced by `BriefingSource` (+ `details/3`) and `CommandSource`; Executor is a target kind in aiur's `BriefingSource` |
| `.StatusCard` | split: `VoiceConverse.Briefing` (core) + `Aiur.VoiceConverse.Host.BriefingSource` (aiur fields) |
| `.SideQuery` | `AgentChannel.fork_query/3` (core) → `Aiur.VoiceConverse.Host.AgentChannel` → `Aiur.Harness` `fork_session/2` (MP-R7) |
| role registry | `VoiceConverse.Roles`; aiur supplies `roles_dir` and the glossary |
| `Aiur.VoiceConversation.Host.*` | `Aiur.VoiceConverse.Host.*` |

Ticket IDs and test intent do not change. Test paths for core work move to
`packages/elixir/voice_converse/test/**` and run with
`env -C packages/elixir/voice_converse mise exec -- mix test`. They do not boot aiur, so the
agent-token hash check is not needed there. It is still needed for every `src/` test.

### 17.10 MP-R1 manifest and promotion

- **Manifest (`components.json`, MP-R1-C1-T01):** two entries. (1) `voice-conversation-core`:
  paths `packages/elixir/voice_converse/**`, `requires: []`, `optional: []`, `owns.state:
  ["<transcript_root> (injected)"]`, `owns.config: []`, kind `optional`, target `package
  (born as package)`. (2) `voice-conversation` (existing row): paths
  `src/lib/aiur/voice_converse/**`, `src/lib/aiur_web/channels/voice_converse_channel.ex`;
  `requires: [voice-conversation-core, config, listener-modes]`; `optional: [commands,
  conversations, executor-attention, harness-adapters (fork_session), voice-stt (ElevenLabs
  key via MP-R5)]`; `owns.config: ["voice.conversation"]`. The R-down rule then fails any
  edge from core to aiur.
- **Promotion test (migration-plan §5), recorded by MP-E6-C11-T07 as a birth check:**
  criterion 2 (own child specs) and 3 (tests run without the app) hold by construction and
  are proven by the standalone CI job. Criterion 4 holds because the core owns no aiur config
  section and aiur's `voice.conversation` is declared in the adapter entry. Criterion 5 is
  met by the example host and Kevin's 2026-10-09 statement that independent use is a need.
  Criterion 1 (zero violations for 2 consecutive merged releases) is checked before any
  public publish (E6-OQ16), not before the in-repo path dependency.

### 17.11 Rules kept

- **Latency targets unchanged** (research §7): answer from the briefing ≤ 0.8 s median,
  ≤ 1.5 s p95; Converse → listening ≤ 1 s. Ports are in-process function calls with the
  budgets in §17.4. The split adds no network hop. The standalone socket has the same hop
  count as `/voice`. C11-T03 measures Converse → listening with the fake provider in the
  example host as a regression guard.
- **Never an instruction without confirmation** (V5, V8). This is a core invariant. Only
  `VoiceConverse.confirm_draft/3` called with `origin: :client` from a transport calls
  `AgentChannel.instruct/4` or `CommandSource.answer/4`. No tool, provider event or host
  callback can reach those calls. Core test with `FakeAgentChannel`: across every tool and
  provider event, `instruct` is called only after a client confirm, and once per `draft_id`.
  The `ask` (consult) and `fork_query` paths are framed questions, not instructions (§6), and
  E6-OQ2 still decides whether `ask` needs a button.
- **Privacy defaults travel with the package** (D17, V2). The core never writes audio. It
  refuses a provider agent with `record_voice: true` and deletes the provider conversation
  after the session. `Config.privacy` has no switch that turns these off. A standalone user
  gets the same guarantees as aiur.

### 17.12 Ticket changes

- **New research ticket files** (promoted with MP-E6, no GitHub issue now): MP-E6-C11-T01
  package skeleton, `Config`, ports and the standalone CI job; C11-T02 session API, wire
  codec and WebSock transport; C11-T03 standalone example host; C11-T04 aiur host adapter
  layer and manifest entries; C11-T05 harness `fork_session` capability (MP-R7 layer);
  C11-T06 second provider adapter (bake-off runner-up); C11-T07 package docs and birth check.
- **Amended (section "Amendment 2026-10-09 — independent package"):** C2-T01..T04, C3-T01..T03,
  C4-T01..T06, C5-T01..T05, C6-T01..T03, C7-T01, C9-T01, C10-T01..T05.
- Component map `voice-conversation` row and capability-matrix `voice.conversation` row
  updated. voice-session contract §13 added. MP-R7 plan gets a plan-refresh note for
  `fork_session` (contract request R-6).

### 17.13 Open questions for Kevin

| ID | Question | Recommendation |
| --- | --- | --- |
| E6-OQ16 | Distribution: in-repo path dependency only, Hex, npm, or Hex + npm? | **In-repo path dependency for v1. Publish to Hex after the 2-release clean check (§17.10). No npm package:** the browser client is one file in `priv/`. Add npm only when a non-browser JS consumer (for example Khala) asks for it. |
| E6-OQ17 | Is a standalone demo host in scope for v1? | **Yes: the local WebSock + one-page browser host (C11-T03).** It is the proof of independence and runs in CI with a fake provider. **No CLI mic/speaker demo** (platform audio tools, no echo cancellation). |
| E6-OQ18 | Package name: neutral `voice_converse` / `VoiceConverse` or aiur-branded `aiur_voice_converse`? | **Neutral `voice_converse`.** It costs nothing now, and an aiur prefix would suggest that aiur is required. Check Hex name availability at C11-T07. |
| E6-OQ19 | License for the package? | **Apache-2.0, the same as aiur** (`LICENSE` at the repo root). |
| E6-OQ20 | Ship both provider adapters in v1, or only the bake-off winner? | **Both, winner first.** Standalone users may have only one vendor account. The fake-driven conformance suite makes the second adapter cheap (C11-T06 runs after the aiur path works). |
| E6-OQ21 | Accept the replay fallback for harnesses without a native fork (Muse, Gemini, headless `claude` until `aiur-claude` adds a fork), with the spoken "from a summary" note? | **Yes.** Otherwise `ask_agent` on those harnesses must wait for the agent's checkpoint. Also file a cross-repo `aiur-claude` fork request when MP-E6 is promoted. |
