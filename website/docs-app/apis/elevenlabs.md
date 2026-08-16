# ElevenLabs

Aiur uses ElevenLabs for Stream Deck voice input today; spoken replies are a later capability.

## What voice does

| Capability | Status | What happens |
| --- | --- | --- |
| Speech to text | Available | Dictation is transcribed and delivered through the same agent-message path as typed Dashboard text. |
| Text to speech | Later | Agent replies will be spoken when voice replies land. |

## API key permissions

| Permission | Needed now | Why |
| --- | --- | --- |
| `Speech to Text` | Yes | Transcribes operator dictation. |
| `User` | Yes | Reads account subscription data for the Units meter. |
| `Text to Speech` | Not yet | Required only when spoken replies land. |

Use a restricted key with those permissions. A key that can transcribe but cannot read `User` data makes voice input work while the meter reports an authorization failure.

## Configure the key

| Location | Value |
| --- | --- |
| Private environment | `ELEVENLABS_API_KEY=<restricted key>` |
| `.aiur/config` | `elevenlabs.api_key: $ELEVENLABS_API_KEY` |
| Language | `elevenlabs.language_code: eng` by default. |

The key is optional. Without it, microphone discovery and level meters remain available, but no audio leaves the machine and transcription stays disabled.

## What the Units meter measures

| Figure | Meaning |
| --- | --- |
| Character pool | Text-to-speech characters reported by the ElevenLabs subscription. |
| Speech-to-text cost | Not represented; ElevenLabs bills transcription per audio-minute. |
| Dollar balance | Not available from ElevenLabs. |

The meter can remain unchanged after heavy dictation because it reads the text-to-speech character pool, not audio-minute usage.

## Privacy and secret handling

| State | Data path |
| --- | --- |
| Dictation held open | Microphone audio goes to ElevenLabs and the returned text goes to the selected agent. |
| Dictation released | Capture stops; there is no always-on listener or wake word. |
| Key absent | No ElevenLabs connection opens and no audio leaves the machine. |
| Agent process | `ELEVENLABS_API_KEY` is scrubbed from coding-agent environments and never logged. |

See [Stream Deck voice input](/guide/stream-deck#voice-input) for operator controls and [Configuration](/reference/configuration#elevenlabs) for field defaults.
