# MP-E6 voice prototype comparison

Facts checked 2026-10-28. PC fills measured cells after attended live runs;
blank cells are intentionally unmeasured. No provider recommendation yet.
Stream Deck voice remains out of scope until Kevin selects a provider.

| Criterion | ElevenLabs Agents (PROTO-01) | OpenAI Realtime (PROTO-02) |
| --- | --- | --- |
| Latency to first audible audio (median / p95, ms; PC measured) | | |
| Turn-taking and interruption (PC measured) | | |
| Voice quality (PC listening notes; selected voice) | | |
| Tool reliability (successful / attempted, PC measured) | | |
| Actual total cost per elapsed minute (USD, PC measured) | | |
| Documented pricing | Additional call minutes USD 0.08/min; burst USD 0.16/min. LLM/telephony extra; account plan may differ. [Pricing](https://elevenlabs.io/pricing/agents?price.platform=agents_platform) | `gpt-realtime-2.1`: per million audio tokens USD 32 input / 0.40 cached / 64 output; text USD 4 input / 0.40 cached / 24 output. Transcription extra. No fixed conversation price/minute. [Model pricing](https://developers.openai.com/api/docs/models/gpt-realtime-2.1) |
| Documented limits | Default conversation 600 s; configurable 60–7200 s. [Conversation flow](https://elevenlabs.io/docs/eleven-agents/customization/conversation-flow) | Realtime session maximum 60 minutes; PCM input 24 kHz mono. [Protocol](https://developers.openai.com/api/docs/guides/realtime-conversations) |
| Turn-taking implementation | Hosted Agent VAD/interruption events; Agent dashboard settings apply. | Server VAD auto-response/cancellation; speech-start clears browser playback. Without playback-offset feedback, adapter truncates the whole interrupted audio item from model context. |
| Tool wiring | Configure four client tools and expects-response in Agent dashboard. | Session registers the same four tool schemas; only complete function arguments execute, call ids are deduplicated. |
| Setup | PC daemon `ELEVENLABS_API_KEY`, Agent id/model, prompt override, PCM16k output, event subscriptions and four client tools. | PC daemon `OPENAI_API_KEY`; `voice.conversation.provider: openai_realtime`, explicit `llm`, cloud consent; optional `voice_id`. No Agent creation. |

See [demo configuration](../../../../../website/docs-app/reference/configuration-voice.md)
for exact YAML, ElevenLabs tool schemas and the shared transcript/summary handoff.
Both providers keep the browser and read-only tool allowlist unchanged.

## Measurement protocol for PC

Use the same PC, microphone/headphones, network, briefing and prompts. Record
provider model, voice, account plan, build SHA, date, and elapsed run duration.
Start with short runs (180 seconds maximum, five daily minutes); these are time
caps, not dollar caps. Read remaining account credit before starting. Count all
PROTO-01 and PROTO-02 charges against the same USD 25 total, including text,
transcription and LLM charges. Stop before exhausting the remainder; do not
activate an ongoing subscription or leave the microphone running unattended.

For each provider, repeat a status question, interrupt a long answer, request
agent details, then state one explicit decision, one unanswered question and one
idea. Ask to end the conversation. Record stop-speaking to first audible answer
latency for each turn, interruption behavior and listening notes. Count each
expected tool invocation and each successful normalized result. Confirm the
ended-session drawer retains transcript and the three summary arrays and that
the Executor receives the same session-ended handoff. Compare billed usage before
and after, dividing total incremental USD by elapsed session minutes. Record
sample size beside median/p95; do not infer voice quality or real latency from
transport-double tests. Disable the demo when finished.
