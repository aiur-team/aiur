# Aiur Voice Mode — Product and Technical Specification

**Status:** Draft
**Project:** Aiur
**Feature:** Browser-based voice interface for the Aiur orchestrator
**Primary access:** Aiur dashboard on desktop or mobile over Tailscale

---

## 1. Summary

Add a voice mode to the existing Aiur dashboard so a user can speak naturally with the orchestrator that manages Aiur.

The user should be able to open the dashboard from a desktop or mobile browser, tap a microphone button, ask a question or issue an instruction, and receive both a spoken and written response.

The voice interface should not be a separate autonomous agent. It should be another client of the same Aiur orchestrator used by the dashboard, terminal, or other interfaces. The orchestrator retains access to its existing Aiur state, agents, tools, and MCP servers.

The initial voice provider should be ElevenLabs for speech-to-text and text-to-speech, including support for a configured custom voice. The architecture should remain provider-agnostic so other speech or real-time voice providers can be added later.

---

## 2. Goals

The feature should:

1. Make it possible to interact with Aiur from a mobile browser without installing a native application.
2. Allow the user to ask for project, ticket, agent, and system status through voice.
3. Route transcribed speech into the same orchestrator used by the rest of Aiur.
4. Allow the orchestrator to use its existing MCP tools and Aiur capabilities.
5. Return the orchestrator's answer as both text and synthesized speech.
6. Minimize latency, particularly for common status requests.
7. Work securely over Tailscale.
8. Support interruption, cancellation, and graceful recovery from provider errors.
9. Avoid coupling the orchestrator directly to ElevenLabs or any specific voice provider.
10. Establish an architecture that can later support continuous, full-duplex voice interaction.

---

## 3. Core Product Principle

**Voice is a transport and user interface, not a separate agent.**

The intended relationship is:

```text
Dashboard text interface ─┐
Terminal interface ───────┼──> Aiur Orchestrator ──> Aiur state, agents, and MCP tools
Dashboard voice interface ┘
```

Voice input should ultimately become an ordinary user message delivered to the orchestrator.

The voice layer is responsible for:

* Capturing audio
* Speech-to-text
* Conversation/session management
* Streaming UI events
* Text-to-speech
* Audio playback
* Cancellation and interruption

The orchestrator remains responsible for:

* Understanding the request
* Deciding whether tools are needed
* Reading Aiur state
* Calling MCP tools
* Performing orchestration
* Producing the final textual response
* Enforcing command and action policy

The voice gateway must not independently call Aiur MCP tools.

---

## 4. Primary User Experience

### 4.1 Entry point

Add a microphone control to the Aiur dashboard.

The dashboard should be responsive and usable from:

* A desktop browser
* A mobile browser
* A device connected to the same Tailscale network as the Aiur machine

No native mobile application should be required.

### 4.2 Basic interaction

The initial interaction model should be push-to-talk:

1. The user opens the Aiur dashboard.
2. The user taps the microphone button.
3. The dashboard begins capturing audio.
4. The user speaks.
5. The user taps again to stop, or the client detects the end of speech.
6. The audio is transcribed.
7. The final transcript is sent to the Aiur orchestrator.
8. The orchestrator processes the request using its normal state and tools.
9. The textual answer appears in the dashboard.
10. The answer is synthesized using the configured ElevenLabs voice.
11. Audio begins playing as soon as a useful response segment is available.

### 4.3 UI states

The microphone and conversation interface should visibly represent these states:

```text
Idle
Listening
Transcribing
Thinking
Using tools
Speaking
Cancelled
Error
```

The user should not be left uncertain about whether the system heard them or is still working.

### 4.4 Conversation display

Each voice turn should display:

* The user's transcript
* Any transcript corrections made before submission
* The assistant's response
* The status of the turn
* The time the response was generated
* The timestamp of any cached Aiur status used in the response
* A replay button for the spoken response, when audio is available

Typed messages and voice messages should be able to share the same conversation.

---

## 5. Example Interactions

### Status request

**User:** > What's going on with Aiur right now?

**Expected behavior:** Aiur immediately retrieves the latest status snapshot, summarizes active work, blockers, recently completed work, failures, and available capacity, and speaks the answer.

### Follow-up

**User:** > Which agents are blocked?

**Expected behavior:** The new message remains in the same conversation and can refer to the previous answer.

### Read-only inspection

**User:** > Give me an update on the dashboard ticket.

**Expected behavior:** The orchestrator reads the relevant ticket and agent status through its normal tool path.

### Mutating request

**User:** > Stop agent seven and reassign its ticket.

**Expected behavior:** The orchestrator prepares the action but requires explicit confirmation before performing it. For higher-risk actions, the dashboard should display the exact proposed operation and require a button confirmation rather than relying only on another spoken phrase.

---

## 6. Proposed Architecture

```text
┌──────────────────────────────────────────────┐
│ Mobile or Desktop Browser                    │
│ Aiur Dashboard                               │
│ - Microphone controls                        │
│ - Audio capture                              │
│ - Transcript and response UI                 │
│ - Audio playback                             │
└──────────────────────┬───────────────────────┘
                       │  Tailscale + HTTPS
                       ▼
┌──────────────────────────────────────────────┐
│ Aiur Voice Gateway / Backend Module          │
│ - Authentication and authorization           │
│ - Voice session management                   │
│ - Audio stream handling                      │
│ - STT provider adapter                       │
│ - Orchestrator adapter                       │
│ - TTS provider adapter                       │
│ - Cancellation and interruption              │
│ - Metrics and tracing                        │
└───────┬───────────────────┬──────────────────┘
        ▼                   ▼
┌────────────────┐   ┌─────────────────────────┐
│ ElevenLabs     │   │ Aiur Orchestrator       │
│ - STT          │   │ - Conversation context  │
│ - Custom TTS   │   │ - Aiur state / agents   │
└────────────────┘   │ - MCP access / tools    │
                     └───────────┬─────────────┘
                                 ▼
                     ┌─────────────────────────┐
                     │ Status Snapshot Service │
                     │ and Aiur Runtime State  │
                     └─────────────────────────┘
```

---

## 7. Backend Discovery Requirement

The implementation must not assume that the current dashboard already has an appropriate backend. Before implementation, inspect the Aiur repository and determine: whether the dashboard is frontend-only; whether it already has an HTTP server; whether it supports WebSockets; how authentication currently works; how the dashboard reads Aiur state; how the orchestrator is launched; whether the orchestrator exposes an API, message bus, socket, or other machine-readable interface; where conversation state currently lives.

If no suitable backend exists, introduce a minimal local backend or gateway as part of this feature. The browser must never invoke a local terminal session, model CLI, or MCP server directly.

---

## 8. Orchestrator Adapter

Create an adapter between the voice gateway and the Aiur orchestrator. The voice system should interact with an abstract interface similar to:

```typescript
interface OrchestratorAdapter {
  sendTurn(input: OrchestratorTurnInput): AsyncIterable<OrchestratorEvent>;
  cancelTurn(turnId: string): Promise<void>;
}

interface OrchestratorTurnInput {
  turnId: string;
  conversationId: string;
  userId: string;
  message: string;
  source: "voice" | "text";
  statusSnapshotId?: string;
  clientContext?: Record<string, unknown>;
}

type OrchestratorEvent =
  | { type: "started" }
  | { type: "text_delta"; text: string }
  | { type: "tool_started"; toolName: string }
  | { type: "tool_finished"; toolName: string }
  | { type: "confirmation_required"; action: ProposedAction }
  | { type: "completed"; text: string }
  | { type: "cancelled" }
  | { type: "error"; code: string; message: string };
```

The adapter should hide whether the orchestrator is implemented through a local HTTP endpoint, a local WebSocket endpoint, a Unix socket, a message queue, an existing OpenCode/Claude/Codex orchestration process, or another local runtime. A stable API, socket, or message-bus interface is preferred. Do not implement this by screen-scraping a terminal. A temporary CLI subprocess adapter is acceptable for a first vertical slice, but it should not become the permanent interface.

---

## 9. MCP and Tool Access

The voice gateway should not connect directly to MCP servers. The expected flow is: voice transcript → Aiur orchestrator → existing orchestrator policy and reasoning → MCP or Aiur tool call → tool result → orchestrator response → text-to-speech.

This preserves existing tool permissions, orchestration logic, context/memory, audit trails, consistent text/voice behavior, and a single place for safety and confirmation policy. A voice-originated message should have the same capabilities as a typed message in the same session, subject to additional confirmation requirements for risky operations.

---

## 10. Voice Provider Abstraction

Although ElevenLabs is the initial provider, define provider interfaces rather than placing ElevenLabs calls throughout the application.

```typescript
interface SpeechToTextProvider { createSession(options: STTSessionOptions): Promise<STTSession>; }
interface STTSession {
  writeAudio(chunk: Uint8Array): Promise<void>;
  finish(): Promise<FinalTranscript>;
  cancel(): Promise<void>;
  events(): AsyncIterable<STTEvent>;
}
interface TextToSpeechProvider {
  synthesizeStream(input: TTSInput): AsyncIterable<Uint8Array>;
  cancel(requestId: string): Promise<void>;
}
interface TTSInput { requestId: string; text: string; voiceId: string; format?: string; }
```

The configuration should allow future support for additional providers (STT, TTS, or speech-to-speech) without changing dashboard or orchestrator code. They are outside the initial implementation.

---

## 11. ElevenLabs Integration

**Runtime behavior:** use ElevenLabs for streaming/near-real-time transcription, text-to-speech, and a configured custom voice.

**Custom voice setup:** treat custom voice creation/cloning as an administrative setup step, not part of the first dashboard release. The application consumes a configured voice ID. Only audio for which the user has the necessary rights and consent should be used to create a cloned/custom voice.

```env
VOICE_STT_PROVIDER=elevenlabs
VOICE_TTS_PROVIDER=elevenlabs
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
VOICE_STATUS_CACHE_TTL_SECONDS=60
VOICE_AUDIO_RETENTION_ENABLED=false
```

**Fallback behavior:** if the custom voice is unavailable — preserve/display the textual answer; attempt a configured fallback voice when enabled; show a non-blocking audio-generation error; do not rerun the orchestrator request merely because TTS failed.

---

## 12. Transport

Use an authenticated bidirectional connection between the dashboard and the voice gateway. A WebSocket is the preferred initial transport (audio chunks, partial/final transcripts, orchestrator state events, text deltas, TTS audio chunks, cancellation). A first implementation may use HTTP audio upload plus server-sent events if that fits the codebase more naturally, but the internal event model should support future streaming.

Client events: `voice.session.start`, `audio.start`, `audio.chunk`, `audio.stop`, `turn.cancel`, `playback.stop`, `action.confirm`, `action.reject`.
Server events: `voice.session.ready`, `stt.partial`, `stt.final`, `orchestrator.started`, `orchestrator.tool_started`, `orchestrator.tool_finished`, `assistant.text.delta`, `assistant.text.final`, `tts.audio.start`, `tts.audio.chunk`, `tts.audio.end`, `action.confirmation_required`, `turn.completed`, `turn.cancelled`, `error`.
Audio chunks may use binary WebSocket frames rather than encoding audio into JSON.

---

## 13. Status Snapshot and Latency Optimization

Status questions are expected to be one of the most common voice interactions. Introduce a first-class **Aiur status snapshot** usable by voice, the dashboard, reports, and notifications.

```typescript
interface AiurStatusSnapshot {
  id: string;
  generatedAt: string;
  summary: string;
  activeAgents: AgentSummary[];
  queuedWork: WorkSummary[];
  recentlyCompleted: WorkSummary[];
  blockedWork: BlockedWorkSummary[];
  failedWork: FailureSummary[];
  currentCapacity?: { active: number; maximum?: number; cpuUsage?: number; memoryUsage?: number; };
  notableChanges: string[];
  recommendedAttention: string[];
  sourceVersions?: Record<string, string>;
}
```

**Refresh:** event-driven updates on state change; periodic refresh (initially every 60s); manual forced refresh when the user asks for live/exact status.
**Cache rules:** a normal status request may use a snapshot ≤60s old; responses retain the snapshot's `generatedAt`; if older than threshold, refresh or disclose age; terms like "live/exact/refresh/right now" may bypass the cache; the orchestrator may still query more detailed state. The cached snapshot must not be presented as live without disclosing its timestamp.

---

## 14. Latency Targets

Engineering targets (not hard external guarantees). Cached status request: stop-speaking→final-transcript <1s; final-transcript→first-assistant-text <1.5s; first-text→first-audio <1s; end-of-speech→first-spoken-answer <3s. Requests needing tools/fresh orchestration: show visual progress immediately; avoid unexplained silence; emit a short nonverbal cue or factual acknowledgement when processing >~2s; never generate a fake status update to fill time. Instrument each stage separately.

---

## 15. Streaming the Response

Do not require the full orchestrator response before starting TTS: stream text → buffer to a stable sentence/phrase boundary → send that segment to TTS → begin playback → continue synthesizing. Segmentation must avoid speaking incomplete code, splitting numbers/names, reading markdown syntax, speaking tool metadata, or producing overlapping audio streams. The full canonical response remains the orchestrator's text; TTS is a rendering of it.

---

## 16. Interruption and Cancellation

The user must be able to interrupt the assistant while it is speaking. When interrupted: stop browser playback immediately; cancel active TTS; cancel/suspend the orchestrator turn when appropriate; begin capturing the new utterance; preserve already-displayed text unless the turn is explicitly discarded. Provide a visible stop button. Cancellation propagates through the full stack via a stable `turnId`/`requestId`.

---

## 17. Conversation and Session Model

Each voice session has: user identity, conversation ID, voice session ID, turn IDs, creation/expiration timestamps, a reference to the orchestrator session, voice configuration, cancellation state. Voice and text share conversation context when they use the same conversation ID. Do not rely solely on an in-memory browser session if the orchestrator already maintains persistent conversation state. A page refresh should either restore the conversation or clearly begin a new one.

---

## 18. Safety for Actions

Voice transcription errors can turn a read-only request into a mutating instruction, so voice commands require explicit action policy.

- **Read-only (no extra confirmation):** read status, inspect tickets, inspect logs, summarize agent progress, list blockers, report capacity, explain failures.
- **Mutating (require confirmation):** stop/restart an agent, reassign a ticket, change priority, start a run, modify config, create/delete resources, merge/deploy/publish/release.
- **High-risk (require visible dashboard confirmation button; voice-only confirmation insufficient):** destructive, external, financial, deployment, credential, or data-deletion operations.

The confirmation UI shows the exact proposed action, affected object, expected consequences, confirm/reject controls, and any relevant warnings.

---

## 19. Security and Privacy

HTTPS (mobile mic access); access restricted through Tailscale + existing Aiur auth (Tailscale is not a substitute for app-level authz); ElevenLabs keys stay server-side; the browser never receives a permanent provider key; validate WebSocket origins + authenticated sessions; reasonable request/session/audio-size limits; prevent cross-user session attachment; redact tokens/credentials/secrets from logs+transcripts; do not store raw mic audio by default; make transcript retention configurable; audit-event every voice-initiated tool action; associate confirmed actions with the original transcript + confirmation event; expire abandoned sessions; do not expose MCP servers to the browser.

---

## 20. Observability

Assign a trace ID per turn, propagated through: browser → voice gateway → STT → orchestrator → tool calls → TTS → browser playback. Metrics: audio-connection success, time-to-first-partial/final-transcript, orchestrator queue time, time-to-first-text-token, tool execution time, time-to-first-TTS-audio, total end-to-end latency, cache age, cancellation rate, TTS/STT failure rate, turn success rate, session disconnects, provider usage + estimated cost. Logs avoid raw audio/sensitive content by default. A dev-only diagnostics view may expose per-stage timings.

---

## 21. Error Handling

Clear recovery for: mic permission denied (explain + preserve typed chat); audio capture failure (retry without reload); Tailscale/backend disconnect (reconnecting state, don't silently discard recorded audio); STT failure (retry or type manually); orchestrator timeout (preserve transcript, show timed-out, allow retry); TTS failure (display text, continue without audio); custom voice unavailable (fallback voice when configured); tool failure (orchestrator explains which op failed without exposing secrets/raw exceptions); stale snapshot (display timestamp, offer/perform refresh).

---

## 22. Configuration

```env
VOICE_ENABLED=true
VOICE_STT_PROVIDER=elevenlabs
VOICE_TTS_PROVIDER=elevenlabs
ELEVENLABS_API_KEY=
ELEVENLABS_VOICE_ID=
ELEVENLABS_FALLBACK_VOICE_ID=
VOICE_STATUS_CACHE_TTL_SECONDS=60
VOICE_MAX_AUDIO_SECONDS=120
VOICE_SESSION_TTL_MINUTES=30
VOICE_AUDIO_RETENTION_ENABLED=false
VOICE_TRANSCRIPT_RETENTION_ENABLED=true
VOICE_MUTATING_ACTIONS_ENABLED=true
VOICE_REQUIRE_UI_CONFIRMATION_FOR_HIGH_RISK=true
ORCHESTRATOR_TRANSPORT=http
ORCHESTRATOR_ENDPOINT=http://127.0.0.1:PORT
```

Exact names should follow existing Aiur configuration conventions.

---

## 23. MVP Scope

1. Mobile-responsive mic button in the dashboard. 2. Tap-to-start/stop recording. 3. Secure audio transfer to the backend. 4. ElevenLabs STT. 5. Visible partial/final transcription. 6. Stable bridge from backend to the Aiur orchestrator. 7. Transcript delivered into the same conversation system used by text. 8. Orchestrator's existing Aiur+MCP access preserved. 9. Written response streaming to the dashboard. 10. ElevenLabs TTS with a configured voice ID. 11. Browser audio playback. 12. Stop/cancel controls. 13. Status snapshot ≤60s normal age. 14. Clear listening/thinking/tool-use/speaking states. 15. Text fallback when speech services fail. 16. Server-side credential protection. 17. Confirmation for mutating actions. 18. Basic latency + error metrics.

---

## 24. Non-Goals for the Initial Release

Native iOS/Android app; wake word; always-on background listening; full-duplex open-mic conversation; custom voice training inside Aiur; a voice-provider marketplace; direct browser MCP access; voice-controlled destructive actions without visual confirmation; moving Aiur's agent runtime to the cloud; increasing max parallel agent count; replacing the terminal/individual-agent interfaces; multi-user voice rooms; telephone calling; public internet exposure outside the selected secure access model.

---

## 25. Recommended Implementation Phases

- **Phase 0 — Repo + architecture discovery:** dashboard architecture, backend capabilities, auth flow, orchestrator entry point, conversation storage, event-streaming support, Aiur state sources, existing status-summary functionality. Produce a short ADR before provider integrations.
- **Phase 1 — Text-only orchestrator bridge:** backend endpoint/message interface to send a text turn to the orchestrator; stream the response; confirm MCP+Aiur capabilities retained; add turn IDs, cancellation, error propagation; validate typed + voice-originated messages share one path. (Removes the largest unknown.)
- **Phase 2 — Status snapshot service:** define schema; generate from runtime state; refresh periodically + on state change; display age; make available to orchestrator + dashboard.
- **Phase 3 — Push-to-talk vertical slice:** mic UI; capture audio; send to backend; ElevenLabs STT; forward final text to orchestrator; ElevenLabs TTS; play response; text fallback.
- **Phase 4 — Streaming + interruption:** stream audio; partial transcripts; stream orchestrator text; TTS at sentence boundaries; barge-in + cancellation; detailed latency tracing.
- **Phase 5 — Action confirmations + production hardening:** risk classification; confirmation cards; auth + session isolation; rate limits + retention; fallback provider behavior; operational dashboards + cost reporting.
- **Phase 6 — Future conversational voice mode:** auto end-of-speech detection; full-duplex; VAD; seamless interruption; provider switching; per-agent voices; proactive spoken notifications; voice run summaries; optional remote/cloud gateway.

---

## 26. Acceptance Criteria (MVP)

1. Open the dashboard from a mobile browser over Tailscale. 2. Served through a secure context, can request mic permission. 3. Tap mic, speak, stop recording. 4. Transcript displayed before/as sent. 5. Transcript reaches the same orchestrator as the non-voice interface. 6. Orchestrator accesses existing Aiur state + MCP tools. 7. Text response appears. 8. Response spoken via configured ElevenLabs voice. 9. TTS failure doesn't discard the text. 10. Standard status query uses a ≤60s snapshot. 11. Dashboard shows the snapshot timestamp. 12. Stop playback + cancel in-progress turn. 13. Mutating ops require confirmation. 14. High-risk ops require visible dashboard confirmation. 15. ElevenLabs credentials not exposed to the browser. 16. Raw mic audio not retained by default. 17. UI distinguishes listening/transcribing/thinking/tool-use/speaking. 18. Each turn has traceable latency measurements. 19. Disconnects/provider failures produce understandable errors. 20. Typed interaction remains available throughout.

---

## 27. Success Metrics

≥95% of normal voice turns complete without a transport/provider error; ≥90% of cached status questions begin spoken playback within 3s of end-of-utterance; no permanent speech-provider credentials sent to the browser; no unconfirmed high-risk operation executable from a voice transcript; status answers always retain a machine-readable snapshot timestamp; TTS errors never lose an already-generated text answer; works from desktop + mobile browsers over Tailscale.

---

## 28. Open Technical Decisions

Resolve + document after inspecting the repo: (1) does the dashboard have a suitable backend for the gateway; (2) cleanest machine-readable interface to the orchestrator; (3) where conversation state lives; (4) WebSockets vs HTTP+SSE vs hybrid; (5) browser audio capture format; (6) server-side audio normalization needed?; (7) ElevenLabs for both STT+TTS or only TTS; (8) how the status snapshot is generated from current Aiur state; (9) which actions are read-only/mutating/high-risk; (10) how cancellation propagates into the orchestrator runtime; (11) does a forced live refresh block the answer or serve cached-first; (12) transcript retention policy; (13) which fallback voice; (14) how provider cost/usage limits are enforced.

These decisions must not alter the central requirement that voice remains a provider-agnostic client of the existing Aiur orchestrator.
