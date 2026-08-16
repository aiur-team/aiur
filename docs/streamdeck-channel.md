# Stream Deck channel

Aiur exposes a Phoenix WebSocket at `/streamdeck/websocket` for push-driven
fleet state. Join the single `streamdeck:fleet` channel; internal PubSub topic
names and tuple shapes are not part of this API.

## Authentication

The device first requests `POST /api/v1/streamdeck/token` with the existing
dashboard HTTP Basic credentials. The response is `{token, expires_in_seconds}`.
Pass that token as the Phoenix socket parameter (`/streamdeck/websocket?token=…`),
then join `streamdeck:fleet`.

This adds no device credential: the token can only be minted after dashboard
Basic authentication, expires after five minutes, is signed by the endpoint,
and stops verifying when the dashboard username, password, or signing key
changes. A joined channel closes when that five-minute token window expires or
the dashboard credential configuration changes.
The WebSocket handshake therefore avoids placing a reusable dashboard password
in the upgrade URL while retaining the same authorization boundary. Use
HTTPS/WSS when the dashboard is exposed beyond loopback.

## Events

Every payload is JSON and uses `version: 1` in the initial `snapshot` event.

| Event | Payload | Meaning |
| --- | --- | --- |
| `snapshot` | `{version, fleet, usage, decisions, voice}` | Complete state sent immediately after a successful join. |
| `fleet` | `{agents}` | Complete fleet replacement after a fleet change. |
| `usage` | `{codex, claude}` | Redacted provider-meter projection for the touch-strip usage segments. |
| `decisions` | `{count}` | Updated decision summary. |
| `transcript` | `{identifier, role, body, sequence, timestamp}` | Latest sampled line for the focused agent. |
| `logs` | `{transcript, event_keys, event_starts, …}` | The focused agent's log surface: the event-key strip and the transcript rows it jumps into. Pushed on focus and again whenever a new transcript line lands. |
| `alert` | `{identifier, name, message, severity, needs_attention, timestamp}` | Focused agent alert. |
| `control` | `{identifier, state}` | Focused agent's redacted control state. `state` may contain `action`, `status`, and lifecycle timestamps (`requested_at`, `accepted_at`, `applied_at`, `rejected_at`, `expiry`); request, tracker, and requester details are never exposed. |

An agent item may contain `identifier`, `status`, `alert_count`, `title`,
`runtime_seconds`, `turn_count`, `work_state`, `pause_reason`,
`tracker_paused`, `backend`, and `model`. Fields absent from the source are
omitted rather than represented by implementation-specific sentinels.

## Focus and transcript rate

Send `focus` with `{identifier}` to watch one agent, or `unfocus` to stop. A
channel subscribes to only that one `agent:<identifier>` source; it never fans
out subscriptions for every agent. Re-focusing unsubscribes the prior agent.

Physical key toggles send `control` with `{identifier, action}`. The accepted
actions are exactly `pause` and `resume`, and nothing else is accepted: the
agent view's four keys are pause, logs, mic and settings, so there is no
surface that can send a priority action and the channel does not pretend to
offer one. Orchestrator priority itself is unchanged and remains reachable from
the dashboard's own controls. The channel routes the request through
`Aiur.AgentChat` and returns the orchestrator result; the device does not
implement a second pause/resume path.

Transcript traffic is latest-value coalesced in 250 ms windows (four pushes per
second maximum per joined channel). A dedicated relay is the sole subscription
to the focused agent, so the channel mailbox is not filled by a transcript
burst. A burst produces one `transcript` event containing the final line from
that window; intermediate lines are intentionally discarded because the device
renders only a small live-log region.

## Voice input

Voice input streams captured microphone audio to Aiur, and **Aiur** performs the
ElevenLabs call. `ELEVENLABS_API_KEY` never exists in the sidecar process, its
environment, or its configuration; there is no second place to configure it.

### Device → Aiur

| Event | Payload | Reply |
| --- | --- | --- |
| `voice_start` | `{}` | `{"session": id}` or `{"reason": r}` |
| `voice_audio` | `{"session": id, "audio": base64}` | none |
| `voice_stop` | `{"session": id}` | `{}` |

### Aiur → device

| Event | Payload |
| --- | --- |
| `voice` | `{"session", "kind", "text"}` — `kind` is `partial` or `final` |
| `voice_error` | `{"session", "reason"}` |
| `voice_closed` | `{"session"}` |

`voice_start` requires the same authenticated socket as `say`; an unauthenticated
one is refused with `unauthorized`. When no API key is configured the reply is
`unconfigured`, which is a normal state rather than a failure — the device says
why the microphone is off while capture, waveform and the decibel bar keep
working.

`session` is an opaque server-minted id. A second `voice_start` replaces the
live session, stopping it cleanly first. A `voice_audio` or `voice_stop`
carrying a stale or unknown session is ignored, so a late frame from a previous
hold cannot reach the provider, and text the abandoned session had already
produced cannot be relabelled with the new session's id. A frame larger than
64 KiB, or a malformed payload, is dropped rather than crashing the channel.

The session runs in its own monitored process: the channel stops it on
`unfocus`, on refocus, and on `terminate`, and a provider fault ends the session
without ending the channel.

### The `voice` snapshot entry

```json
"voice": { "available": true, "reason": null }
```

`available` is `false` with the reason
`"Aiur has no ElevenLabs API key - transcription is off"` when no key is
configured, so the device can explain a disabled microphone key without a round
trip. The entry reports the *presence* of a credential only; neither the key nor
any part of it ever appears in a projection.

### Why base64 in JSON on this channel, and not a binary frame

The sidecar's channel client is a hand-rolled Phoenix v2 JSON serializer, where
a frame is the array `[join_ref, ref, topic, event, payload]`. Phoenix's binary
path carries a raw payload with **no event name**, so a binary frame cannot be
routed alongside `focus`, `control` and `say` without a second socket with its
own authentication and its own reconnect. That cost buys nothing here, because
ElevenLabs' own realtime protocol is already base64-in-JSON: the provider frame
is `{message_type: "input_audio_chunk", audio_base_64, commit, sample_rate}`.
Relaying the base64 string verbatim means Aiur does **zero transcode** — the
string the sidecar produced is the string the provider receives. The 4/3
expansion is therefore paid once, on a leg that would pay it anyway; a binary
channel frame would only force Aiur to base64-encode instead, moving the cost
rather than removing it.

The measured budget: capture is 32,000 B/s (16 kHz mono s16le), regrouped into
3,200-byte 100 ms frames, so **10 messages/s** of 4,272 base64 characters plus
roughly 60 bytes of Phoenix framing — about **43.3 kB/s**, with framing overhead
at 1.4% of the message.

Only transcribed text round-trips. The waveform and the decibel bar are computed
on the sidecar from the captured PCM and never wait on Aiur, so "is my
microphone working" is bounded by the 20 ms capture latency rather than by any
network round trip.
