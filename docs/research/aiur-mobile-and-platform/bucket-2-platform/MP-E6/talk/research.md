---
feature_id: MP-E6
sub_feature: talk
date: 2026-10-10
parent: ../plan.md

# /talk and native providers — research (2026-10-10)

All web sources were accessed on 2026-10-10 unless a row says otherwise. Local CLI checks: Claude Code 2.1.296, codex-cli 0.160.0, Gemini CLI 0.62.0, OpenCode 1.17.10 (help output only; no sessions started). "UNVERIFIED" marks a claim with only a third-party source or none. Research was web-only; no paid API calls were made.

## 0. Findings that change the design

1. **Anthropic has no speech API.** Claude models take text and images and give text. A Claude user needs a cascade (speech-to-text → streaming Claude → text-to-speech). Anthropic's own cookbook measured 0.71 s to first Claude token on Haiku 4.5 and 1.48 s to first audio sentence-by-sentence with ElevenLabs (§1.3). → cascade adapter C14-T04/T05.
2. **OpenAI has two incompatible native protocols** (Realtime `gpt-realtime-2.1`, 60-min sessions; GPT-Live `gpt-live-1` on `v1/live/sessions`, $0.05/min, which owns turn-taking and has no manual truncation) (§1.1). **Gemini Live** connections last about 10 min and audio sessions 15 min without compression; long talks need compression plus resumption (§1.2). → one adapter per protocol (C14-T02, C14-T03).
3. **Only text-to-speech APIs give character timing** (ElevenLabs TTS and the Agents WebSocket `audio` event; not over WebRTC). OpenAI and Gemini give text deltas only, so the page must pace text against the audio clock (§1.6). → normalized timing event C13-T05.
4. **Live agents can receive confirmed instructions without terminal typing.** Claude Code has a documented per-session messaging socket (`CLAUDE_CODE_MESSAGING_SOCKET`, v2.1.224+). Codex has `codex queue --thread $CODEX_THREAD_ID`. Gemini CLI has only hooks (§3.3). → C13-T06 push delivery with a file-inbox fallback.
5. **Native read-only forks exist for Claude Code (`--resume --fork-session`), Codex (`thread/fork` ephemeral read-only, `codex exec fork`) and OpenCode (`POST /session/:id/fork`); not for Gemini CLI, Cursor CLI or Aider** (§3.2). A fork turn takes seconds, so it is for "let me check" answers, not the voice turn (§3.5). → C13-T07.
6. **Codex ships its own realtime voice** (`/voice`, app-server `thread/realtime/*`, experimental, delegates to the thread) (§6). → experimental agent-native option C14-T07.
7. **One skill serves most agents** through the Agent Skills standard: install to `~/.agents/skills/talk` and symlink `~/.claude/skills/talk` (§3.1). Invocation differs (`/talk`, `$talk`, model-activated).
8. **The voice model must use API keys, not the agent subscription.** Anthropic does not permit routing third-party product requests through Free/Pro/Max credentials; Codex docs recommend API keys for automation (§3.4). The fork runs the unmodified agent binary with the user's own login, which is the ordinary-use case.
9. **Local launch safety follows the Jupyter/Vite fixes:** loopback bind, Host allowlist (DNS rebinding), Origin check on the WebSocket, one-time code → HttpOnly SameSite=Strict cookie, no CORS. Use a stable port: mic permission is stored per origin including the port (§4).
10. **Elixir distribution:** Bakeware is archived and Burrito is experimental; a per-platform `mix release` (ERTS included) through npm optional dependencies (the esbuild pattern) is the proven route (§5).

## 1. Voice providers

### 1.1 OpenAI

#### 1.1a Realtime API

| Item | Fact | Source |
|---|---|---|
| Current models | `gpt-realtime-2.1` is the newest. It updates `gpt-realtime-2` and improves alphanumeric recognition, silence/noise handling, and interruption behavior. | https://developers.openai.com/api/docs/models/gpt-realtime-2.1 |
| Other models | The prompting guide recommends `gpt-realtime-2` for the strongest reasoning and tool use, and `gpt-realtime-1.5` for a fast non-reasoning model. | https://developers.openai.com/api/docs/guides/realtime-models-prompting |
| Mini model | `gpt-realtime-2.1-mini` was released on 2026-07-06 (UNVERIFIED, third-party blog). | https://mer.vin/2026/07/gpt-realtime-2-1-api-reasoning-voice-agents-and-mini-pricing/ |
| Legacy | `gpt-realtime` (snapshot `gpt-realtime-2025-08-28`). 32k context, 4,096 max output. | https://developers.openai.com/api/docs/models/gpt-realtime |
| 2.1 limits | 128k context, 32k max output. Reasoning has a configurable effort. | https://developers.openai.com/api/docs/models/gpt-realtime-2.1 |
| Transports | WebRTC (browser), WebSocket (server), SIP (telephony). | https://developers.openai.com/api/docs/models/gpt-realtime ; https://developers.openai.com/api/docs/guides/realtime |
| Ephemeral secret | `POST /v1/realtime/client_secrets`. `expires_after.seconds` is 10 to 7200, default 600. The response has `value` (`ek_...`) and `expires_at`. The session config can be locked in the secret. | https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets/methods/create |
| WebRTC call | The browser posts SDP to `/v1/realtime/calls` with the ephemeral secret. | https://developers.openai.com/api/docs/guides/realtime |
| Beta header | Drop `OpenAI-Beta: realtime=v1`. Use GA session shapes. | https://developers.openai.com/api/docs/guides/realtime |
| Audio formats | Input: 24 kHz PCM, G.711 u-law, G.711 A-law. Examples use `audio/pcm` at rate 24000 and `audio/pcmu`. | https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets/methods/create ; https://developers.openai.com/api/docs/guides/realtime-conversations |
| VAD | `server_vad` (silence-based, default; `threshold`, `prefix_padding_ms`, `silence_duration_ms`). `semantic_vad` (word-based classifier; `eagerness` low/medium/high/auto). Flags `create_response` and `interrupt_response`. Set `turn_detection: null` for manual (push-to-talk). | https://developers.openai.com/api/docs/guides/realtime-vad |
| Barge-in | `input_audio_buffer.speech_started` cancels the response (`response.cancelled`). WebSocket: the client stops playback and sends `conversation.item.truncate` (`item_id`, `content_index`, `audio_end_ms`). WebRTC and SIP: the server truncates automatically. The transcript is not realigned after truncation. | https://developers.openai.com/api/docs/guides/realtime-conversations |
| Function calling | Tools go in `session.tools` or `response.tools`. A `function_call` item (`name`, `arguments`, `call_id`) arrives. Send `conversation.item.create` with `function_call_output`, then `response.create`. MCP tools are also accepted in the session config. | https://developers.openai.com/api/docs/guides/realtime-conversations ; https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets/methods/create |
| Output transcript | `response.output_audio_transcript.delta` / `.done`. The audio comes in `response.output_audio.delta`. There is no per-character timing. | https://developers.openai.com/api/docs/guides/realtime-conversations |
| Input transcript | `conversation.item.input_audio_transcription.delta` and `.completed`. `gpt-live-transcribe` (recommended) streams deltas. `gpt-transcribe` can also stream deltas. Delta behavior for `gpt-4o-transcribe` and `whisper-1` is not stated (UNVERIFIED). There are no word timestamps on `gpt-live-transcribe`. | https://developers.openai.com/api/docs/guides/realtime-transcription |
| Session max | 60 minutes. | https://developers.openai.com/api/docs/guides/realtime-conversations |
| Price, 2.1 / 2 | Per 1M tokens. Audio: $32 in, $0.40 cached, $64 out. Text: $4 in, $0.40 cached, $24 out. | https://developers.openai.com/api/docs/models/gpt-realtime-2.1 |
| Price, 2.1-mini | Audio: $10 in, $0.30 cached, $20 out. Text: $0.60 in, $2.40 out (UNVERIFIED, third-party). | https://mer.vin/2026/07/gpt-realtime-2-1-api-reasoning-voice-agents-and-mini-pricing/ |
| Price per minute | No official per-minute rate. UNVERIFIED. | — |
| Latency | No official number. A third-party post reports "at least 25% p95 latency reduction" via caching (UNVERIFIED). | https://mer.vin/2026/07/gpt-realtime-2-1-api-reasoning-voice-agents-and-mini-pricing/ |
| Privacy header | `OpenAI-Safety-Identifier`, set on the server request that creates the client secret. | https://developers.openai.com/api/docs/guides/realtime |

#### 1.1b GPT-Live

| Item | Fact | Source |
|---|---|---|
| Model | `gpt-live-1`. Full duplex: it listens and speaks at the same time. It delegates reasoning and tools to a backend. | https://developers.openai.com/api/docs/models/gpt-live-1 |
| Endpoint | `v1/live/sessions` only. It is not on `v1/realtime`. | https://developers.openai.com/api/docs/models/gpt-live-1 |
| Price | $0.05 per minute, billed per second. Backend model and tool use are billed separately. | https://developers.openai.com/api/docs/models/gpt-live-1 |
| Limits | Concurrent sessions: 50 (Build), 300 (Launch), 500 (Grow). No free tier. | https://developers.openai.com/api/docs/models/gpt-live-1 |
| Launch date | 2026-09-10 (UNVERIFIED, third-party). | https://www.unite.ai/da/openais-gpt-live-1-arrives-in-the-api-at-0-05-per-minute/ |
| Transports | WebRTC (browser; media tracks plus a JSON data channel), WebSocket (server), SIP/telephony. | https://developers.openai.com/api/docs/guides/live |
| Browser auth | The server creates the session and exchanges the browser's SDP offer for an answer. The key stays on the server. The guide does not mention ephemeral tokens. | https://developers.openai.com/api/docs/guides/live |
| No ephemeral secrets | The Pydantic AI adapter says `create_client_secret` always raises. Browsers connect through a server-side `answer_webrtc_offer`. | https://pydantic.dev/docs/ai/api/realtime/openai_live/ |
| Delegation | "Responses delegation": OpenAI runs the backend model, and your app runs function tools. "Client delegation": you connect any model, agent, or service. Backend work can continue after an interrupt. | https://developers.openai.com/api/docs/guides/live |
| Turn-taking | Live owns turn-taking. There is no manual interruption, truncation, or turn-detection setting. There is no end-of-response frame; the turn end is inferred from silence. Text is added as context, not as a user turn. Transcripts are always on, in both directions, as fragments. (Third-party adapter docs.) | https://pydantic.dev/docs/ai/api/realtime/openai_live/ |
| Design note | Client delegation can, in principle, put the coding agent (or Claude) behind GPT-Live's voice. This is an inference from the guide, not a tested fact. | https://developers.openai.com/api/docs/guides/live |

### 1.2 Google Gemini Live API

| Item | Fact | Source |
|---|---|---|
| Models | `gemini-3.8-live` (default for low-latency voice). `gemini-3.8-live-extended-thinking` (more reasoning). `gemini-3.1-flash-live-preview` (legacy). `gemini-2.5-flash-native-audio-preview-12-2025` still has a price row. | https://ai.google.dev/gemini-api/docs/live-guide ; https://ai.google.dev/gemini-api/docs/pricing |
| 3.8 limits | 131,072 input tokens, 65,536 output tokens. Async function calling is the default (`NON_BLOCKING`). Search grounding is supported. Structured outputs are not. | https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live |
| Transport | A stateful WebSocket (WSS). Server-to-server or client-to-server. The client-to-server path "generally offers better performance". There is no WebRTC in the Gemini API docs. | https://ai.google.dev/gemini-api/docs/live |
| Audio | Input: raw 16-bit PCM, 16 kHz, little-endian. Output: raw 16-bit PCM, 24 kHz, little-endian. | https://ai.google.dev/gemini-api/docs/live |
| Ephemeral tokens | `POST https://generativelanguage.googleapis.com/v1beta/auth_tokens`. `expire_time` defaults to 30 min. `new_session_expire_time` defaults to 1 min. `uses` is typically 1. `liveConnectConstraints` locks the model and config, so system instructions stay on the server. v1beta only. | https://ai.google.dev/gemini-api/docs/ephemeral-tokens |
| VAD | `realtimeInputConfig.automaticActivityDetection` is on by default. Fields: `startOfSpeechSensitivity`, `endOfSpeechSensitivity`, `silenceDurationMs` (500 to 800 ms recommended, about 800 ms default). It can be disabled for client-side VAD or push-to-talk (`audioStreamEnd`). | https://ai.google.dev/gemini-api/docs/live-guide |
| Barge-in | When `serverContent.interrupted` is true, generation was cancelled. The client stops playback and clears the queue. | https://ai.google.dev/gemini-api/docs/live-guide |
| Transcription | `inputAudioTranscription` and `outputAudioTranscription` in setup. The docs do not say explicitly that the text streams incrementally (UNVERIFIED). There are no timestamps. | https://ai.google.dev/gemini-api/docs/live-guide |
| Tools | Function calling and Google Search. | https://ai.google.dev/gemini-api/docs/live |
| Session limits | Without compression: audio-only 15 min, audio+video 2 min. One connection lasts about 10 min. | https://ai.google.dev/gemini-api/docs/live-session |
| Long sessions | `contextWindowCompression` (sliding window). `sessionResumption`: tokens are valid for 2 h after termination. `GoAway` carries `timeLeft`. `generationComplete` marks the end of a response. | https://ai.google.dev/gemini-api/docs/live-session |
| Compression cost | Compression drops history. | https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/live-api/best-practices |
| Price (3.8 / 3.1 Live) | Text: $0.75 in, $4.50 out per 1M. Audio in: $3.00 per 1M or $0.005/min. Audio out: $12.00 per 1M or $0.018/min. The free tier is free of charge. | https://ai.google.dev/gemini-api/docs/pricing |
| Token rate | 25 audio tokens per second. | https://ai.google.dev/gemini-api/docs/pricing |
| Context rebilling | The whole context window is billed again on each turn, so cost grows over a session (UNVERIFIED, forum reports). | https://discuss.ai.google.dev/t/pricing-of-speech-to-speech-live-model/140340 |
| Latency | No official number. UNVERIFIED. | — |

### 1.3 Anthropic (Claude)

| Item | Fact | Source |
|---|---|---|
| Native speech API | **None found.** "All current models support text and image input, text output." Haiku 5.5 lists "Text and images → text". No realtime, STT, or TTS endpoint appears in the models overview. | https://platform.claude.com/docs/en/about-claude/models/overview ; https://platform.claude.com/docs/en/models/haiku-5-5/overview |
| Third-party confirmation | "Claude does not have a native realtime audio API" (UNVERIFIED, third-party blog). | https://claudexia.tech/blog/claude-voice-realtime-stack-2026 |
| Claude apps voice mode | Beta. Available on all plans, on iOS, Android, Desktop, and web. Hands-free mode (with interruption) and push-to-talk. It uses the same models as chat, but Fable is not available. Connected tools work. It counts toward usage limits. | https://support.claude.com/en/articles/11101966-use-voice-mode |
| 2026-07-23 update | Voice mode runs on Opus, Sonnet, and Haiku, with connected tools and more languages. | https://claude.com/blog/think-through-hard-problems-in-voice-mode |
| Claude Code | Voice dictation exists (speech to text input). Voice mode is not available in Claude Code or Cowork. | https://code.claude.com/docs/en/voice-dictation ; https://claude.com/blog/think-through-hard-problems-in-voice-mode |
| Apps voice stack | Reportedly ElevenLabs TTS (UNVERIFIED). | https://www.datastudios.org/post/claude-voice-features-explained-current-status-and-upcoming-real-time-updates |
| Official cascade recipe | Anthropic cookbook: ElevenLabs STT (`scribe_v1`), then Claude streaming (`claude-haiku-4-5`), then ElevenLabs TTS (`eleven_turbo_v2_5`), with WebSocket TTS recommended. | https://platform.claude.com/cookbook/third-party-elevenlabs-low-latency-stt-claude-tts |
| Cascade latency (cookbook) | STT 0.54 s. Claude streaming TTFT 0.71 s (non-streaming 1.03 s). TTS first chunk 0.39 s. Sentence-by-sentence first audio 1.48 s. Measured on Haiku 4.5, not 5.5. | https://platform.claude.com/cookbook/third-party-elevenlabs-low-latency-stt-claude-tts |
| Fast model now | `claude-haiku-5-5` (released 2026-10-07). "Fastest" comparative latency. $0.10 in / $0.50 out per MTok up to 100k-token prompts. Adaptive thinking, default effort `medium`. Omit `temperature`. | https://platform.claude.com/docs/en/models/haiku-5-5/overview |
| Haiku 5.5 TTFT | No official number. UNVERIFIED. Use low effort to reduce latency (inference from the effort docs, not measured). | https://platform.claude.com/docs/en/models/haiku-5-5/overview |
| Other models | Sonnet 5.5 ($2 / $10, "Fast"). Opus 5.5 ($4 / $20, "Moderate"). | https://platform.claude.com/docs/en/about-claude/models/overview |

### 1.4 ElevenLabs

#### 1.4a Agents Platform (formerly Conversational AI; docs now under "eleven-agents")

| Item | Fact | Source |
|---|---|---|
| Transports | WebRTC (default for voice) or WebSocket (default for text-only). `connectionType: 'webrtc' \| 'websocket'`. | https://elevenlabs.io/docs/agents-platform/libraries/java-script |
| Conversation token (WebRTC) | `GET /v1/convai/conversation/token?agent_id=...` with `xi-api-key`, called server-side. Validity is not stated (UNVERIFIED). | https://elevenlabs.io/docs/agents-platform/libraries/java-script |
| Signed URL (WebSocket) | `GET /v1/convai/conversation/get-signed-url?agent_id=...`. Valid for 15 min to start; the session can run longer. | https://elevenlabs.io/docs/agents-platform/customization/authentication |
| Allowlist | Up to 10 origin hostnames, exact match. Do not combine with signed URLs on the same agent. | https://elevenlabs.io/docs/agents-platform/customization/authentication |
| Client tools | Registered in the SDK (`clientTools` in `Conversation.startSession`). They run in the browser. "Wait for response" returns the result to the agent. | https://elevenlabs.io/docs/agents-platform/customization/tools/client-tools |
| Events | `conversation_initiation_metadata` (e.g. output `pcm_44100`, input `pcm_16000`), `audio` (with `alignment`: `chars`, `char_start_times_ms`, `char_durations_ms`; **not sent over WebRTC**), `user_transcript` (final), `agent_response` (complete), `agent_response_correction` (after interrupt), `client_tool_call`, `vad_score`, `agent_chat_response_part`, `agent_response_complete`, `ping`. | https://elevenlabs.io/docs/eleven-agents/customization/events/client-events |
| SDK alignment | The JS SDK has `onAudioAlignment` with character-level timing for agent speech. Whether it works over WebRTC is not stated (UNVERIFIED). | https://elevenlabs.io/docs/agents-platform/libraries/java-script |
| Partial user transcript | The SDK `onMessage` covers "tentative or final transcriptions of user voice". The raw event name is not confirmed (UNVERIFIED). | https://elevenlabs.io/docs/agents-platform/libraries/java-script |
| Audio saving | `platform_settings.privacy.record_voice`. Set it to `false` to disable. Enabled by default. | https://elevenlabs.io/docs/eleven-agents/customization/privacy/audio-saving |
| Retention | `platform_settings.privacy.retention_days`. Default is 2 years. `-1` means forever. `0` schedules deletion. Transcripts and audio have separate settings. | https://elevenlabs.io/docs/agents-platform/customization/privacy/retention |
| Zero Retention Mode | Per agent: no recordings, no PII transcripts or metadata stored. Data only through post-call webhooks. Enterprise-only (UNVERIFIED; the agent page does not state the tier). | https://elevenlabs.io/docs/eleven-agents/customization/privacy/zrm ; https://elevenlabs.io/docs/developer-guides/zero-retention-mode |
| Custom LLM | OpenAI-compatible `/v1/chat/completions` or `/v1/responses`, streamed by SSE. The docs suggest ngrok, so the URL must be reachable from ElevenLabs. | https://elevenlabs.io/docs/eleven-agents/customization/llm/custom-llm |
| Price | $0.08/min. Burst and extra minutes $0.16/min. | https://elevenlabs.io/pricing/api |
| Billing detail | LLM cost is extra. Billed on connection time. Silences over 10 s get a 95% discount (UNVERIFIED, third-party). | https://www.getmacha.com/blog/elevenlabs-agents-pricing-explained ; https://www.cloudzero.com/blog/elevenlabs-pricing/ |

#### 1.4b Standalone TTS with timing

| Item | Fact | Source |
|---|---|---|
| Stream-input WebSocket | `wss://api.elevenlabs.io/v1/text-to-speech/{voice_id}/stream-input`. You stream text in and audio comes out. `AudioOutput` has `audio`, `alignment`, and `normalizedAlignment` (`chars`, `charStartTimesMs`, `charDurationsMs`). Times are relative to the chunk. Other options: `sync_alignment`, `auto_mode`, `flush`, `chunk_length_schedule` (default [120,160,250,290]), and `inactivity_timeout` (default 20 s, max 180). Auth: `xi-api-key`, bearer, or `single_use_token`. | https://elevenlabs.io/docs/api-reference/text-to-speech/v-1-text-to-speech-voice-id-stream-input |
| HTTP stream with timestamps | `POST /v1/text-to-speech/{voice_id}/stream/with-timestamps`. Chunks have `audio_base64`, `alignment` (`characters`, `character_start_times_seconds`, `character_end_times_seconds`), and `normalized_alignment`. | https://elevenlabs.io/docs/api-reference/text-to-speech/stream-with-timestamps |
| Single-use token | `POST /v1/single-use-token/{token_type}`. Types: `realtime_scribe`, `batch_scribe`, `tts_websocket`. Expires after 15 min and is consumed on first use. | https://elevenlabs.io/docs/api-reference/single-use/create |
| TTS price | Per 1K chars: Flash/Turbo $0.04, Multilingual v2 $0.08, v3 $0.08. | https://elevenlabs.io/pricing/api |

#### 1.4c Scribe realtime STT

| Item | Fact | Source |
|---|---|---|
| Model | `scribe_v2_realtime`. Browser flow: the server creates a `realtime_scribe` single-use token (15 min), and the browser connects with the SDK. | https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/client-side-streaming |
| Events | `SESSION_STARTED`, `PARTIAL_TRANSCRIPT`, `COMMITTED_TRANSCRIPT`, `COMMITTED_TRANSCRIPT_WITH_TIMESTAMPS` (with `includeTimestamps: true`). | https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/client-side-streaming |
| Commit | Manual commit is the default. VAD (silence-based) commit is an option. | https://elevenlabs.io/blog/real-time-speech-to-text-under-200ms |
| Audio | PCM 8 to 48 kHz and u-law. The example uses `PCM_16000`. | https://elevenlabs.io/realtime-speech-to-text ; https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/client-side-streaming |
| Latency | About 150 ms model latency, by vendor claim (one page says under 100 ms). | https://elevenlabs.io/realtime-speech-to-text |
| Price | Scribe v2 Realtime $0.39/hour. Scribe v2 batch $0.22/hour. | https://elevenlabs.io/pricing/api |

### 1.5 Other speech-to-speech providers

| Provider | Summary | Source |
|---|---|---|
| Azure OpenAI (Foundry) | Hosts `gpt-realtime-2` (2026-05-07), `gpt-realtime-1.5`, and others over WebRTC and WebSocket. GA paths `/openai/v1/realtime/client_secrets` and `/openai/v1/realtime/calls`. Entra ID is recommended. Azure does not serve GPT-Live. | https://learn.microsoft.com/en-my/Azure/foundry/openai/how-to/realtime-audio-webrtc ; https://pydantic.dev/docs/ai/api/realtime/openai_live/ |
| xAI Grok Voice | `wss://api.x.ai/v1/realtime`, model `grok-voice-latest`, ephemeral tokens. Reportedly a clone of the OpenAI Realtime protocol at about $0.08/min for think-fast-2.0 (price and compatibility UNVERIFIED). | https://docs.x.ai/docs/guides/voice ; https://www.eesel.ai/blog/grok-voice-think-fast-2-pricing |
| Amazon Nova 2 Sonic | Bedrock bidirectional streaming. 8-min connection limit with a renewal pattern. Async tools, barge-in, 7 languages. Price UNVERIFIED (third-party: about $3 / $12 per 1M speech tokens). | https://docs.aws.amazon.com/nova/latest/nova2-userguide/using-conversational-speech.html ; https://rywalker.com/research/aws-nova-2-sonic |
| Mistral Voxtral | No single speech-to-speech endpoint. The official pattern is a cascade: Voxtral Realtime STT, an LLM, then Voxtral TTS. | https://docs.mistral.ai/studio-api/audio/overview |
| Alibaba Qwen | A Qwen-Audio Realtime WebSocket with `server_vad`, `smart_turn`, and manual modes. OpenAI-like events. | https://help.aliyun.com/en/model-studio/qwen-audio-realtime-websocket-api |
| DeepSeek, Kimi (Moonshot) | No native realtime speech API found. UNVERIFIED absence. | (search, no result) |

### 1.6 Output text timing (letter-by-letter reveal)

| Provider / API | Output timing | Granularity | Source |
|---|---|---|---|
| ElevenLabs TTS stream-input WS | Yes: `alignment` / `normalizedAlignment` | Character (ms, relative to the chunk) | https://elevenlabs.io/docs/api-reference/text-to-speech/v-1-text-to-speech-voice-id-stream-input |
| ElevenLabs TTS with-timestamps (HTTP stream) | Yes | Character (s) | https://elevenlabs.io/docs/api-reference/text-to-speech/stream-with-timestamps |
| ElevenLabs Agents | Yes, in the `audio` event over **WebSocket only**. SDK `onAudioAlignment`. | Character | https://elevenlabs.io/docs/eleven-agents/customization/events/client-events ; https://elevenlabs.io/docs/agents-platform/libraries/java-script |
| Cartesia Sonic TTS (WS / SSE) | Yes: `add_timestamps` gives `word_timestamps`, plus `phoneme_timestamps` | Word, phoneme | https://docs.cartesia.ai/api-reference/tts/websocket |
| OpenAI Realtime | No. Only `response.output_audio_transcript.delta` text. | None. The UI must estimate. | https://developers.openai.com/api/docs/guides/realtime-conversations |
| OpenAI GPT-Live | No. Transcript fragments only (third-party adapter). | None | https://pydantic.dev/docs/ai/api/realtime/openai_live/ |
| Gemini Live | No. `outputAudioTranscription` text only. | None | https://ai.google.dev/gemini-api/docs/live-guide |
| xAI | Word timestamps are listed for **STT**, not for voice-agent output. | — | https://docs.x.ai/docs/guides/voice |

**Fallback for native speech-to-speech providers.** Reveal transcript deltas at a rate estimated from the duration of received audio, measured as played audio time. This is a design inference, not a provider feature. For OpenAI over WebSocket, `audio_end_ms` on truncation gives the cut point. Note that the transcript is not realigned.

## 2. Speech-to-text, text-to-speech and browser audio

### 2.1 Browser Web Speech API

| Item | Finding | Source |
|---|---|---|
| Default path | MDN: "By default, using speech recognition on a web page involves a server-based recognition engine. Your audio is sent to a web service for recognition processing, so it won't work offline." | https://developer.mozilla.org/en-US/docs/Web/API/Web_Speech_API/Using_the_Web_Speech_API |
| Chrome cloud | MDN says that on some browsers, "like Chrome", audio goes to a web service. In Chrome this is Google. That it is Google comes only from a secondary source. | https://developer.mozilla.org/docs/Web/API/SpeechRecognition ; https://www.forasoft.com/learn/ai-for-video-engineering/articles-ai/client-side-asr-faster-whisper-wasm-browser |
| Chrome on-device | Chrome 139 (Aug 2025) shipped the "on-device Web Speech API". Sites can query availability per language, ask the user to install the language pack, and make sure that "audio and transcribed speech are not sent to a third-party service". | https://developer.chrome.com/blog/new-in-chrome-139 |
| `processLocally` | Set `recognition.processLocally = true` before `start()`. "When it's false, which is the default, the user agent can choose whether to do the processing locally or remotely." The property is marked experimental. | https://developer.mozilla.org/en-US/docs/Web/API/SpeechRecognition/processLocally |
| Language packs | `SpeechRecognition.available({langs, processLocally})` gives `unavailable`, `available`, `downloadable`, or `downloading`. `SpeechRecognition.install({langs})` gives a boolean. If no pack is installed, `start()` fails with `language-not-supported`. You download a pack one time per language. After that it works offline. The `on-device-speech-recognition` Permissions-Policy (default `self`) controls `available()` and `install()`. | https://developer.mozilla.org/en-US/docs/Web/API/Web_Speech_API/Using_the_Web_Speech_API |
| Quality hint (future) | A W3C TAG review (Feb 2026) proposes a `quality` option with the values command, dictation, and conversation, for on-device recognition. The API can change. | https://tag-github-bot.w3.org/gh/w3ctag/design-reviews/1189 |
| Interim results | `interimResults` controls "whether the speech recognition system should return interim results or only final results". | https://developer.mozilla.org/en-US/docs/Web/API/Web_Speech_API/Using_the_Web_Speech_API |
| Edge | Edge's implementation "uses Azure Cognitive Services, so voice data will leave the machine". A local model is in Edge Canary/Dev 150.0.4076+ behind a flag. Local languages: en-US, de, it, pt-PT, es-ES, ko. A user report (not official) says that cloud recognition failed with "network error" from Edge 134. | https://learn.microsoft.com/th-th/deployedge/microsoft-edge-browser-policies/speechrecognitionenabled ; https://learn.microsoft.com/fi-fi/microsoft-edge/web-platform/speech-recognition-api ; https://learn.microsoft.com/en-us/answers/a/2054895 |
| Safari | The constructor is supported on macOS Safari 14.1+ and iOS 14.5+, through 26.x. `available()` and `phrases` are not supported. Safari's backend (Apple server or on-device): UNVERIFIED. | https://caniuse.com/mdn-api_speechrecognition_speechrecognition ; https://caniuse.com/mdn-api_speechrecognition_available_static |
| Firefox | Not supported through 141. In 142–154 it is present but "disabled by default". It is not supported on Firefox for Android. | https://caniuse.com/mdn-api_speechrecognition_speechrecognition |
| Baseline | MDN says `SpeechRecognition` is not Baseline. | https://developer.mozilla.org/docs/Web/API/SpeechRecognition |
| Chrome on-device language list | UNVERIFIED. No source gave the list. Use `available()` at runtime. | — |

**Privacy note.** Without `processLocally = true`, Chrome and Edge send microphone audio to the vendor's cloud. The skill must tell the user this, or it must require local mode and fall back when it is not available.

### 2.2 Local speech-to-text models

| Engine | Realtime partials? | Install effort | Speed / latency | Source |
|---|---|---|---|---|
| whisper.cpp `whisper-stream` | Yes. It samples the mic every `--step` ms (e.g. 500) over a `--length` window. `--step 0` gives VAD sliding-window mode that prints blocks on silence. | C/C++ build with CMake and SDL2 (`-DWHISPER_SDL2=ON`). The model is a GGML file. | A Raspberry Pi 4 drops audio with the small model. | https://huggingface.co/datasets/echodict/whisper.cpp/blob/main/examples/stream/README.md |
| whisper.cpp `whisper-server` | No. It is request/response: `POST /inference` with a multipart file, and `/load`. The default is `127.0.0.1:8080`. OpenAI compatibility is not stated. | Same build. | — | https://github.com/ggml-org/whisper.cpp/tree/master/examples/server |
| whisper.cpp on Apple Silicon | — | Metal by default. Core ML/ANE encoder needs Python tooling and a model conversion step. The first run is slow because the ANE compiles. | The ANE encoder is ">x3 faster" than CPU-only. Release-note bench: base model encoder ≈71 ms on M1 Pro (Metal), ≈18 ms on M2 Ultra. The column meaning comes from a truncated table, so this is partly UNVERIFIED. | https://github.com/ggml-org/whisper.cpp ; https://fr.github.com/ggerganov/whisper.cpp/releases |
| faster-whisper | Not by itself. It is a batch library and the backend that streaming wrappers use. | `pip install faster-whisper`. No FFmpeg needed. A GPU needs CUDA 12 and cuDNN 9. | "Up to 4 times faster than openai/whisper". On an i7-12700K, the small int8 model does 13 min of audio in ≈1m42s on 8 threads. | https://github.com/SYSTRAN/faster-whisper |
| whisper_streaming (UFAL) | Yes. Uses a local-agreement policy. A TCP server takes 16 kHz S16_LE audio. | pip + faster-whisper (GPU recommended), or MLX on Mac. | 3.3 s latency (paper). The README says that it is "becaming outdated, replaced by SimulStreaming". It points to WhisperLiveKit for a WebSocket/web demo. | https://github.com/ufal/whisper_streaming |
| WhisperLive (Collabora) | Yes. It has `on_partial_transcript` and `on_committed_transcript` callbacks and uses a WebSocket. | `pip install whisper-live` + PortAudio. Docker images are available for CPU, GPU, and OpenVINO. | Calls itself "nearly-live". | https://github.com/collabora/WhisperLive |
| NVIDIA Parakeet TDT 0.6B v3 | Chunked streaming through a NeMo script. | NeMo + PyTorch. Optimized for NVIDIA GPUs. There is also a C++ runtime (NeMo-Speech.cpp). License CC BY 4.0. 25 European languages. | RTFx 3,332 on the Open ASR Leaderboard (hardware not given). | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 |
| Parakeet on CPU | Community INT8 ONNX ports run faster than realtime on CPU in batch mode. The 120M EOU variant streams in 640 ms chunks through ONNX Runtime (secondary source). | pip + onnxruntime | — | https://github.com/groxaxo/parakeet-tdt-0.6b-v3-fastapi-openai ; https://soniqo.audio/guides/parakeet |
| Moonshine (v2 streaming) | Yes. "Optimized for live streaming, with low latency by doing work while the user is still talking." | Lowest: `pip install moonshine-voice`, then `moonshine-voice mic --language en`. Also available for JS/WASM, iOS, Android, and Raspberry Pi. MIT license (non-English legacy models: non-commercial). | Paper: on par with models 4–6x its size. Tiny model: WER 12, RTFx 847. | https://github.com/moonshine-ai/moonshine ; https://arxiv.org/pdf/2602.12241 ; https://huggingface.co/moonshine-ai/moonshine-streaming-tiny |
| Kyutai STT (DSM) | Yes. It is a native streaming model with word timestamps and punctuation. stt-1b-en_fr has a 0.5 s delay and semantic VAD. stt-2.6b-en has a 2.5 s delay. | PyTorch `moshi` (pip), MLX `moshi-mlx` on Mac (mic script included), or a Rust `moshi-server` with CUDA for production. | One H100 handles 400 streams. CPU-only use: UNVERIFIED (probably not practical). | https://kyutai.org/stt ; https://github.com/kyutai-labs/delayed-streams-modeling |

**Summary.** No local engine is "zero install". The lowest-effort engine with true streaming is Moonshine (one pip command, CPU-friendly, MIT). whisper.cpp is the most portable native binary, but its streaming is a mic-only CLI and its server does not stream.

### 2.3 OS dictation tools (text-only mode)

These tools type into the focused text field of any app. A text-only mode with a focused `<textarea>` therefore works with all of them, with no extra code.

| Tool | Local or cloud | Source |
|---|---|---|
| macOS Dictation | The Keyboard settings show if voice input is "processed on your device and not sent to Siri servers". Secondary sources say that on Apple silicon, general dictation is on-device for supported languages and dictation into search boxes still uses a server. The Apple silicon detail is UNVERIFIED from Apple. | https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac ; https://spokenly.app/blog/how-to-use-dictation-on-mac |
| Windows voice typing (Win+H) | It starts only when a text field has focus. Cloud or offline: the sources disagree (secondary), so this is UNVERIFIED. Voice Access downloads a local model. | https://mcmw.abilitynet.org.uk/how-to-use-voice-typing-in-windows-11 ; https://www.yaps.ai/blog/voice-typing-windows.md |
| Superwhisper | macOS/iOS. It types at the cursor through a hotkey. Local Whisper or Parakeet models are optional (secondary). | https://spokenly.app/blog/superwhisper-vs-wispr-flow |
| Wispr Flow | Mac, Windows, iOS. Cloud-only, "no offline mode at any price" (secondary). | https://getvext.app/blog/wispr-flow-alternatives.md ; https://clickup.com/blog/wispr-flow-vs-superwhisper/ |

**Design note.** The text field must keep focus. Do not steal focus with live-updated elements, and do not clear the field while the user dictates.

### 2.4 Echo cancellation and 16 kHz capture

- `echoCancellation` is Baseline since Jan 2020. The values are `true`, `false`, `"all"`, and `"remote-only"`. With `true`, the browser must cancel at least remote peer audio and "should attempt" to cancel all system audio. https://developer.mozilla.org/en-US/docs/Web/API/MediaTrackConstraints/echoCancellation
- Chrome uses hardware AEC when the hardware has it, else software AEC that "uses an internal loopback to get the playout audio". https://developer.chrome.com/blog/more-native-echo-cancellation/
- **Caveat.** A vendor reports that Chromium does *not* apply AEC to Web Audio API output, only to `<audio>`/media elements (and WebRTC). Safari and Firefox do apply it. The Chromium issue is long open; current status UNVERIFIED. **Play assistant audio through an `<audio>` element, not through an AudioContext graph.** https://docs.atmoky.com/known-issues ; https://lists.w3.org/Archives/Public/public-webrtc-logs/2019Apr/0334.html
- **16 kHz PCM.** Use `new AudioContext({sampleRate: 16000})`, then MediaStreamSource → AudioWorklet, and convert Float32 to Int16. Batch the 128-sample blocks into chunks of about 100 ms. The browser resamples. Check `audioContext.sampleRate` after you create it. ScriptProcessorNode is deprecated. https://www.mintlify.com/AssemblyAI/realtime-transcription-browser-js-example/guides/audio-worklet ; https://velog.io/@taegyeong0320/web-audio-api-mic-to-pcm ; https://developer.invoxmedical.com/ai-services/streaming-transcription/streaming-guide

### 2.5 Text-to-speech without a vendor

| Option | One-line verdict | Source |
|---|---|---|
| Browser `speechSynthesis` | Zero install and Baseline since Sep 2018. Voices depend on the device, and the list loads asynchronously (`voiceschanged`). Quality varies by OS, and some voices can be remote (`localService`): UNVERIFIED per browser. | https://developer.mozilla.org/en-US/docs/Web/API/SpeechSynthesis |
| Piper | "Fast and local neural text-to-speech". `pip install piper-tts`. GPL-3.0 (the new repo). Has an HTTP server doc. Latency numbers: UNVERIFIED. | https://github.com/OHF-Voice/piper1-gpl |
| Kokoro-82M | 82M params, Apache-2.0, 8 languages and 54 voices. "Comparable quality to larger models". `pip install kokoro` + system `espeak-ng`. CPU latency: UNVERIFIED. | https://huggingface.co/hexgrad/Kokoro-82M |

## 3. Agents: skills, fork, delivery

### 3.1 Skill portability

#### 3.1.1 The open standard

| Fact | Source | Label |
|---|---|---|
| Agent Skills is "a lightweight, open format". A skill is a folder with `SKILL.md`. Minimum metadata is `name` and `description`. Optional dirs: `scripts/`, `references/`, `assets/`. | https://agentskills.io (2026-10-10) | VERIFIED-DOC |
| Anthropic made the format, then released it as an open standard. Spec repo: github.com/agentskills/agentskills. | https://agentskills.io (2026-10-10) | VERIFIED-DOC |
| Loading is "progressive disclosure": name+description at startup, full `SKILL.md` on activation, scripts and files on demand. | https://agentskills.io (2026-10-10) | VERIFIED-DOC |
| Listed adopters include: Claude Code, Claude, ChatGPT & Codex, Gemini CLI, Cursor, GitHub Copilot, VS Code, OpenCode, OpenHands, Amp, Goose, Junie, Roo Code, Factory, Kiro, Letta, Mistral Vibe, Tabnine, pi, and more. | https://agentskills.io (2026-10-10) | VERIFIED-DOC |

#### 3.1.2 Per-agent locations and invocation

| Agent | Skill directories it reads | User invocation | Source |
|---|---|---|---|
| Claude Code | `~/.claude/skills/<n>/SKILL.md`, `.claude/skills/`, plugin `skills/`, managed dir. No `.agents/skills` listed. | `/talk` (slash). `disable-model-invocation: true` makes it user-only. | https://code.claude.com/docs/en/skills (2026-10-10) VERIFIED-DOC |
| Codex | `$CWD/.agents/skills` (up to repo root), `$REPO_ROOT/.agents/skills`, `$HOME/.agents/skills`, `/etc/codex/skills`, system skills. Doc does not list `~/.codex/skills` (this host still has one; legacy behavior UNVERIFIED). Follows symlinks. | `$talk` in prompt, or `/skills`. `agents/openai.yaml` `policy.allow_implicit_invocation: false` makes it explicit-only. | https://learn.chatgpt.com/docs/build-skills (2026-10-10) VERIFIED-DOC |
| Gemini CLI | `~/.gemini/skills/`, `~/.agents/skills/`, `.gemini/skills/`, `.agents/skills/`, extension skills. `.agents/skills` wins over `.gemini/skills` in the same tier. | No per-skill slash command. Model calls `activate_skill`; user gets a consent prompt. `/skills` only manages (list, link, enable, disable, reload). | https://geminicli.com/docs/cli/skills/ (2026-10-10) VERIFIED-DOC; `gemini skills` subcommand exists VERIFIED-HELP 0.62.0 |
| Cursor | `.agents/skills/`, `.cursor/skills/`, `~/.agents/skills/`, `~/.cursor/skills/`, plus compat `.claude/skills/`, `.codex/skills/`, `~/.claude/skills/`, `~/.codex/skills/`. | `/talk` in Agent chat. Supports `disable-model-invocation: true`. | https://cursor.com/docs/context/skills (2026-10-10) VERIFIED-DOC |
| GitHub Copilot (CLI, cloud agent, VS Code, JetBrains) | Project: `.github/skills`, `.claude/skills`, `.agents/skills`. Personal: `~/.copilot/skills`, `~/.agents/skills`. | Not checked. UNVERIFIED. | https://docs.github.com/en/copilot/concepts/agents/about-agent-skills (2026-10-10) VERIFIED-DOC |
| OpenCode | `.opencode/skills`, `~/.config/opencode/skills`, `.claude/skills`, `~/.claude/skills`, `.agents/skills`, `~/.agents/skills`. | Model calls the `skill` tool. Slash invocation not documented. | https://opencode.ai/docs/skills/ (2026-10-10) VERIFIED-DOC |
| Antigravity CLI (`agy`, Gemini CLI successor) | Google says Agent Skills, Hooks and Subagents carry over. Paths UNVERIFIED. Third-party cheat sheet lists `/skills`. | UNVERIFIED | https://developers.googleblog.com/en/an-important-update-transitioning-gemini-cli-to-antigravity-cli/ (2026-10-10) VERIFIED-DOC for "skills carry over"; https://www.scriptbyai.com/antigravity-cli-cheatsheet/ SECONDARY |

Design result: put the real skill in `~/.agents/skills/talk/`. Symlink `~/.claude/skills/talk` to it. Cursor and OpenCode read both, so they could show it twice. Test for a duplicate before you ship (UNVERIFIED).

#### 3.1.3 Frontmatter portability

- Spec-safe keys: `name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`. Claude Code says: outside Claude Code (claude.ai, Skills API) only these keys are allowed; other keys are a hard error. https://code.claude.com/docs/en/skills (2026-10-10) VERIFIED-DOC
- OpenCode: `name` must be 1-64 lowercase alphanumerics with single hyphens and must match the directory name. `description` 1-1024 chars. Unknown keys are ignored. https://opencode.ai/docs/skills/ (2026-10-10) VERIFIED-DOC
- Claude-only keys (`disable-model-invocation`, `argument-hint`, `context`, `hooks`, `model` ...) are ignored by Claude Code's own rules when unknown, but they can break the claude.ai upload path. Keep them out if you also publish to claude.ai.

#### 3.1.4 Bundled scripts

| Agent | How the skill finds its own scripts | Source |
|---|---|---|
| Claude Code | `${CLAUDE_SKILL_DIR}` substitution. Also `${CLAUDE_SESSION_ID}` substitution in skill text. `` !`cmd` `` runs a command before the prompt goes to Claude. `allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/x.sh *)` removes the permission prompt. | https://code.claude.com/docs/en/skills (2026-10-10) VERIFIED-DOC |
| Cursor | Paths relative to the skill root, such as `scripts/deploy.sh`. | https://cursor.com/docs/context/skills (2026-10-10) VERIFIED-DOC |
| Codex | `scripts/` dir; no path variable documented. | https://learn.chatgpt.com/docs/build-skills (2026-10-10) VERIFIED-DOC |
| Gemini CLI | On activation the skill dir becomes an allowed path; the agent can read bundled files. No auto-run. | https://geminicli.com/docs/cli/skills/ (2026-10-10) VERIFIED-DOC |

Design result: make one launcher script, for example `scripts/talk-launch`. It must detect the host agent itself: `CLAUDECODE=1` / `CLAUDE_CODE_SESSION_ID` for Claude Code; `CODEX_THREAD_ID` for Codex. Write `SKILL.md` text that tells the agent "run `<skill dir>/scripts/talk-launch` in the background". Do not depend on `${CLAUDE_SKILL_DIR}` in the shared text. Use a relative path plus a Claude-only `!` line if needed.

### 3.2 Native session fork per agent CLI

#### 3.2.1 Claude Code (2.1.296)

| Item | Fact | Source / label |
|---|---|---|
| Fork flag | `--fork-session`: "When resuming, create a new session ID instead of reusing the original (use with --resume or --continue)". Example `claude --resume abc123 --fork-session`. | https://code.claude.com/docs/en/cli-reference (2026-10-10) VERIFIED-DOC; VERIFIED-HELP 2.1.296 |
| In-session fork | `/branch [name]`. Copies the transcript and switches the running process into the copy. | https://code.claude.com/docs/en/sessions (2026-10-10) VERIFIED-DOC |
| SDK fork | `forkSession: true` (TS) / `fork_session=True` (Python) with `resume: <id>`. "The original stays unchanged." Forks branch the conversation, not the filesystem. | https://code.claude.com/docs/en/agent-sdk/sessions (2026-10-10) VERIFIED-DOC |
| Session id from inside | `CLAUDE_CODE_SESSION_ID`: "Set automatically to the current session ID in Bash and PowerShell tool subprocesses, hook command subprocesses, and stdio MCP server subprocesses." Updated on `/clear`. An MCP server keeps the ID it was spawned with. | https://code.claude.com/docs/en/env-vars (2026-10-10) VERIFIED-DOC. Also present in this subagent's own env (names only checked). |
| Also | `${CLAUDE_SESSION_ID}` substitution in skill text. Hook JSON input has `session_id` and `transcript_path`. | https://code.claude.com/docs/en/skills ; https://code.claude.com/docs/en/sessions (2026-10-10) VERIFIED-DOC |
| Transcript | `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, "saved continuously". Format is internal and can change. | https://code.claude.com/docs/en/sessions (2026-10-10) VERIFIED-DOC |
| Cross-dir lookup | `--resume <id>` searches the current project, then every project (v2.1.223+). | same |
| Fork while live | Docs: "If you resume the same session in two terminals without forking, messages from both interleave into one transcript." So always fork. A running **background** session: `--resume` attaches unless you "Add `--fork-session` to resume a copy of the conversation instead". | https://code.claude.com/docs/en/sessions (2026-10-10) VERIFIED-DOC |
| Fork mid-turn | Not documented for a foreground interactive session that is mid-turn. The transcript is written continuously, so a fork sees history up to the last written entry. Resume marks a tool call that has no recorded result as "cut off" ("Claude sees the call marked as cut off before its result was recorded"). Expect the fork to see an unfinished last turn. | UNVERIFIED for mid-turn; resume cut-off behavior VERIFIED-DOC (sessions page) |
| Read-only fork | Combine: `--permission-mode plan`; `--tools "Read,Grep,Glob"` (removes others; `""` removes all built-ins); `--disallowedTools "Edit Write Bash mcp__*"`; `--permission-prompts none` (denies prompts in `-p`, v2.1.259+); `--no-session-persistence` (fork not saved). Note: `--fork-session` does not restore plan mode, so pass the mode on the command line. | https://code.claude.com/docs/en/cli-reference ; https://code.claude.com/docs/en/sessions (2026-10-10) VERIFIED-DOC |
| Low-latency fork process | `-p --input-format stream-json --output-format stream-json --include-partial-messages` keeps one process open for many questions and streams tokens. | https://code.claude.com/docs/en/cli-reference (2026-10-10) VERIFIED-DOC |
| Hazard | `--bare` skips OAuth and keychain; it needs `ANTHROPIC_API_KEY` or `apiKeyHelper`. `--bare` also binds no inbox socket. | VERIFIED-HELP 2.1.296; https://code.claude.com/docs/en/cross-session-messaging (2026-10-10) |

Example (not run):
```
claude -p --resume "$CLAUDE_CODE_SESSION_ID" --fork-session --no-session-persistence \
  --permission-mode plan --tools "Read,Grep,Glob" --disallowedTools "mcp__*" \
  --permission-prompts none --input-format stream-json --output-format stream-json \
  --include-partial-messages --verbose
```

Alternative inside the live agent: Claude Code also has forked subagents (`context: fork` skills, "fork the current conversation"). These run inside the live process and cost the live agent's context. Not a good fit for "agent keeps working". https://code.claude.com/docs/en/skills (2026-10-10) VERIFIED-DOC

#### 3.2.2 Codex CLI (0.160.0)

| Item | Fact | Source / label |
|---|---|---|
| CLI fork | `codex fork [SESSION_ID] [PROMPT]` (interactive), `codex exec fork <SESSION_ID> [PROMPT]` (non-interactive) with `--ephemeral`, `--json`. | VERIFIED-HELP 0.160.0; https://learn.chatgpt.com/docs/developer-commands.md?surface=cli (2026-10-10) VERIFIED-DOC |
| Do not use | `codex exec resume <id>` appends to the original thread. Use `exec fork`. | VERIFIED-HELP 0.160.0 |
| In-session | `/fork`; `/side` and `/btw` = "ephemeral fork from the current chat without switching away", and the TUI keeps showing parent status. | https://learn.chatgpt.com/docs/developer-commands.md?surface=cli (2026-10-10) VERIFIED-DOC |
| App-server fork | `thread/fork`: copies stored history to a new thread id. `ephemeral: true` = in-memory, not listed. Overrides: `sandbox`, `approval_policy`, `developer_instructions`, `model`, etc. `last_turn_id` "cannot be in progress". Doc: mid-turn without `lastTurnId`, "the fork records an interruption marker". `experimentalPredictionMode` reuses the parent's prompt cache (needs loaded persisted parent and `ephemeral: true`). | https://learn.chatgpt.com/docs/app-server (2026-10-10) VERIFIED-DOC; `codex-rs/app-server-protocol/src/protocol/v2/thread.rs` VERIFIED-SRC |
| Thread id from inside | `CODEX_THREAD_ID` is injected into tool shell environments "even when `include_only` is set". There is also `CODEX_SESSION_ID_ENV_VAR`. | `codex-rs/core/src/exec_env.rs` VERIFIED-SRC. Not found in user docs. |
| Shared daemon | `codex agents` = "Browse all agent sessions on the shared local app-server daemon". `daemon_auto_start` feature is stable/on. `codex app-server proxy --sock` connects to the control socket. `--listen unix://` uses the default control socket. | VERIFIED-HELP 0.160.0; https://learn.chatgpt.com/docs/app-server (2026-10-10) |
| Read-only fork | App-server: `sandbox: "read-only"` on `thread/fork`, or per-turn `sandboxPolicy` readOnly. CLI: `codex exec -s read-only`; `exec fork` help does not list `-s`, so use `-c sandbox_mode="read-only"` (UNVERIFIED that it applies to `exec fork`). | VERIFIED-DOC / VERIFIED-HELP; one item UNVERIFIED |

#### 3.2.3 Gemini CLI (0.62.0)

| Item | Fact | Source / label |
|---|---|---|
| Sessions | Auto-saved in `~/.gemini/tmp/<project_hash>/chats/`. `--resume latest|<index>|<UUID>`, `/resume` browser. | https://geminicli.com/docs/cli/session-management/ (2026-10-10) VERIFIED-DOC; VERIFIED-HELP 0.62.0 |
| Checkpoints | `/resume save <tag>`, `/resume list`, `/resume resume <tag>`; `/chat` alias. "For named branch points inside a session". | same, VERIFIED-DOC |
| Fork | No native fork. | VERIFIED-DOC (absence on the page) |
| Workaround | `--session-file <json>` loads a session from a JSON file. `--session-id <uuid>` starts with a given id. Copy the chat file, then `gemini --session-file copy.json --approval-mode plan -p "..."`. | flags VERIFIED-HELP 0.62.0; workflow UNVERIFIED |
| Session id from inside | Not found. Hook input may carry it. | UNVERIFIED |
| Read-only | `--approval-mode plan` = "read-only mode". | VERIFIED-HELP 0.62.0 |
| Status | Gemini CLI stopped serving Google AI Pro/Ultra and free individual users on 2026-06-18. It still works with paid Gemini API keys and enterprise licenses. Antigravity CLI replaces it. | https://developers.googleblog.com/en/an-important-update-transitioning-gemini-cli-to-antigravity-cli/ (2026-10-10) VERIFIED-DOC |
| Antigravity CLI | Third-party cheat sheet lists `/fork` (`/branch`), `-c`, `--conversation <id>`, `-p`. | https://www.scriptbyai.com/antigravity-cli-cheatsheet/ (2026-10-10) SECONDARY / UNVERIFIED |

#### 3.2.4 Others

| Agent | Fork / share | Read-only | Source |
|---|---|---|---|
| OpenCode | Server API: `POST /session/:id/fork` (`messageID?`), `POST /session/:id/message`, `POST /session/:id/prompt_async`, `POST /session/:id/abort`, `POST /session/:id/share`, `GET /event` (SSE). The TUI runs its own server on a random port (set with `--port`). CLI: `opencode run --session <id> --fork`. | Not checked: use a read-only agent/permissions config (UNVERIFIED). | https://opencode.ai/docs/server/ (2026-10-10) VERIFIED-DOC; VERIFIED-HELP 1.17.10 |
| Cursor CLI | `cursor-agent --resume <id>`, `cursor-agent ls`. No native fork; users ask for one on the forum. | UNVERIFIED | https://forum.cursor.com/t/fork-session-or-duplicate-chat-in-cursor-cli/149498 (2026-10-10) SECONDARY |
| Aider | No sessions. `--restore-chat-history`, `--chat-history-file` (`.aider.chat.history.md`). No fork. | n/a | https://aider.chat/docs/config/options.html (2026-10-10) VERIFIED-DOC |

### 3.3 Delivering a message into a running session

#### 3.3.1 Claude Code, ranked by reliability

| Rank | Mechanism | Idle session | Busy (mid-turn) | Notes | Source |
|---|---|---|---|---|---|
| 1 | **Inbox socket** (`CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_CODE_MESSAGING_TOKEN`) | "Claude Code starts a new turn with the message" | "reads the message between tool calls during an active turn, so a running tool is never interrupted" | v2.1.224+ macOS/Linux. On by default. Own-child messages (from a hook or Bash command of this session) are delivered when no `crossSessionInbound` value applies. Linux verifies by process evidence even after the child exits; the token auth line also verifies. A bypass-permissions session holds unverified messages for approval. `--bare` sessions bind no socket. Connection closes after 30 s without a complete line. Max 50 queued, ~1M chars. Message is shown to Claude as from "another session", not the user: it "can't approve anything" and "can't change configuration". | https://code.claude.com/docs/en/cross-session-messaging (2026-10-10) VERIFIED-DOC |
| 1a | Wire format of that socket | | | Doc gives only the auth line `{"type":"auth","token":"<token>"}`. The 2.1.296 binary contains this example: `{ echo '{"type":"auth","token":"'"$CLAUDE_CODE_MESSAGING_TOKEN"'"}'; echo '{"type":"user","message":{"role":"user","content":"hello"}}'; } \| socat - UNIX-CONNECT:<socket>` | Binary string, Claude Code 2.1.296. UNDOCUMENTED; test it. |
| 2 | Channels (MCP server push, `notifications/claude/channel`) | Arrives in the open session | Arrives in the open session | Research preview. Must start the session with `--channels plugin:...` (allowlisted) or `--dangerously-load-development-channels server:<name>`. So /talk can not add it to a session that is already running. Needs claude.ai or Console auth. Team/Enterprise must set `channelsEnabled`. Two-way reply tool and permission relay supported. | https://code.claude.com/docs/en/channels (2026-10-10) VERIFIED-DOC |
| 3 | Background Bash task or Monitor started by the agent | Background task end wakes the agent (behavior seen in practice; doc says notes appear) | Monitor "feeds each output line back to Claude ... Claude interjects when an event arrives" | Monitor deadline: 5 min default, 30 min max, then one notice; agent must re-arm. Monitor also takes a `ws` WebSocket source (one event per text message). Not on Bedrock/Vertex/Foundry, or with `DISABLE_TELEMETRY`. Plugins can declare auto-start monitors. Depends on the agent to start and re-arm it. | https://code.claude.com/docs/en/tools-reference (2026-10-10) VERIFIED-DOC |
| 4 | Hooks + inbox file | `Stop` hook: `decision:"block"` + `reason` keeps Claude going (cap 8 continuations in a row; resets on tool call). `asyncRewake: true` hook runs in background and "wakes Claude on exit code 2" with stderr as a system reminder. | `PostToolUse` / `PostToolBatch` `additionalContext` is inserted next to the tool result. | Hooks must be in settings or the skill's `hooks` frontmatter; settings changes may need a restart (UNVERIFIED for mid-session). Polling an inbox file from PostToolUse is simple and robust while the agent works. | https://code.claude.com/docs/en/hooks (2026-10-10) VERIFIED-DOC |
| 5 | Remote Control | Yes | Yes | You drive the session from claude.ai or the app. Needs claude.ai login. Not a local API. | https://code.claude.com/docs/en/channels (comparison table) (2026-10-10) VERIFIED-DOC |
| 6 | `claude --resume <bg-id> "prompt"` | Sends prompt as next turn to a **background** session | Same | Only for `--bg` sessions; a prompt starting with `/` or `!` is not sent. | https://code.claude.com/docs/en/sessions (2026-10-10) VERIFIED-DOC |

Recommendation: the /talk launcher runs as a child of the agent's Bash tool. It inherits `CLAUDE_CODE_MESSAGING_SOCKET` and `CLAUDE_CODE_MESSAGING_TOKEN`. Store both at launch. Post confirmed instructions as own-child messages. Fallback: PostToolUse + Stop hook reading an inbox file.

Trust note: socket messages arrive labeled as from another session. The receiving Claude is told they are not user consent. For /talk this is acceptable for "instructions", but Claude can refuse to treat them as user approval. Wrap them as "The user said by voice: ...". Test how Claude treats them (UNVERIFIED).

#### 3.3.2 Codex, ranked

| Rank | Mechanism | Behavior | Source |
|---|---|---|---|
| 1 | `codex queue --thread <CODEX_THREAD_ID> --message "<text>"` | Calls `thread/queue/add` on the shared local daemon. Refuses `--no-daemon`: "Queuing must discover the shared server to avoid writing through a separate server." Experimental. Queued items run as the next turn (TUI docs: Tab "queue a follow-up ... for the next turn"); exact drain timing UNVERIFIED. | VERIFIED-HELP 0.160.0; `codex-rs/tui/src/session_queue_commands.rs`, `protocol/common.rs` VERIFIED-SRC; https://learn.chatgpt.com/docs/developer-commands.md?surface=cli (2026-10-10) |
| 2 | App-server `turn/steer` | "append user input to the active in-flight turn"; needs `expectedTurnId`; fails if no turn is active. Use `turn/start` when idle. Connect through the daemon control socket (`codex app-server proxy`). Whether the user's TUI thread is visible to a second client: likely (subscriber model, `codex agents`), UNVERIFIED. | https://learn.chatgpt.com/docs/app-server (2026-10-10) VERIFIED-DOC |
| 3 | Hooks | Events: PreToolUse, PermissionRequest, PostToolUse, PreCompact, PostCompact, UserPromptSubmit, SubagentStop, Stop, Interrupt, SessionStart, SubagentStart, SessionEnd. `Stop` with `decision:"block"` + `reason` "tells Codex to continue and automatically creates a new continuation prompt". `additionalContext` on SessionStart, SubagentStart, PreToolUse, PostToolUse, UserPromptSubmit. `async: true` (max 8) output "delivered at the next safe point". Non-managed hooks need trust review (`/hooks`). | https://learn.chatgpt.com/docs/hooks (2026-10-10) VERIFIED-DOC |
| 4 | `notify` config | Runs a program on events (outbound only). Not checked in docs. | UNVERIFIED |

#### 3.3.3 Gemini CLI

| Mechanism | Behavior | Source |
|---|---|---|
| `AfterAgent` hook `decision:"deny"` + `reason` | Rejects the response and "force[s] a retry"; `reason` is sent as a new prompt. Use it to inject an inbox message at turn end. | https://geminicli.com/docs/hooks/reference/ (2026-10-10) VERIFIED-DOC |
| `BeforeAgent` / `AfterTool` `hookSpecificOutput.additionalContext` | Appended to the turn prompt / tool result. Inbox-file polling works while it works. | same |
| No socket or external API documented for the interactive TUI. `--acp` exists, but only when Gemini runs under an ACP client. | | https://geminicli.com/docs/hooks/ (2026-10-10) VERIFIED-DOC; VERIFIED-HELP 0.62.0 |
| Idle wake | No mechanism found. An idle Gemini session cannot be woken from outside. | UNVERIFIED (absence) |

#### 3.3.4 OpenCode

`POST /session/:id/prompt_async` or `/tui/append-prompt` + `/tui/submit-prompt` on the TUI's own server. Best external API of all CLIs, but the port is random unless set. https://opencode.ai/docs/server/ (2026-10-10) VERIFIED-DOC

### 3.4 Subscription versus API key

#### 3.4.1 Claude

| Fact | Source |
|---|---|
| OAuth "is intended exclusively for purchasers of Claude Free, Pro, Max, Team, and Enterprise subscription plans and is designed to support ordinary use of Claude Code and other native Anthropic applications." | https://code.claude.com/docs/en/legal-and-compliance (2026-10-10) VERIFIED-DOC |
| "Developers building products or services ... including those using the Agent SDK, should use API key authentication ... Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, or Max plan credentials on behalf of their users." Enforcement "without prior notice". | same |
| It "does not ... prevent an end user from signing in to the unmodified Claude Code binary with their own Claude subscription". | same |
| "Advertised usage limits for Pro and Max plans assume ordinary, individual usage of Claude Code and the Agent SDK." | same |
| Agent SDK: "Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent SDK." | https://code.claude.com/docs/en/agent-sdk/overview (2026-10-10) VERIFIED-DOC |
| `claude setup-token` makes a 1-year OAuth token for "CI pipelines, scripts" (`CLAUDE_CODE_OAUTH_TOKEN`). Needs Pro/Max/Team/Enterprise. `--bare` does not read it. | https://code.claude.com/docs/en/authentication (2026-10-10) VERIFIED-DOC |

Reading: a user's own /talk that shells out to the unmodified `claude -p` with their own login is inside "ordinary, individual usage" in spirit. A published /talk that calls the Messages API with a subscription token, or that is sold to others, is not allowed. The fork call (`claude -p --resume --fork-session`) runs the official binary, so it is the safest subscription path. The fast voice LLM itself should use an API key or a realtime provider key. Exact line for a personal tool: UNVERIFIED; ask Anthropic for a product.

#### 3.4.2 Codex / OpenAI

| Fact | Source |
|---|---|
| Codex sign-in: ChatGPT (subscription) or API key (usage-based). | https://learn.chatgpt.com/docs/auth.md (2026-10-10) VERIFIED-DOC |
| "Use API key authentication for programmatic Codex CLI workflows, such as CI/CD jobs." ChatGPT-auth in CI is "advanced"; "API keys are still the recommended default for automation." | same |
| Enterprise: Codex access tokens for "trusted, non-interactive Codex local workflows". | same |
| Realtime voice may need an API key, not ChatGPT OAuth. | https://codex-sdk.hexdocs.pm/06-realtime-and-voice.html SECONDARY / UNVERIFIED |

### 3.5 Fork latency

No measured number found for `claude -p` or `codex exec` cold start. UNVERIFIED.
What is known:
- A cold `claude -p` process must start, load settings, CLAUDE.md, plugins, MCP servers, then send the whole forked history. `--bare` is faster but needs an API key. https://code.claude.com/docs/en/cli-reference (2026-10-10)
- A resumed session that is idle for about 1 hour and over 100k tokens has an expired prompt cache; the next request "processes the full history once". https://code.claude.com/docs/en/sessions (2026-10-10) VERIFIED-DOC. A fork taken while the live agent works should hit the warm cache of the live session (UNVERIFIED that fork shares cache prefix).
- Codex `thread/fork` `experimentalPredictionMode` exists "to maximize prompt-cache reuse". VERIFIED-SRC.
- Third-party per-turn estimate: 2-4 s per model turn on a ~100k-token session. https://fast.inference.net/guides/why-is-claude-code-slow (2026-10-10) SECONDARY.
Design result: the fork is too slow for the voice turn. Use a realtime voice model for chat (sub-second). Send deep questions to a warm, long-lived fork process (`--input-format stream-json`) and say "let me check" while it works. Measure TTFT on the target host before you set UX timing.

### 3.6 Gaps to test before build

1. Claude inbox socket line format (`{"type":"user",...}`) and how Claude labels and trusts a /talk message.
2. Claude fork of a foreground session that is mid-tool-call: what the fork sees.
3. Codex: is the user's TUI thread reachable from a second daemon client for `turn/steer` and `thread/fork`? Does `codex queue` drain at turn end or steer?
4. Codex realtime auth with ChatGPT login.
5. Gemini: session id inside a session; `--session-file` copy as a fork.
6. Duplicate skill listing in Cursor/OpenCode when both `~/.agents/skills` and `~/.claude/skills` hold `talk`.
7. TTFT of `claude -p --resume --fork-session` and `codex exec fork --ephemeral` on this host.

## 4. Safe local launch

### 4.1 Bind, port and token

| Tool | Default bind | Auth model | Source |
|---|---|---|---|
| Jupyter Server | localhost | A token is on by default. It goes in the URL query (`?token=`), the `Authorization` header, or a login form. After the first visit "a cookie will be set in your browser and you won't need to use the token again". A new port needs a new cookie. | https://jupyter-server.readthedocs.io/en/latest/operators/security.html |
| Jupyter Host check | — | Requests get 403 if the Host header is not local (DNS-rebinding defence). `allow_remote_access=False` is the default. `local_hostnames=['localhost']`. 127.0.0.1 and ::1 are always accepted. | https://gh.nn.ci/jupyter/notebook/releases/tag/5.6.0 (mirror of the release notes) |
| VS Code `serve-web` | — | `--connection-token` / `--connection-token-file`. `--without-connection-token` is only for when "the connection is secured by other means" (secondary/mirror docs). | https://mintlify.wiki/microsoft/vscode/cli/commands ; https://learn.arm.com/install-guides/vscode-remote/ |
| Vite dev server | localhost | No token for HTTP. After CVE-2025-24010 (fixed in 6.0.9 / 5.4.12 / 4.5.6), Vite added a Host-header check (`server.allowedHosts`), set `server.cors` to `false` by default, and added a token check on the HMR WebSocket. | https://github.com/vitejs/vite/security/advisories/GHSA-vg6x-rcgg-rjx6 |
| Ollama | `127.0.0.1:11434` | No token. CORS allows only 127.0.0.1 and 0.0.0.0 origins by default (`OLLAMA_ORIGINS` adds more). CVE-2024-28224: DNS rebinding gave full API access before 0.1.29. | https://docs.ollama.com/faq ; https://www.nccgroup.com/research/technical-advisory-ollama-dns-rebinding-attack-cve-2024-28224/ |
| ComfyUI | `127.0.0.1` (`--listen` with no value binds all interfaces) | No authentication. The policy says "anyone with access to the ComfyUI URL is trusted". The CORS header is off by default. | https://docs.comfy.org/development/comfyui-server/startup-flags ; https://raw.githubusercontent.com/Comfy-Org/ComfyUI/master/SECURITY.md |
| Gradio | `127.0.0.1:7860` | Optional `auth=(user, pass)`. `share=True` makes a public tunnel URL that "anyone can use". | https://www.gradio.app/guides/environment-variables ; https://gradio.app/sharing_your_app |

**Token location.**
- A token in the query string leaks to the Referer header, server logs, browser history, and cache. "Simply using HTTPS does not resolve this vulnerability." (OWASP)
- A fragment (`#t=...`) is not sent to the server, so it does not go into server logs or the Referer header. But it stays in history and in copied links.

Source: https://owasp.org/www-community/vulnerabilities/Information_exposure_through_query_strings_in_url ; https://codemia.io/knowledge-hub/path/get_request_part_after_hash_sign

**Recommended pattern** (this is a synthesis, not a quote):
1. Bind 127.0.0.1 only. Ask the OS for a free port (port 0).
2. Make a 128-bit random one-time code. Put it in the URL (path or query).
3. On the first GET, exchange the code for an `HttpOnly; SameSite=Strict` cookie. Then 302 to a clean URL and send `Referrer-Policy: no-referrer`. Mark the code as used.
4. Require the cookie on all HTTP and WebSocket requests.

This is Jupyter's model, made stronger with single-use codes.

### 4.2 DNS rebinding, WebSocket Origin, CSRF

- **DNS rebinding.** An attacker page changes its DNS record to 127.0.0.1 and then reads your local server. The defence is a Host-header allowlist (`127.0.0.1:<port>`, `localhost:<port>`), as Jupyter and Vite do. The Vite advisory says the attack works "even if you only run the dev server on your own machine". https://github.com/vitejs/vite/security/advisories/GHSA-vg6x-rcgg-rjx6 ; https://www.nccgroup.com/research/technical-advisory-ollama-dns-rebinding-attack-cve-2024-28224/
- **WebSocket.** The WebSocket protocol does not check the origin. The browser sends cookies on the upgrade request, so a server that does not check the origin can be hijacked (CSWSH, CWE-1385). Check `Origin` against an exact allowlist, and also check a session token. https://owasp.org/www-project-web-security-testing-guide/latest/4-Web_Application_Security_Testing/11-Client-side_Testing/10-Testing_WebSockets ; https://christian-schneider.net/CrossSiteWebSocketHijacking.html
- **CSRF.** Do the same for state-changing POSTs: Origin check + SameSite=Strict cookie, and no CORS headers. (This is a synthesis from the Vite fix of `cors: false`.)
- **Chrome Local Network Access (LNA).** Chrome 142+ shows a prompt when a *public* page requests a loopback address (secondary sources say this is enforced from 142). A page that the local server itself serves is not public, so its own requests to itself appear to be outside LNA. LNA is defence in depth, not a substitute for the checks above. The Chrome 138 blog also says that WebSockets were not gated by LNA at that time. https://developer.chrome.com/blog/local-network-access ; https://www.dynamsoft.com/web-twain/docs/faq/chromium-142-local-network-access-issue.md

### 4.3 Secure context and mic permission

| Browser | `http://localhost` | `http://127.0.0.1` | Source |
|---|---|---|---|
| Spec / MDN | Secure (`localhost`, `*.localhost`) | Secure (127.0.0.0/8, ::1) | https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts |
| Chrome | Secure, so mic access is allowed | Secure | Same + https://www.daily.co/blog/setting-up-a-local-webrtc-development-environment |
| Firefox | Secure since Firefox 84 (`localhost` and `*.localhost` are hard-wired to loopback) | Secure | https://bugzilla.mozilla.org/show_bug.cgi?id=1220810 |
| Safari | Treated as secure. WebKit requires the exact host "localhost" or "127.0.0.1" (2020 bug comment). The current Safari 26 behaviour is UNVERIFIED. Test it. | Same | https://bugs.webkit.org/show_bug.cgi?id=220184 ; https://www.daily.co/blog/setting-up-a-local-webrtc-development-environment |

**Permission persistence.** Permissions are stored per *origin* (scheme + host + port).
- A random port per launch makes a new origin each time. Thus the user sees the mic prompt on every launch. It also leaves stale entries in `chrome://settings/content/microphone`. The Chrome per-origin claim comes from secondary sources; it follows from the origin model.
- Firefox may not offer "Remember this decision" on some sites. The user can set the permission in the site Permissions panel.
- **Design consequence:** use a *stable* preferred port (fall back to random only if it is busy). Then the mic grant persists, and the token, not the port, gives security.

Source: https://help.skynettechnologies.com/microphone-permission.html ; https://support.mozilla.org/fr/questions/1580661

### 4.4 Remote and headless

- **SSH.** Start with no browser, then the user runs `ssh -N -L localhost:PORT:localhost:PORT user@host` and opens `localhost:PORT` on the local machine. This is the Jupyter pattern. Because the browser still sees `localhost`, the page is a secure context and the mic works. https://www.digitalocean.com/community/tutorials/how-to-install-run-connect-to-jupyter-notebook-on-remote-server ; https://kb.wisc.edu/page.php?id=154458
- **VS Code port forwarding** is "Private" by default and needs the same GitHub account. "Public" ports are open to anyone with the link. https://code.visualstudio.com/docs/debugtest/port-forwarding
- **Do not** use a LAN IP (`http://192.168.x.x`). It is not a secure context, so `getUserMedia` is blocked. Follows from the MDN rules above.
- **Headless.** Always print the URL. Try to open a browser only when a display exists (`$DISPLAY`/`$WAYLAND_DISPLAY`, macOS `open`). An agent session (Claude Code, Codex) must send the link to the user in chat. These are design recommendations; no external source.

## 5. Distribution of the talk host

| Option | Notes | Source |
|---|---|---|
| `mix release` with bundled ERTS (default `include_erts: true`) | Not cross-platform. The target must have the same OS, arch, and ABI (gnu/musl). OpenSSL is dynamically linked, so the target needs it if the app uses `:crypto`/`:ssl`. You therefore need one build per OS/arch/libc, made on a CI matrix. | https://mix.hexdocs.pm/Mix.Tasks.Release.html |
| Burrito | A Zig wrapper with an xz payload (BEAM + ERTS). The first run extracts to AppData / Application Support, and later runs of the same version reuse it. Non-prod builds extract every run. Targets: macOS x86_64/arm64, Linux x86_64 (+arm64 ERTS), Windows x86_64. Needs Zig 0.15.2 and xz on the build host; prebuilt ERTS from OTP 25.3. Cross-compiles elixir_make NIFs. Unsigned macOS binaries need a Gatekeeper exemption. Self-described "still experimental". Size and startup time: UNVERIFIED (none published). | https://github.com/burrito-elixir/burrito |
| Bakeware | Archived 2024-09-18: "no longer maintained. Please see Burrito." Historical: binaries are at least ~12 MB; 12–15 MB Linux, 5–7 MB macOS; ~0.5 s start (non-scientific). | https://github.com/bake-bake-bake/bakeware ; https://proxy-ga.blitzz.co/proxy/123456/web.archive.org/web/20200919062622/https:/github.com/spawnfest/bakeware |
| npm/npx + per-platform optional deps | This is the esbuild pattern. A main package lists `@scope/<os>-<arch>` packages in `optionalDependencies`. Each one declares `os`/`cpu` (and `libc` for linux), so npm installs only the matching one. Risk: `--omit=optional`/`--no-optional` skips it silently, so add a fallback or a clear error. | https://docs.npmjs.com/cli/v11/configuring-npm/package-json ; https://chromium.googlesource.com/devtools/devtools-frontend/+/0a3621c/node_modules/esbuild/install.js ; https://github-redirect.dependabot.com/npm/rfcs/discussions/120 |
| Node server alternative | Node SEA (`node --build-sea`) embeds one script in the node binary. It is "Active development" (1.1), not stable. Signing is separate on macOS/Windows. `bun build --compile` bundles the Bun runtime, size not measured (UNVERIFIED). A plain `npx` Node package needs no binary at all for users who already have Node. | https://beta.docs.nodejs.org/single-executable-applications ; https://www.mintlify.com/zhcndoc/bun/bundler/executables |
| Python alternative | Fits if local STT is Python-based (Moonshine, faster-whisper, WhisperLive are all pip). No source gathered on packaging (UNVERIFIED). | — |

**Note.** This repo already ships `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, so an npm wrapper path exists in-house (local observation, not a web source).

## 6. Built-in voice in the agent CLIs

| Agent | What exists | Conversation (TTS reply)? | Reuse for /talk? | Source |
|---|---|---|---|---|
| Claude Code | `/voice` dictation: hold or tap Space. Audio streams to Anthropic for STT. Needs claude.ai login (not API key, not Bedrock/Vertex/Foundry). 20 languages. No token cost. Also works in agent view. `autoSubmit` option. | No. Dictation into the prompt only. | Not directly. It types into the live prompt, which is the opposite of "agent keeps working". The STT endpoint is not a public API. | https://code.claude.com/docs/en/voice-dictation (2026-10-10) VERIFIED-DOC |
| Codex CLI | TUI `/voice`: "start or stop voice; use /voice settings to choose a voice". Feature `realtime_conversation` = stable, on. App-server `thread/realtime/start|appendAudio|appendText|appendSpeech|stop|listVoices` (experimental), WebRTC transport, realtime V3 "delegation" that hands work to the Codex thread and returns Codex responses into the voice session. | Yes. Thread-scoped realtime voice that delegates to the thread. | Yes, strongly. For Codex, /talk can be a thin client over `thread/realtime/*` on a fork or on the live thread. Auth: third-party SDK says realtime needs an API key (SECONDARY, UNVERIFIED). | slash cmd: `codex-rs/tui/src/slash_command.rs` VERIFIED-SRC; feature: VERIFIED-HELP 0.160.0 (`codex features list`); methods: `codex-rs/app-server-protocol/src/protocol/v2/realtime.rs` VERIFIED-SRC; auth: https://codex-sdk.hexdocs.pm/06-realtime-and-voice.html SECONDARY |
| ChatGPT desktop app | "ChatGPT Voice" (GPT-Live) can talk inside an existing Codex task, check progress and steer it. Plus/Pro/Business/Edu/Enterprise. | Yes. This is the /talk concept as a product. | Prior art; desktop app only. | https://learn.chatgpt.com/docs/features/voice.md (2026-10-10) VERIFIED-DOC |
| Gemini CLI | v0.42.0 (2026-05-12): "implement real-time voice mode with cloud and local backends", microphone UI, transcription inserted at cursor, Gemini Live privacy warning. | Looks like dictation (transcript inserted at cursor). Conversational reply UNVERIFIED. | Not directly. | `gh release view v0.42.0 -R google-gemini/gemini-cli` (2026-10-10) VERIFIED-SRC (release notes) |
| Aider | `/voice` + `--voice-format`, `--voice-language`, `--voice-input-device`. | No (dictation). | No. | https://aider.chat/docs/config/options.html (2026-10-10) VERIFIED-DOC |

## 7. Synthesis notes from the STT and launch research

1. **Default STT = browser Web Speech with `processLocally=true`** where `available()` says so (Chrome 139+). Otherwise warn that audio goes to Google/Microsoft/Apple, or offer text mode. Firefox has no STT, so text mode plus OS dictation is the universal fallback.
2. **Text-only mode with a focused textarea** covers macOS Dictation, Win+H, Superwhisper, and Wispr Flow for free.
3. **Optional local engine:** Moonshine is the lowest-effort true streaming engine (pip, CPU, MIT). Use whisper.cpp only for batch.
4. **Security:** bind 127.0.0.1, Host allowlist, Origin check on HTTP + WS, one-time code → HttpOnly SameSite=Strict cookie, Referrer-Policy no-referrer, and no CORS.
5. **Stable preferred port** so the mic permission persists (permission is per origin, including the port).
6. **Play TTS through `<audio>`**, not Web Audio (Chromium AEC gap). Capture with `echoCancellation: true`.
7. **Elixir shipping:** Burrito is the only maintained single-file option and is experimental. A per-platform `mix release` tarball through npm optional deps is the proven pattern. A small Node server avoids ERTS entirely.
