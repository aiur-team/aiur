---
research_question: MP-Q3b (fast conversation over a slow coding agent)
feature_id: MP-E6
related: [MP-E5, MP-E7, MP-E4, MP-E3, MP-R5]
base_main_sha: 0972f0297
date: 2026-10-08
status: answered — recommended flow below; provider choice goes to a measured two-provider spike (MP-E6-C1-T01, amended)
---

# Realtime conversation mode over a slow coding agent

## 0. Kevin's request (verbatim, 2026-10-08)

> "one thing im nervous about: when i use voice mode with heavier, higher effort agents, the
> convo is extremely slow and broken up. i love how chat GPT's newest convo mode works and
> would love if the supported conversation mode either used it directly via open code API (if
> they offer access to it), or something very close to it provided by eleven labs. my fear is
> that if we separate the voice conversation agent from the real aiur coding agent, it may
> only add additional latency while the convo agent asks the coding agent and acts as a dumb
> relay. it makes me wonder if we need a more sophisticated setup, something like:
> 1. the user clicks convo mode
> 2. the coding agent halts immediately and context dumps a full summary of what it's doing,
>    any requested commands, progress, the issue, the pr, comments, etc
> 3. context is sent to convo agent.
> 4. user begins talking to convo agent
> 5. convo agent tries its best to answer given this context, but is capable of doing a full
>    relay loop with coding agent as needed.
> include this context in the research doc and relevant ticket for the voice to text and
> convo features. background additional needed research now to handle something like this or
> propose a better flow"

"open code API" is read as **OpenAI API** (most likely a dictation error). The OpenCode
harness is also checked (§3.5).

## 1. Short answer

- **Yes, ChatGPT's newest voice mode is now available to developers.** OpenAI's
  **GPT-Live 1** (`gpt-live-1`) became generally available in the API on 2026-09-10. Press and
  OpenAI's engineering post say GPT-Live powers ChatGPT Voice. It is a full-duplex
  speech-to-speech model. Its built-in **delegation** sends hard work to a backend while the
  voice keeps talking, and that backend may be our own code ("client delegation"). That is
  the "smart voice, slow brain" split Kevin is afraid of, with the latency problem solved in
  the model. Price: **$0.05 per session minute**, plus backend tokens (§3.1).
- **Kevin's fear is correct for a naive relay, and his flow is the right idea in the wrong
  place.** The voice agent must answer most questions without asking the coding agent. But it
  should not *halt* the coding agent to get that context: a high-effort model takes tens of
  seconds to minutes to write a full dump, so the first useful word would come later than it
  does today. The better flow keeps a **status card** current all the time (written by the
  agent at checkpoints, completed by aiur from data it already holds). Converse then starts
  in about one second with no halt. Halting stays available as an explicit "Pause and brief
  me" (§4, §5).
- **Today's slowness has a plain cause.** The current dashboard "interactive voice chat" sends
  every spoken turn *to the worker* and reads the reply only after the worker's whole turn
  ends (`conversation-voice-controller.js:354-396`), with the `:interrupt` default send policy
  (`src/lib/aiur/agent_chat.ex:27`). With a high-effort model each turn is a full coding turn.
  MP-E6 replaces that mode (§2).

## 2. What exists today and what MP-E6 already plans

| Item | Evidence | Effect on latency |
| --- | --- | --- |
| Legacy voice chat = the worker conversation | `voice:conversation` → `requestSubmit` to the worker; wait for the next completed agent reply; TTS (`conversation-voice-controller.js:354-396`, `voice_channel.ex:118-182`) | one high-effort turn per spoken turn: tens of seconds to minutes; half-duplex |
| Operator messages | `Aiur.AgentChat.send/3` → `Orchestrator.send_operator_message/2`; policies `:checkpoint`, `:interrupt`, `:immediate`, `:auto` (`orchestrator/operator_messages/delivery_policy.ex:9-46`); receipts `:pending/:delivered/:consumed` (`agent_chat.ex:63-80`) | a consult can either wait for a checkpoint (slow, safe) or cut the turn (fast, costly) |
| Listener modes (planned, MP-E7) | `steer` / `sync` / `async`, default `sync` (D13) | decides when a consult reaches the agent |
| Agent-emitted progress | `emit_event` `progress` with `percent` + `label` at phase boundaries (`src/prompts/shared-agent-instructions.md:106-135`); `## Agent Workpad` comment | a thin, already-existing "status" signal; no "why / next / asks" fields |
| MP-E6 plan (2026-10-06) | separate assistant, ElevenLabs Agents, daemon-held websocket, ContextBuilder (8,000-token start context, last 20 messages), `contextual_update` from the bus, `consult_agent` async, drafts + Confirm | already avoids the "dumb relay" for discussion; the start context is raw and large, and nothing makes the agent itself keep a briefing current |

The MP-E6 design is closer to the right answer than Kevin feared: the assistant is not a
relay, it answers from context, and its one path to the agent (`consult_agent`) is already
asynchronous. The gaps are (a) the context is a raw transcript tail, not a briefing; (b) the
coding agent emits nothing aimed at a briefing; (c) the provider choice predates GPT-Live;
(d) there is no fast path for "why did you…?" questions, which today can only be answered by
waiting for the agent's turn.

## 3. Provider findings (all accessed 2026-10-08)

### 3.1 OpenAI GPT-Live 1 (the ChatGPT Voice model)

| Item | Finding | Source |
| --- | --- | --- |
| Availability | `gpt-live-1`, GA 2026-09-10, endpoint `v1/live/sessions` | <https://developers.openai.com/api/docs/models/gpt-live-1>; changelog <https://developers.openai.com/api/docs/changelog> |
| Same as ChatGPT Voice? | Reported: default ChatGPT Voice model for Go/Plus/Pro from about 2026-07-08; full-duplex, backchannels, delegates reasoning to a frontier model in the background. OpenAI's own pages returned HTTP 403 to our fetcher, so this is from press and an engineering-post summary — **verify** | <https://dig.watch/updates/gpt-live-1-chatgpt-voice>; <https://gigazine.net/gsc_news/en/20260804-openai-gpt-live/> (2026-08-04) |
| Turn-taking | no separate end-of-turn detector; the model decides to speak, listen, wait or interrupt several times per second; WebRTC transport | same engineering-post summary |
| Transports | WebRTC (browser), WebSocket (server), SIP; a **sideband** server WebSocket can attach to a session for transcripts, delegation and tools | <https://developers.openai.com/api/docs/guides/live> |
| Delegation | fixed per session. **Responses delegation**: OpenAI calls a Responses model (docs suggest `gpt-6-luna`, `gpt-6-sol` for complex work) that can call *our* function tools. **Client delegation**: we receive `session.delegation.created` (with no task text; rebuild it from the transcript deltas), do the work, and push `session.commentary.append` (spoken, paraphrased), `session.thinking.append` (silent context) or `session.instructions.append` | <https://developers.openai.com/api/docs/guides/live-delegation> |
| Rules in the docs | "Live speech and delegated work continue independently." An interruption does not cancel backend work; the app must cancel and de-duplicate. Speak only verified states; announce success only after the tool confirms | same |
| Limits | `instructions` ≤ 16,384 tokens; seed input ≤ 128 messages / 8,192 tokens; each append ≤ 500 tokens; 128k context with automatic engine replacement past 90% | <https://developers.openai.com/api/docs/guides/live-conversations> |
| Max session length | **not published** | — |
| Latency | **no official number found**; "sub-300 ms" claims are unverified | — |
| Price | **$0.05 / session minute**, billed per second; backend model and tools billed separately | model page |
| Storage | `store: true` keeps recordings 30 days for session forking; not available under ZDR. Default retention for `store: false` must be checked in the spike | live-conversations guide |

### 3.2 OpenAI Realtime API (`gpt-realtime-2.1`, the classic path)

- Models: `gpt-realtime-2.1` and `-mini` (2026-07-06); 128k context; Realtime beta removed
  2026-05-12 (changelog).
- Price per 1M tokens: 2.1 — audio in $32 / cached $0.40 / out $64; text $4 / $0.40 / $24.
  2.1-mini — audio $10 / $0.30 / $20 (<https://developers.openai.com/api/docs/models/gpt-realtime-2.1>).
- Session max 60 minutes; `conversation.item.create` injects context; out-of-band responses
  (`response.conversation: "none"`); `server_vad` / `semantic_vad`; barge-in with truncation
  (<https://developers.openai.com/api/docs/guides/realtime-conversations>,
  <https://developers.openai.com/api/docs/guides/realtime-vad>).
- Async function calls: the session continues while a call is pending and the model says
  "still waiting"; a late `function_call_output` + `response.create` delivers the result. Risk:
  the model may invent a result before it arrives (<https://developers.openai.com/blog/realtime-api>).
- The Agents SDK documents "delegation through tools" to a text model and warns that a
  blocking tool stops the agent from handling new input
  (<https://openai.github.io/openai-agents-js/guides/voice-agents/build/>). OpenAI's
  "chat-supervisor" demo answers a delegated question about 2 s after the filler
  (<https://github.com/openai/openai-realtime-agents>).
- Assessment: GPT-Live supersedes this for our use. Keep it as the fallback inside the same
  OpenAI adapter.

### 3.3 ElevenLabs Agents (current MP-E6 recommendation)

- Cascade of ASR → chosen LLM → TTS with a proprietary turn-taking model; orchestration
  overhead "<100 ms"; speculative LLM requests before the turn ends
  (<https://elevenlabs.io/blog/unpacking-elevenagents-orchestration-engine>, updated 2026-09-14).
  No end-to-end number is published (marketing "sub-500 ms" is unverified).
- Turn settings: eagerness eager/normal/patient; turn timeout 1–30 s; soft-timeout filler
  0.5–8 s (off by default); `max_duration_seconds` default 600, max 7,200
  (<https://elevenlabs.io/docs/eleven-agents/customization/conversation-flow>, changelog).
- Tools: client, webhook, system, MCP; execution modes Immediate (pre-tool speech is
  extended), Post-tool speech, **Async** (background); client tools with `expects_response`
  and `response_timeout_secs` (-1 = wait forever)
  (<https://elevenlabs.io/docs/eleven-agents/customization/tools/client-tools>).
- `contextual_update` adds non-interrupting background facts; `sendUserMessage` forces a turn
  (<https://elevenlabs.io/docs/agents-platform/customization/events/client-to-server-events>).
  There is no documented "speak this when idle" primitive; an aiur-originated announcement
  needs a user-message-style trigger (spike question).
- LLMs: OpenAI, Anthropic (Haiku 4.5 … Opus 5.5), Gemini, hosted open models; pass-through
  cost with no markup (<https://elevenlabs.io/docs/eleven-agents/customization/llm>).
- Price: plans with included minutes (Creator $22 / 275 min; Pro $99 / 1,238 min); overage
  $0.08/min; LLM extra (<https://elevenlabs.io/pricing/agents>; page layout was
  inconsistent, verify).
- Assessment: very good turn-taking and voice quality, reuses Kevin's key and voice. It is a
  cascade, so it is "close to" ChatGPT Voice, not the same model.

### 3.4 Others (brief)

- **Gemini Live** (`gemini-3.8-live`, page updated 2026-09-15): cheapest audio ($3 / $12 per
  1M ≈ $0.005 + $0.018 per minute); **NON_BLOCKING** function calls are the default with
  response scheduling `INTERRUPT` / `WHEN_IDLE` / `SILENT` — an exact fit for "answer when the
  agent replies"; 15-minute audio sessions without compression, about 10-minute connections
  with resumption (<https://ai.google.dev/gemini-api/docs/live-tools>,
  <https://ai.google.dev/gemini-api/docs/live-session>). A forum thread reports
  first-audio regressions to 9–26 s on 3.1 Flash Live in September 2026 (anecdotal). New
  vendor; not proposed for launch.
- **Pipecat / LiveKit Agents**: open-source cascades; Pipecat states 500–800 ms round trips;
  async tools with `cancel_on_interruption=False`; LiveKit has an audio turn-detector model.
  They are the "cascade" option with extra infrastructure; keep as design references only.
- **Latency targets**: human turn gap is about 200 ms; the common voice-agent target is
  ≤ 800 ms median voice-to-voice, 1.5 s acceptable (<https://www.daily.co/blog/advice-on-building-voice-ai-in-june-2025/>).
- **Products**: Claude Code `/voice` is dictation only (<https://code.claude.com/docs/en/voice-dictation>).
  A Codex realtime voice mode is reported in testing only (unverified).

### 3.5 OpenCode

No voice or realtime feature. It has a headless server (`opencode serve`) with
`POST /session/:id/prompt_async`, `POST /session/:id/abort` and SSE `/event`
(<https://opencode.ai/docs/server/>). That maps onto GPT-Live client delegation for an
OpenCode worker, but it is not a voice API.

### 3.6 Requirement check (from provider-research.md §1)

| Req | GPT-Live 1 | ElevenLabs Agents |
| --- | --- | --- |
| P1 role prompt | `instructions` ≤ 16k tokens | override (must be enabled) |
| P2 live context | `thinking.append` / `instructions.append` (≤ 500 tokens each) | `contextual_update` |
| P3 aiur tools | Responses-delegation function tools, or client delegation | client tools |
| P4 turn-taking | native full-duplex (the ChatGPT Voice feel) | proprietary turn model, configurable |
| P5 live transcripts | input/output transcript deltas | `user_transcript`, `agent_response` |
| P6 retention | `store: false`; ZDR on approval; verify defaults | `record_voice=false`, delete; ZRM Enterprise only |
| P7 no public URL | server WebSocket / sideband from the daemon | daemon websocket (no custom LLM, no webhooks) |
| P8 key on daemon | yes | yes (signed URL) |
| P9 reuse | **new key and vendor** (Kevin already runs Codex on OpenAI) | same key, voice, account |
| Async answer from the agent | built in (delegation; commentary spoken when ready) | Async tools + `contextual_update`; spoken announcement needs a trigger |

## 4. Kevin's 5-step flow, evaluated

| Step | Right about | Cost / risk |
| --- | --- | --- |
| 1 click Converse | explicit start (already D16) | — |
| 2 agent halts and dumps a full summary | the voice agent needs a full, *agent-authored* briefing, not a raw log; Commands, PR, comments belong in it | **slow**: a high-effort model writing a 1–2k-token summary takes about 30–120 s (estimate; the spike measures it), so the first informed word comes later than today. **Loses momentum**: an interrupt cuts the running turn; on resume the model re-reads context, and a cold prompt cache costs more. **Stale on arrival**: the agent is stopped, so nothing new happens, but the moment it resumes the dump ages. **Large**: a "full" dump crowds the voice model's context and slows its first audio (GPT-Live seed input ≤ 8,192 tokens) |
| 3 context sent to the voice agent | yes | — |
| 4 user talks | yes | waits for step 2 |
| 5 answer from context, relay when needed | **exactly right**; this is the thinker/responder pattern all vendors now support | the relay must be non-blocking with a spoken acknowledgement, or it feels broken |

Verdict: keep steps 1, 3, 4, 5. Replace step 2 with a briefing that is **already there** when
Converse opens, and make halting an explicit choice.

## 5. Recommended flow

### 5.1 Before Converse (always on, no voice involved)

1. The coding agent writes a short **status note** at every checkpoint: phase boundary, before
   a long step, when it opens a Command, at turn end, and on request (`emit_event
   progress.status`: doing / why / next / waiting on / asks / risks / PR). MP-E6-C10-T01.
2. aiur keeps a **status card** per target: the note plus data aiur already holds — phase and
   percent, PR/CI/review, open Commands, last milestones, last operator message and its
   delivery state, listener mode — each with its age. About 1,500 tokens, deterministic, no
   LLM. MP-E6-C10-T02.

### 5.2 Converse

1. Operator presses Converse → the panel is listening in under 1 s. The session opens with
   the role prompt + status card + open Commands + the tail of the last voice session
   (≤ 4,000 tokens). The coding agent **keeps working**.
2. If the note is older than 5 minutes, aiur sends a **refresh** request at the agent's next
   checkpoint (never an interrupt). The new note arrives as a delta. MP-E6-C10-T04.
3. While the operator talks, each card change goes to the voice model as a silent update;
   agent answers and new Commands are **spoken at the next pause** (E6-OQ14).

### 5.3 Intent paths (the voice model routes; no separate router service)

| Path | Example | Mechanism | Coding agent disturbed? |
| --- | --- | --- | --- |
| A answer from card | "what's it doing? is CI green?" | answer directly from context | no |
| B quick look-up | "what did it say last? which tests fail?" | `get_details(section)` local read ≤ 300 ms | no |
| C side query | "why did it drop the retry?" | fork the agent's session read-only, low effort (MP-E6-C10-T03/T05) | no |
| D consult | "ask it whether it tested on Postgres" | `ask_agent` → listener-mode send at checkpoint; spoken ack now, answer spoken when it lands | at its next checkpoint only |
| E steer / hand a task | "tell it to stop and use the old schema" | `propose_instruction` draft → on-screen Confirm → send (steer only if the operator says urgent) | yes, by the operator's choice |
| F pause and brief me | "stop and give me the full picture" | Kevin's step 2 on request: confirm → pause → full briefing → separate resume confirm | yes, by the operator's choice |

With **GPT-Live**, paths B–F are function tools of a Responses-delegation backend, or aiur
handles them as a client-delegation backend; the voice keeps talking natively and speaks the
result with `commentary.append`. With **ElevenLabs**, they are client tools (Async mode for C
and D) plus `contextual_update`.

### 5.4 What the coding agent must emit

- The status note (C10-T01) at the five checkpoints above, honest and short.
- The existing `progress` percent, `emit_alert` phase events and Commands (no change).
- Replies to a consult as normal conversation messages (already captured by
  `LiveConversation` / MP-E4). Nothing voice-specific beyond the note.

### 5.5 Keeping the two in sync

- The **coding agent's transcript and the event bus are the source of truth**. The voice
  session never holds state the agent does not have.
- Every context block, delta, tool call and draft is written to the voice transcript before
  the provider sees it (contract §9), so a reviewer can see what the voice model knew.
- Each card field has an age; the voice model must say "as of 12 minutes ago" when it answers
  from a stale field.
- Delivered instructions and consults carry `origin: voice_assistant` in the agent transcript
  (MP-E7 request), so the agent and the operator see the same record.
- An interruption of the voice never cancels backend work (GPT-Live rule); a stale consult is
  marked stale, not re-sent.

## 6. Mapping onto aiur

| Need | Existing piece | New / changed piece | Ticket |
| --- | --- | --- | --- |
| agent-authored briefing | `emit_event` `progress.<slug>`; workpad | status note protocol + store | MP-E6-C10-T01 (new) |
| always-current briefing | StatusReport, DecisionStore, AgentChat receipts, Exchange | StatusCard + deltas | MP-E6-C10-T02 (new) |
| fast "why" answers | Claude `--resume` session ids (`claude/repl/command.ex:50-60`) | forked read-only side query | MP-E6-C10-T03 spike, -T05 (new) |
| refresh / halt on request | delivery policy `:checkpoint`; PauseResume | briefing actions | MP-E6-C10-T04 (new) |
| consult without cutting the turn | `AgentChat.send/3` (`:interrupt` default) | `ask_agent`, non-blocking, `:checkpoint` | MP-E6-C5-T04 (amended) |
| spoken announcement of late results | — | `ConversationProvider.announce/3` | MP-E6-C2-T01 (amended) |
| smaller, faster start context | ContextBuilder (8k) | card first, 4k budget | MP-E6-C4-T03 (amended) |
| live sync | LiveContext | card deltas + announce | MP-E6-C4-T05 (amended) |
| quick reads | read tools | `get_details(section)` | MP-E6-C5-T01 (amended) |
| provider | ElevenLabs-only spike | **two-provider bake-off: GPT-Live 1 vs ElevenLabs** | MP-E6-C1-T01 (amended) |
| hand-off from the mic | `open-voice-conversation` event | target only; no wait | MP-E5-C3-T02 (amended) |
| today's slow mode | legacy `voice:conversation` | `:checkpoint` send until replaced | MP-E5-C3-T03 (amended) |

Listener modes (MP-E7): `sync` (default) delivers consults at checkpoints, which is path D;
`steer` is used only when the operator asks for urgency; `async` makes the consult wait for
a pull, and the voice model says so. The Executor target (MP-E6-C4-T06) uses the same card
shape with one line per agent.

## 7. Latency budget (targets; time to first spoken word after the operator stops talking)

Numbers marked *est.* are engineering estimates to be measured by MP-E6-C1-T01 and
MP-E6-C10-T03.

| Path | First spoken word | Useful answer | Notes |
| --- | --- | --- | --- |
| Converse press → listening | — | ≤ 1.0 s | no context build beyond a local card read |
| Greeting after Start | ≤ 1.5 s | — | includes provider connect |
| A answer from card | **≤ 0.8 s median, ≤ 1.5 s p95** | same | industry voice-to-voice target (§3.4) |
| B quick look-up | ≤ 0.8 s (ack or answer) | ≤ 2 s | local read ≤ 300 ms + model turn |
| B via GPT-Live Responses delegation | ≤ 0.8 s (native filler) | 2–4 s *est.* | OpenAI demo: ~2 s after filler |
| C side query (fork) | ≤ 0.8 s ack | ≤ 15 s target, 5–30 s *est.* | spike pass line 15 s at 150k context |
| D consult at checkpoint | ≤ 0.8 s ack | 30 s – 10 min (agent-bound) | the voice keeps talking meanwhile |
| E instruction draft | ≤ 0.8 s | draft card ≤ 2 s; receipt ≤ 1 s after Confirm | agent acts at its checkpoint or on steer |
| F pause and brief me | ≤ 0.8 s ack | 30–120 s *est.* | this is Kevin's step 2; opt-in |
| Kevin's flow as written | 30–120 s *est.* + halt time | same | first informed word waits for the dump |
| Today (legacy voice chat) | 20 s – minutes per turn *est.* | same | one full coding turn per spoken turn |

### Cost (per 20-minute conversation, list prices, 2026-10-08)

| Provider | Voice | Reasoning | 20 min ≈ | 60 min/day cap ≈ / month |
| --- | --- | --- | --- | --- |
| GPT-Live 1 | $0.05/min | backend tokens (Responses model) | $1.00 + backend | $90 + backend |
| ElevenLabs Agents | included minutes, then $0.08/min | LLM pass-through | $1.60 at overage (or plan minutes) + LLM | $144 at overage; Pro plan $99 includes 1,238 min |
| gpt-realtime-2.1-mini | tokens ($10 / $20 per 1M audio) | in model | context-dependent; *est.* $0.5–2 | — |
| Gemini 3.8 Live | ≈ $0.023/min audio | in model | ≈ $0.46 | ≈ $41 |

Side queries (path C) add model cost per question on the worker's harness (spike SQ-5).

## 8. Recommendation

1. Build the **status note + status card** first (C10-T01, C10-T02). They are provider-neutral,
   help every surface (Executor, phone home), and are the main reason the voice will feel fast.
2. Turn the paid spike into a **bake-off: GPT-Live 1 vs ElevenLabs Agents**, same card, same
   tools, same scripted questions; measure first-word latency per path, barge-in, async
   announcement, privacy settings and cost. Choose by measured feel (E6-OQ13). Research leans
   to **GPT-Live 1** because it is the ChatGPT Voice model Kevin likes and it has native
   delegation; ElevenLabs stays the choice if reuse of the existing key/voice and its privacy
   controls matter more, or if GPT-Live fails a privacy check.
3. Keep `ConversationProvider` neutral (C2-T01 amendment) so either adapter fits.
4. Never halt by default. Offer "Refresh" (checkpoint) automatically and "Pause and brief me"
   on request (C10-T04).
5. Run the side-query spike (C10-T03) in parallel; it costs no new vendor.

## 9. Open questions for Kevin (also in DESIGN-E6 §3.1)

1. **E6-OQ12** — When you press Converse, may the coding agent keep working (recommended), with
   "Pause and brief me" as an explicit button?
2. **E6-OQ13** — Are you willing to add an OpenAI API key (separate from ChatGPT/Codex
   subscriptions) for GPT-Live 1, and do you authorize the two-provider bake-off (budget in
   MP-E6-C1-T01)?
3. **E6-OQ14** — May the voice speak first at the next pause when the agent answers or a
   Command opens?
4. **E6-OQ15** — May the voice fork the agent's session read-only for fast "why" answers, at
   extra model cost per question?
5. Does the confirm rule (E6-OQ1: on-screen Confirm only) still hold if the voice feels as
   natural as ChatGPT? Spoken "send it" would be faster but is less safe.

## 10. Sources (accessed 2026-10-08 unless stated)

- OpenAI: models <https://developers.openai.com/api/docs/models>; changelog
  <https://developers.openai.com/api/docs/changelog>; GPT-Live
  <https://developers.openai.com/api/docs/models/gpt-live-1>,
  <https://developers.openai.com/api/docs/guides/live>,
  <https://developers.openai.com/api/docs/guides/live-delegation>,
  <https://developers.openai.com/api/docs/guides/live-conversations>; Realtime
  <https://developers.openai.com/api/docs/models/gpt-realtime-2.1>,
  <https://developers.openai.com/api/docs/guides/realtime-conversations>,
  <https://developers.openai.com/api/docs/guides/realtime-vad>,
  <https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets/methods/create>,
  <https://developers.openai.com/blog/realtime-api>; Agents SDK
  <https://openai.github.io/openai-agents-js/guides/voice-agents/build/>; demo
  <https://github.com/openai/openai-realtime-agents>; release note
  <https://community.openai.com/t/new-realtime-models-on-the-api-gpt-realtime-2-1-and-gpt-realtime-2-1-mini/1385896> (2026-07-06).
- GPT-Live and ChatGPT Voice (secondary; openai.com returned 403):
  <https://dig.watch/updates/gpt-live-1-chatgpt-voice>,
  <https://pulse2.com/openai-introduces-gpt-live-to-power-more-natural-chatgpt-voice-interactions/> (about 2026-07-08),
  <https://gigazine.net/gsc_news/en/20260804-openai-gpt-live/> (2026-08-04).
- ElevenLabs: <https://elevenlabs.io/docs/eleven-agents/overview>,
  <https://elevenlabs.io/blog/unpacking-elevenagents-orchestration-engine> (2026-02-27,
  updated 2026-09-14), <https://elevenlabs.io/docs/eleven-agents/customization/conversation-flow>,
  <https://elevenlabs.io/docs/eleven-agents/customization/tools/client-tools>,
  <https://elevenlabs.io/docs/agents-platform/customization/events/client-to-server-events>,
  <https://elevenlabs.io/docs/eleven-agents/customization/llm>,
  <https://elevenlabs.io/docs/eleven-agents/customization/llm/custom-llm>,
  <https://elevenlabs.io/docs/eleven-agents/customization/tools/system-tools/agent-transfer>,
  <https://elevenlabs.io/docs/changelog>, <https://elevenlabs.io/pricing/agents>.
- Gemini: <https://ai.google.dev/gemini-api/docs/pricing>,
  <https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live>,
  <https://ai.google.dev/gemini-api/docs/live-tools>,
  <https://ai.google.dev/gemini-api/docs/live-session>, forum report
  <https://discuss.ai.google.dev/t/gemini-3-1-flash-live-preview-9-15-s-time-to-first-audio-since-2026-09-05-09-00-utc-was-1-s-some-turns-never-answer-reproduced-from-two-projects-two-networks/180918>.
- Pipecat / LiveKit / budgets: <https://docs.pipecat.ai/overview/pipecat>,
  <https://reference-server.pipecat.ai/en/latest/api/pipecat.utils.async_tool_cancellation.html>,
  <https://docs.livekit.io/agents/build/turns/turn-detector/>,
  <https://docs.livekit.io/agents/logic/turns/tuning/>,
  <https://www.daily.co/blog/advice-on-building-voice-ai-in-june-2025/>,
  <https://www.daily.co/blog/the-worlds-fastest-voice-bot/>.
- Products: <https://code.claude.com/docs/en/voice-dictation>;
  <https://www.testingcatalog.com/openai-tests-codex-realtime-voice-mode-for-chatgpt.md> (unverified leak).
- OpenCode: <https://opencode.ai/docs/server/>.
- Repository evidence at `0972f0297`: `src/lib/aiur/agent_chat.ex`,
  `src/lib/aiur/orchestrator/operator_messages.ex`,
  `src/lib/aiur/orchestrator/operator_messages/delivery_policy.ex`,
  `src/lib/aiur/codex/dynamic_tool/emit_event.ex`, `src/lib/aiur/claude/repl/command.ex`,
  `src/prompts/shared-agent-instructions.md`; legacy voice paths as cited in MP-E6 plan §1.
