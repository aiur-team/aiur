---
research_question: MP-Q3
feature_id: MP-E6
base_main_sha: 45a290e3
date: 2026-10-06
status: answered — recommendation below; four claims need the paid validation spike (MP-E6-C1)
---

# MP-Q3 — Conversational voice provider

**Question.** Can the ElevenLabs conversational offering (now "ElevenLabs Agents" / Agents
Platform) provide the MP-E6 experience without rebuilding a voice stack? How does it compare
with the alternatives?

**Answer.** Yes, with one constraint. Use the **ElevenLabs Agents Platform with a built-in LLM**,
driven by a **daemon-held websocket**. aiur's own daemon executes the assistant's tools as
**client tools**. Do **not** use the Agents "custom LLM" or server-tool (webhook) features:
both need a publicly reachable URL, which the private-access rule (brief §3) forbids.

All sources were accessed on **2026-10-06**. External docs are unversioned web pages; API
paths are the version identifiers.

## 1. Requirements the provider must meet

| # | Requirement | From |
| --- | --- | --- |
| P1 | Configurable role pre-context (system prompt) per conversation | brief E6 |
| P2 | Inject target context at start and during the conversation | brief E6 |
| P3 | Tool calls that aiur executes (consult the agent, propose drafts) | brief E6 |
| P4 | Natural turn-taking and barge-in interruption | brief E6 |
| P5 | Transcripts available to aiur in real time, for local retention | D17 |
| P6 | Provider-side audio storage can be turned off; transcripts deletable | D17 |
| P7 | Works without any public inbound URL to the aiur machine | brief §3, R3 |
| P8 | Provider key stays on the daemon | V4 (existing rule) |
| P9 | Reuse the existing ElevenLabs account, key and voice where possible | brief E6 "without rebuilding" |

## 2. ElevenLabs Agents Platform — findings

| Capability | Finding | Source |
| --- | --- | --- |
| Websocket endpoint | `wss://api.elevenlabs.io/v1/convai/conversation?agent_id={agent_id}` | https://elevenlabs.io/docs/agents-platform/libraries/web-sockets |
| Private agent auth | The server obtains a signed URL with its API key: `GET /v1/convai/conversation/get-signed-url?agent_id=…`. "Never expose your ElevenLabs API key on the client side." Validity period not documented → **RQ-E6-1**. | same; https://elevenlabs.io/docs/api-reference/conversations/get-signed-url |
| Audio formats | `user_input_audio_format` / `agent_output_audio_format` include `pcm_16000`, `pcm_44100` and others, reported in `conversation_initiation_metadata` | https://elevenlabs.io/docs/agents-platform/api-reference/agents-platform/websocket |
| Client → server events | `user_audio_chunk`, `user_message`, `user_activity`, `contextual_update` ("Context text to inject into the conversation without interrupting"), `client_tool_result`, `conversation_initiation_client_data`, `pong`, others | same |
| Server → client events | `conversation_initiation_metadata`, `user_transcript`, `agent_response`, `agent_response_correction`, `agent_chat_response_part`, `audio`, `interruption`, `client_tool_call` ("whether the server expects a ClientToolResult"), `vad_score`, `ping`, others | same |
| Per-conversation overrides (P1) | System prompt, first message, language, voice ID, LLM, tools and more, via `conversation_config_override`. "Overrides are disabled by default"; each field must be enabled in the agent's security settings, or the start errors. | https://elevenlabs.io/docs/agents-platform/customization/personalization/overrides |
| Dynamic variables (P2) | `{{var}}` in prompts; passed at start; `secret__` variables are redacted in APIs | https://elevenlabs.io/docs/agents-platform/customization/personalization/dynamic-variables |
| Client tools (P3, P7) | Run "on the user's device through the ElevenLabs SDK or websocket connection". With `expects_response`, "the agent will wait for its response and append the response to the conversation context". Timeout not documented → **RQ-E6-2**. | https://elevenlabs.io/docs/agents-platform/customization/tools/client-tools |
| Custom LLM (rejected) | OpenAI-compatible `/v1/chat/completions` or `/v1/responses` with SSE. The guide tells you to "create a public URL using a tunneling tool like ngrok". Fails P7. | https://elevenlabs.io/docs/agents-platform/customization/llm/custom-llm |
| Built-in LLMs | ElevenLabs-hosted, Google Gemini, OpenAI GPT and Anthropic Claude (Opus, Sonnet, Haiku 4.5) families. "ElevenLabs passes through third-party LLM costs at the provider's published rate, with no markup." | https://elevenlabs.io/docs/agents-platform/customization/llm |
| Turn-taking (P4) | Interruptions on/off; turn timeout 1–30 s; turn eagerness Eager/Normal/Patient; soft-timeout filler (about 3 s) | https://elevenlabs.io/docs/agents-platform/customization/conversation-flow |
| Audio storage (P6) | Per-agent `platform_settings.privacy.record_voice`. "By default, audio recordings are enabled." Disabling stops new recordings; transcripts stay accessible. | https://elevenlabs.io/docs/agents-platform/customization/privacy/audio-saving |
| Transcript retention (P6) | Retention in days, `-1` unlimited, default 2 years; `0` described as "scheduled deletion". Exact meaning of `0` → **RQ-E6-3**. | https://elevenlabs.io/docs/agents-platform/customization/privacy/retention |
| Delete a conversation (P6) | `DELETE /v1/convai/conversations/{conversation_id}` | https://elevenlabs.io/docs/api-reference/conversations/delete |
| Zero Retention Mode | Enterprise-only; covers "ElevenLabs Agents: all input and output"; API traffic only; with ZRM only Gemini, Claude and ElevenLabs-hosted Qwen LLMs are allowed. | https://elevenlabs.io/docs/eleven-api/resources/zero-retention-mode |
| Agents as code | `POST /v1/convai/agents/create` with `conversation_config` and `platform_settings` (privacy is in `platform_settings`) | https://elevenlabs.io/docs/api-reference/agents/create |
| Price | $0.08 per additional minute shown on the API pricing page, plus LLM tokens passed through. Plan-dependent; **UNVERIFIED** against the owner's plan. | https://elevenlabs.io/pricing/api |

Observations:

- P5 is met in real time by `user_transcript` and `agent_response` over the websocket the
  daemon holds. aiur never needs the post-call webhook (which would need a public URL) or the
  history API.
- P8: the daemon fetches the signed URL and opens the websocket itself, then relays PCM to and
  from the browser on its own `/voice` socket. The browser never sees the key or the signed URL.
  This mirrors how `Aiur.ElevenLabs.Realtime` already relays STT (`realtime.ex:14-35`). The
  signed URL is a credential in a URL, which `realtime.ex:25-30` warns about: the adapter must
  never log or persist it (contract §9).
- P9: same account, key and `elevenlabs.voice_id`. The key needs Agents permission
  (current docs list `Speech to Text`, `Text to Speech` and `User`; `website/docs-app/apis/elevenlabs.md:14-22`).

## 3. Alternatives

### 3.1 OpenAI Realtime API

| Capability | Finding | Source |
| --- | --- | --- |
| Model | `gpt-realtime-2.1` (current speech-to-speech model per guide) | https://developers.openai.com/api/docs/guides/realtime |
| Connection | WebRTC with ephemeral client secrets (`POST /v1/realtime/client_secrets`) or a server-side WebSocket | same |
| Tools, barge-in | Function calling on the realtime agent; "barge-in, low first-audio latency, natural turn taking, and realtime tool use" | same |
| Turn detection | `server_vad` and `semantic_vad`; `create_response`, `interrupt_response` | https://developers.openai.com/api/docs/guides/realtime-vad |
| Retention | `/v1/realtime`: abuse-monitoring retention 30 days, application state none, Zero Data Retention eligible (approval required) | https://developers.openai.com/api/docs/guides/your-data |

Assessment: meets P1–P5, P7 (server WebSocket from the daemon) and P8. P6 is stronger
(no application-state storage; ZDR possible) than ElevenLabs without Enterprise. It fails P9:
a second vendor account and key, a second voice, a second privacy disclosure. The model and the
voice are bundled, so aiur cannot pick Claude for reasoning.

### 3.2 Cascade on the existing stack

STT (`Aiur.ElevenLabs.Realtime`) → an LLM call made by the daemon → TTS (`Aiur.ElevenLabs.TTS`).

Assessment: maximum control and no new provider product, but aiur would build turn detection,
barge-in, streaming sentence segmentation and latency tuning itself — the "entire voice stack"
the brief asks to avoid. The existing half-duplex loop (`voice_channel.ex:118-144`) shows the
current gap. aiur also has no LLM API credential of its own today (agents run through harness
CLIs). Keep it as a **fallback adapter design**, not the launch path.

### 3.3 Not evaluated in depth

Google Gemini Live API and open-source orchestration frameworks (Pipecat, LiveKit Agents). They
were not needed for a supported recommendation: Gemini is already reachable as an ElevenLabs
built-in LLM, and a framework is a cascade variant (§3.2) with extra infrastructure. No claims
are made about them.

## 4. Scoring

| Req | ElevenLabs Agents (built-in LLM, client tools) | OpenAI Realtime | Cascade |
| --- | --- | --- | --- |
| P1 pre-context | yes (override, must be enabled) | yes | yes |
| P2 context | start + `contextual_update` | start + conversation items | yes |
| P3 aiur tools | client tools over daemon websocket | function calls | yes |
| P4 turn-taking | provider VAD, configurable | server/semantic VAD | build it |
| P5 transcripts | real-time events | real-time events | local by construction |
| P6 retention | audio off + delete; ZRM Enterprise-only | 30-day abuse log; ZDR on approval | provider STT/TTS only |
| P7 no public URL | yes (not with custom LLM/server tools) | yes (server WS) | yes |
| P8 key on daemon | yes (signed URL fetched by daemon) | yes | yes |
| P9 reuse | same key, voice, account | new vendor | yes |

## 5. Recommendation

1. **Launch provider:** ElevenLabs Agents Platform, built-in LLM, daemon-held websocket, client
   tools only, `record_voice=false`, shortest retention, delete each conversation after the
   local transcript is fsynced.
2. **LLM default:** a fast built-in model. Recommend Claude Haiku 4.5 or a Gemini Flash model as
   the configured default, because the assistant is "fast, communication-oriented" and both
   remain ZRM-compatible if the owner later buys Enterprise. The choice is owner question E6-OQ7.
3. **Boundary:** everything behind `Voice.ConversationProvider` (contract §4). The OpenAI
   Realtime adapter is the documented second implementation; the cascade is a design note.
4. **Gate:** do not start implementation tickets past MP-E6-C2 until the validation spike
   (MP-E6-C1) settles RQ-E6-1..4. The spike costs money (agent minutes plus LLM tokens), so it
   needs the owner's explicit authorization (brief §2 Phase D).

## 6. Research questions for the spike (MP-E6-C1)

| ID | Question | How to settle |
| --- | --- | --- |
| RQ-E6-1 | Signed URL lifetime; can the daemon instead connect with an `xi-api-key` header? | Call both; record behaviour |
| RQ-E6-2 | Client-tool timeout and the agent's behaviour while waiting (filler? silence?) | Tool that sleeps 5/15/30/60 s |
| RQ-E6-3 | Does retention `0` delete immediately? Does `DELETE` remove transcript and any audio? | Create, end, delete, then `GET` |
| RQ-E6-4 | Is the override prompt size limited? Latency with an 8k-token start context? | Measure time to first audio |
| RQ-E6-5 | Browser echo cancellation with speakers during barge-in | Manual desktop and phone test |
| RQ-E6-6 | Do `user_transcript` events give final text only, or partials too? | Observe the stream |
