# Configuration reference: voice

Sections of the [configuration reference](/reference/configuration) covering `voice`.

## voice

Optional settings for the conversational voice assistant; an absent `voice:` block changes nothing.

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-voice-00 -->
| --- | --- | --- | --- |
| `voice.conversation.agent_id` | string or nil | nil | ElevenLabs Agents agent the assistant talks through. An account-visible id, not a secret. |
| `voice.conversation.cloud_disclosure_accepted` | boolean or nil | nil (required) | Set `true` to accept that conversation audio and text go to the cloud voice provider. A session refuses to start until it is `true`. |
| `voice.conversation.context_token_budget` | integer | 4000 | Token budget for the context handed to the assistant, 1000 to 32000. |
| `voice.conversation.daily_minutes_cap` | integer or nil | 60 | Voice minutes allowed per day. Minutes from crashed sessions always count. `0` disables sessions; an explicit `null` removes the cap. |
| `voice.conversation.idle_timeout_seconds` | integer | 120 | Silence after which a session ends, 15 to 900 seconds. |
| `voice.conversation.llm` | string or nil | nil (required) | Model the assistant reasons with. No default: a voice session refuses to start until it is set. |
| `voice.conversation.max_session_seconds` | integer | 1800 | Longest one voice session may run, 60 to 3600 seconds. |
| `voice.conversation.provider` | string | elevenlabs_agents | Conversation provider: `elevenlabs_agents` or `openai_realtime`. OpenAI requires `llm` and the daemon's `OPENAI_API_KEY`; no Agent id. |
| `voice.conversation.providers.cascade.llm` | string or nil | nil | Cascade/text-only model as `anthropic:model`, `openai:model` or `gemini:model`. |
| `voice.conversation.providers.cascade.stt` | list of strings | [browser_stt] | Ordered speech recognition parts, validated by the core. |
| `voice.conversation.providers.cascade.tts` | list of strings | [browser_tts] | Ordered speech synthesis parts, validated by the core. |
| `voice.conversation.providers.gemini.live_model` | string or nil | nil | Gemini Live model; nil uses the adapter default. |
| `voice.conversation.providers.mode` | string | voice | Requested conversation mode: `voice` or `text`. |
| `voice.conversation.providers.on_missing_credential` | string | text_only | Missing-key policy: `next`, `text_only` or `refuse`. Text fallback requires `text_only` in the preference list. |
| `voice.conversation.providers.openai.live_model` | string or nil | nil | OpenAI Live model; nil uses the adapter default. |
| `voice.conversation.providers.openai.realtime_model` | string or nil | nil | OpenAI Realtime model; nil uses the adapter default. |
| `voice.conversation.providers.preference` | list of strings | [elevenlabs_agents, openai_live, gemini_live, cascade] | Ordered core registry option ids. Unknown ids fail config loading; unavailable adapters are skipped. |
| `voice.conversation.roles_dir` | string or nil | nil | Directory of role pre-context files. A relative path resolves against the config file's directory, like `prompt_file`. |
| `voice.conversation.voice_id` | string or nil | nil | OpenAI Realtime voice; nil uses `marin`. ElevenLabs keeps its Agent voice. |

`voice.conversation.llm` and `voice.conversation.cloud_disclosure_accepted` have no default. Aiur loads a config without them, but a voice session refuses to start until both are set, and the error names the missing field.

The `daily_minutes_cap` default is a proposed default you may change. Minutes from crashed sessions always count toward the cap.

Standalone VoiceConverse hosts can set `ask_requires_confirm` in `VoiceConverse.Config` to
`:first_in_session` (the default), `:always`, or `:never`. This package setting is separate
from Aiur's `voice.conversation` configuration.

## Provider preferences

`voice.conversation.providers` maps into the shared VoiceConverse provider resolver.
The default order comes from the core: ElevenLabs Agents, OpenAI Live, Gemini Live,
then cascade. Unknown option ids fail loading with the config field path. An adapter
that is not installed remains unsupported and is skipped, even if its key is present.

```yaml
voice:
  conversation:
    providers:
      preference: [elevenlabs_agents, openai_live, gemini_live, cascade]
      mode: voice
      on_missing_credential: text_only
      openai: {live_model: null, realtime_model: null}
      gemini: {live_model: null}
      cascade:
        stt: [browser_stt]
        llm: anthropic:<model id>
        tts: [browser_tts]
```

Model overrides default to `null`, meaning the adapter's default; choose a model
available to your account. `openai.live_model` belongs to the `openai_live`
adapter; `openai.realtime_model` belongs to `openai_realtime`. These are separate
registry options.

`openai_realtime` is intentionally absent from the core default
preference: add it explicitly to opt in. The prototype below uses its explicit
`conversation.llm` model, rather than these resolver overrides.

`cascade.llm` applies to cascade and text-only options.
The existing `conversation.llm` configures the hosted Agent model and the prototype's
explicit Realtime selection below; these are separate settings.

The default `text_only` stops at a missing key. It can use text fallback only if
`text_only` is explicitly in `preference`; otherwise it refuses. Text fallback still
requires the configured cascade LLM key and can incur model charges. No option
outside the configured list is selected.

The operator must approve each paid provider before use. Opting into `next` can
reach **any listed provider whose key exists**, including paid providers; it never
adds unlisted providers. `refuse` stops at the first missing key.

An explicit
provider/model choice in the comparison drawer always uses `refuse`, regardless
of the configured policy; it never records another provider under the chosen arm.
Text mode excludes options that support only voice.

Cascade STT ids are `browser_stt`, `elevenlabs_stt`, `openai_stt`, `text_in`;
TTS ids are `browser_tts`, `elevenlabs_tts`, `openai_tts`, `none`. The core validates
these parts and the `vendor:model` LLM syntax, with failures reported at the full
Aiur config path. Browser parts require client support.

Keys come from the daemon environment at use time: `OPENAI_API_KEY`, `GEMINI_API_KEY`
and `ANTHROPIC_API_KEY`; ElevenLabs retains `elevenlabs.api_key` / `ELEVENLABS_API_KEY`.
Do not put keys under `providers`.

Probes return presence only, and configuration
structs retain no credential values. Capability details report the preferred option
and skipped reasons, such as `OpenAI Realtime skipped: OPENAI_API_KEY missing`.

The public capability entry includes `preferred_provider`, `preference_state` and
`provider_reason`. These describe the core resolver's preference result separately
from the prototype's `state`, which describes its explicit provider selection.


They do not claim that the prototype has used the preferred provider.
The prototype drawer below still permits explicit provider/model selection.

See provider data paths and retention boundaries for [OpenAI](/apis/openai),
[Gemini](/apis/gemini), [Anthropic](/apis/anthropic) and [ElevenLabs](/apis/elevenlabs).

## Executor voice prototype setup

The Executor conversation prototype supports **ElevenLabs Agents** (default)
and **OpenAI Realtime**. From Home, open **Settings → Talk to Executor** (`/voice`) to compare providers and record ratings; see [Executor voice](/guide/executor-voice). These settings configure the same retained backend APIs. For ElevenLabs,
create the Agent and set:

```yaml
elevenlabs:
  api_key: $ELEVENLABS_API_KEY
voice:
  conversation:
    agent_id: agent_your_agent_id
    llm: your_chosen_model
    cloud_disclosure_accepted: true
```

The credential uses `elevenlabs.api_key`, including its `ELEVENLABS_API_KEY`
environment fallback. Keep the key in the daemon's environment or dotenv file.
The browser receives neither the key nor the signed provider URL.

Audio uses mono 16-bit PCM at 16 kHz in both directions; configure the Agent's
output as `pcm_16000`. Choose the model on the Agent itself and set `llm` to
that model's name; the prototype does not override the Agent's model.

Enable the Agent's
[system prompt override](https://elevenlabs.io/docs/eleven-agents/customization/personalization/overrides)
so Aiur can supply its read-only instructions and briefing.

Enable `audio`, `user_transcript`, `agent_response`, `interruption` and
`client_tool_call` events. Set **expects response** on each client tool, so the
Agent waits for results. Restart Aiur after setting this configuration.

Configure these client tools with the exact names and JSON parameter shapes:

| Client tool name | Parameter shape |
| --- | --- |
| `get_status` | `{}`; object with no properties and `additionalProperties: false` |
| `get_details` | `{"section":"agents","n":10}`; required `section` is one of `transcript`, `agents`, `decisions`; optional integer `n` is 1–30, default 10; `additionalProperties: false` |
| `record_summary` | `{"decisions":[],"open_questions":[],"ideas":[]}`; all three fields required; each array has up to 20 nonblank strings of up to 500 characters; no additional properties |
| `end_conversation` | `{}`; object with no properties and `additionalProperties: false` |

For OpenAI, keep `OPENAI_API_KEY` only in the PC daemon's environment or dotenv
file, then configure:

```yaml
voice:
  conversation:
    provider: openai_realtime
    llm: gpt-realtime-2.1
    voice_id: marin
    cloud_disclosure_accepted: true
    max_session_seconds: 180
    daily_minutes_cap: 5
```

No ElevenLabs Agent id or client-tool setup is needed for OpenAI. `llm` is sent
as the Realtime model; `voice_id` is optional. The provider setting selects the backend default. Restart after changing credentials or other daemon settings.

The adapter converts 16 kHz mic PCM to 24 kHz and emits tagged 24 kHz output;
the browser and transcript/summary handoff are shared. Input transcription uses
`gpt-4o-mini-transcribe`.

Server VAD handles turns and cancellation; barge-in
clears playback and conservatively removes the whole interrupted audio item
from model context because the browser does not report how much was heard.


The prototype's time caps are not dollar limits. Live evaluation has a combined
USD 25 budget across both providers; check account usage before and after each
short attended run, then disable the demo. No background live evaluation runs.

The prototype reads current agents, open decisions, and available retained
Executor transcript turns for a live Claude Executor. The bounded transcript read
uses the registered Executor session; Codex transcript context is unavailable in
this prototype. A missing or unsupported source is reported as unavailable.

The dedicated Executor briefing integration is tracked in #4125.
Briefing sections use short excerpts; transcript snippets put the newest turns
first so long older answers cannot crowd out current run facts.

Do not configure `propose_instruction` or `ask_agent`: this prototype has no
instruction delivery or Confirm action. Spoken requests are handed to the
Executor after the conversation ends.

At session end the transcript and summary handoff publishes on
**`executor.voice.session_ended`**. Add that exact topic to the Executor's wake
filter. The event is context for the Executor to act on through its ordinary
workflow; ending the voice session does not itself dispatch instructions.

Before ending, the Agent calls `record_summary`: explicit choices go in
`decisions`, unanswered questions in `open_questions`, and brainstorming or
revised ideas in `ideas`. Empty arrays mean none. The payload keeps these
categories separate beside the full transcript; all summary text is untrusted.

If no valid summary was recorded, the payload contains
`summary: {status: "unstructured"}`.
Ending a session never promotes the transcript into decisions or instructions.

Each handoff retains its **sent** event id and timestamp after the session ends. Acknowledgment is recorded only after the Executor acknowledges the
matching durable wake id. While waiting, the handoff is sent, not received;
missing or unavailable acknowledgment evidence is shown explicitly.

Received means the wake was acknowledged, not that its contents were approved
or executed. The acknowledgment timestamp is when Aiur observed the
acknowledgment. Starting another voice session does not erase earlier receipts.
