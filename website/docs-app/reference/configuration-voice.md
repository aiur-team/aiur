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
| `voice.conversation.roles_dir` | string or nil | nil | Directory of role pre-context files. A relative path resolves against the config file's directory, like `prompt_file`. |

`voice.conversation.llm` and `voice.conversation.cloud_disclosure_accepted` have no default. Aiur loads a config without them, but a voice session refuses to start until both are set, and the error names the missing field.

The `daily_minutes_cap` default is a proposed default you may change. Minutes from crashed sessions always count toward the cap.

Standalone VoiceConverse hosts can set `ask_requires_confirm` in `VoiceConverse.Config` to
`:first_in_session` (the default), `:always`, or `:never`. This package setting is separate
from Aiur's `voice.conversation` configuration.

## Executor voice prototype setup

The Executor conversation prototype uses the **ElevenLabs Agents** provider.
It is enabled by `voice.conversation.agent_id`; there is no separate provider
selection key. Create the Agent in ElevenLabs, then set:

```yaml
elevenlabs:
  api_key: $ELEVENLABS_API_KEY
voice:
  conversation:
    agent_id: agent_your_agent_id
    llm: your_chosen_model
    cloud_disclosure_accepted: true
```

The credential uses the existing `elevenlabs.api_key` secret source, including
its `ELEVENLABS_API_KEY` environment fallback. Keep the actual key in the daemon's
environment or dotenv file. The browser receives neither the key nor the signed
provider URL. Conversation audio uses mono 16-bit PCM at 16 kHz in both directions;
configure the Agent's output format as `pcm_16000`.
Choose the model on the ElevenLabs Agent itself and set `llm` to that model's
name; the prototype does not override the Agent's model. Enable the Agent's
[system prompt override](https://elevenlabs.io/docs/eleven-agents/customization/personalization/overrides)
so Aiur can supply its read-only instructions and briefing. Enable the
`audio`, `user_transcript`, `agent_response`, `interruption` and `client_tool_call`
events. Set **expects response** on each client tool, so the Agent waits for
the daemon's tool result. Restart Aiur after setting this configuration.

Configure these **client tools** on the ElevenLabs Agent with these exact names
and JSON parameter shapes. Each tool returns its result to the Agent through the
daemon; it is not a webhook or server tool.

| Client tool name | Parameter shape |
| --- | --- |
| `get_status` | `{}`; object with no properties and `additionalProperties: false` |
| `get_details` | `{"section":"agents","n":10}`; required `section` is one of `transcript`, `agents`, `decisions`; optional integer `n` is 1–30, default 10; `additionalProperties: false` |
| `end_conversation` | `{}`; object with no properties and `additionalProperties: false` |

The prototype reads current agents, open decisions, and available retained
Executor transcript turns for a live Claude Executor. The bounded transcript read
uses the registered Executor session; Codex transcript context is unavailable in
this prototype. A missing or unsupported source is reported as unavailable.
The dedicated Executor briefing integration is tracked in #4125.
Do not configure `propose_instruction` or `ask_agent`: this prototype has no
instruction delivery or Confirm action. Spoken requests are handed to the
Executor after the conversation ends.

At session end the transcript and summary handoff publishes on
**`executor.voice.session_ended`**. Add that exact topic to the Executor's wake
filter. The event is context for the Executor to act on through its ordinary
workflow; ending the voice session does not itself dispatch instructions.
