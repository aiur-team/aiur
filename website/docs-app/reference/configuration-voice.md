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
