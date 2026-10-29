# Gemini

The VoiceConverse registry supports Gemini Live conversation and Gemini cascade LLM options. Availability depends on the installed
adapter, supported mode and credential presence; a configured preference does not
install an adapter. Missing adapters are reported as unsupported.

Set `GEMINI_API_KEY` in the daemon environment or private dotenv file. The host reads it at
connection time. Presence probes return only `present` or `missing`, never the key.
The browser receives no API key. Do not store credentials under
`voice.conversation.providers`.

## Privacy

| Surface | Data sent | Provider retention and deletion |
| --- | --- | --- |
| Conversation option | Live receives microphone audio, conversation text, briefing and tool results; the cascade LLM receives text. | Provider-side retention follows account terms and controls; Aiur cannot promise deletion of data already sent. See the [provider policy](https://ai.google.dev/gemini-api/terms). |

Aiur retains conversation transcripts according to its transcript settings; cloud
disclosure acceptance is required before a session. Local transcript deletion does
not delete provider-held data. A loopback or private-network dashboard still sends
conversation data to the selected cloud provider. No paid request is made by a
credential probe or capability resolution.

For Gemini, paid and unpaid services have different data-use terms; check the policy
for your account before sending sensitive context.

See [voice configuration](/reference/configuration-voice#provider-preferences) for
preference order, model overrides and missing-key behavior. Dictation and standalone
speech continue through the existing `Aiur.Voice` seam; realtime conversation uses
the `voice_converse` provider session port.
