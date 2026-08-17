# ElevenLabs

Aiur uses ElevenLabs for Stream Deck and Dashboard voice input, and for spoken Dashboard replies.

## What voice does

| Capability | Where | What happens |
| --- | --- | --- |
| Speech to text | Stream Deck Mic key and Dashboard agent composer | Dictation is transcribed and delivered through the same agent-message path as typed Dashboard text. |
| Text to speech | Dashboard interactive conversation | The agent's reply is streamed back to the browser as speech. |

Aiur holds the credential and makes every ElevenLabs call; neither the Stream Deck sidecar nor the browser ever receives it.

## API key permissions

| Permission | Needed for | Why |
| --- | --- | --- |
| `Speech to Text` | Dictation | Transcribes operator speech. |
| `User` | Units meter | Reads account subscription data. |
| `Text to Speech` | Dashboard spoken replies | Renders the agent reply as audio; also needs `elevenlabs.voice_id`. |

Use a restricted key with those permissions. A key that can transcribe but cannot read `User` data makes voice input work while the meter reports an authorization failure.

## Configure the key

| Location | Value |
| --- | --- |
| Private environment | `ELEVENLABS_API_KEY=<restricted key>` |
| `.aiur/config` | `elevenlabs.api_key: $ELEVENLABS_API_KEY` |
| Language | `elevenlabs.language_code: eng` by default. |
| Voice | `elevenlabs.voice_id: null` by default; set a stock or owned voice to enable Dashboard spoken replies. |

The key is optional. Without it, microphone discovery and level meters remain available, but no audio leaves the machine and transcription stays disabled.

## What the Units meter measures

| Figure | Meaning |
| --- | --- |
| Credit quota | Account `character_count` against `character_limit` from `GET /v1/user/subscription`, shown as percentage used. |
| Character pool | Text-to-speech characters reported by the ElevenLabs subscription. |
| Speech-to-text cost | Not represented; ElevenLabs bills transcription per audio-minute. |
| Next invoice due | `next_invoice.amount_due_cents`; money owed, not a remaining balance. |
| Zero character limit | Empty track, because there is no denominator for a percentage. |

The meter can remain unchanged after heavy dictation because it reads the text-to-speech character pool, not audio-minute usage.

## Privacy and secret handling

| State | Data path |
| --- | --- |
| Dictation held open | Microphone audio goes to ElevenLabs and the returned text goes to the selected agent. |
| Dictation released | Capture stops; there is no always-on listener or wake word. |
| Key absent | No ElevenLabs connection opens and no audio leaves the machine. |
| Agent process | `ELEVENLABS_API_KEY` is scrubbed from coding-agent environments and never logged. |

See [Stream Deck voice input](/guide/stream-deck#voice-input) for operator controls and [Configuration](/reference/configuration#elevenlabs) for field defaults.
