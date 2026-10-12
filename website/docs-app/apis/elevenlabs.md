# ElevenLabs

Aiur uses ElevenLabs for Stream Deck and Dashboard voice input, and for spoken Dashboard replies.

## What voice does

| Capability | Where | What happens |
| --- | --- | --- |
| Speech to text | Stream Deck Mic key and Dashboard agent composer | Dictation is transcribed and delivered through the same agent-message path as typed Dashboard text. |
| Text to speech | Dashboard interactive conversation | The agent's reply is streamed back to the browser as speech. |

Aiur holds the credential and makes every ElevenLabs call; neither the Stream Deck sidecar nor the browser ever receives it.

## Who does what

| Stage | Responsibility |
| --- | --- |
| Capture | The browser captures through an AudioWorklet; the Stream Deck sidecar uses `parec`. Both stream 16 kHz mono PCM16 audio only while the mic is held or recording is active. |
| Transport | Audio reaches Aiur over authenticated sockets: `/voice` requires a writable Dashboard session and CSRF proof; `/streamdeck` requires the sidecar token. |
| Transcription | Aiur's daemon opens the ElevenLabs realtime session with its own key. Microphone audio and the returned text pass through ElevenLabs. |
| Delivery | Dictated text returns to the Dashboard composer or Stream Deck buffer for review. It reaches the selected agent only when you press Send. |
| Retention | Aiur writes no microphone audio to disk or logs. Sent text becomes an ordinary chat message. |

Interactive voice chat on the Dashboard sends each finished utterance to the agent without a Send press.

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
| Zero character limit | Empty track, because there is no denominator for a percentage. |

The Units meter shows only the credit quota bar; the next-invoice amount is not rendered on the strip.

The meter can remain unchanged after heavy dictation because it reads the text-to-speech character pool, not audio-minute usage.

## Privacy and secret handling

Voice transcription is cloud processing: while you dictate, your audio and the returned text pass through ElevenLabs; a private network (Tailscale) or loopback-only Dashboard does not change that.

| State | Data path |
| --- | --- |
| Dictation held open | Microphone audio goes to ElevenLabs; returned text stays in the composer or deck buffer until you press Send. |
| Dictation released | Capture stops; there is no always-on listener or wake word. |
| Key absent | No ElevenLabs connection opens and no audio leaves the machine. |
| Agent process | `ELEVENLABS_API_KEY` is scrubbed from coding-agent environments and never logged. |

See [Stream Deck voice input](/guide/stream-deck#voice-input) for operator controls and [Configuration](/reference/configuration#elevenlabs) for field defaults.
