# OpenAI

The VoiceConverse registry supports OpenAI Live / Realtime conversation options and OpenAI cascade parts. Availability depends on the installed
adapter, supported mode and credential presence; a configured preference does not
install an adapter. Missing adapters are reported as unsupported.

Set `OPENAI_API_KEY` in the daemon environment or private dotenv file. The host reads it at
connection time. Presence probes return only `present` or `missing`, never the key.
The browser receives no API key. Do not store credentials under
`voice.conversation.providers`.

## Privacy

| Surface | Data sent | Provider retention and deletion |
| --- | --- | --- |
| Conversation option | Realtime receives microphone audio, conversation text, briefing and tool results; cascade parts receive the selected audio or text. | Provider-side retention follows account terms and controls; Aiur cannot promise deletion of data already sent. See the [provider policy](https://developers.openai.com/api/docs/guides/your-data). |

Aiur retains conversation transcripts according to its transcript settings; cloud
disclosure acceptance is required before a session. Local transcript deletion does
not delete provider-held data. A loopback or private-network dashboard still sends
conversation data to the selected cloud provider. No paid request is made by a
credential probe or capability resolution.

See [voice configuration](/reference/configuration-voice#provider-preferences) for
preference order, model overrides and missing-key behavior. Dictation and standalone
speech continue through the existing `Aiur.Voice` seam; realtime conversation uses
the `voice_converse` provider session port.
