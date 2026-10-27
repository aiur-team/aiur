# VoiceConverse

Host-agnostic voice assistant core. It depends on no host application: everything it needs from
the host arrives through `VoiceConverse.Config` and the behaviours in `VoiceConverse.Ports`.

CI job `voice-converse-standalone` compiles and tests this package alone and fails on any
reference to the host application (`scripts/check-voice-converse-isolation.sh`).

## Standalone WebSocket

When the host includes the optional `websock_adapter` and `bandit` dependencies, it can supervise
`VoiceConverse.Transport.WebSock` independently of Phoenix:

```elixir
{VoiceConverse.Transport.WebSock,
 instance: MyVoiceInstance,
 token_issuer: MyApp.VoiceTokenIssuer,
 port: 40_400}
```

It binds `127.0.0.1` by default. The host's `VoiceConverse.Ports.TokenIssuer` verifies a
short-lived token with the `"converse"` scope. Non-browser clients use
`Authorization: Bearer <token>`; browser clients use `?token=<token>` because the WebSocket API
cannot set an Authorization header. Invalid credentials close the socket with code `4401` before
a session is started.

`priv/static/voice_converse_client.js` is a build-free ES module for host pages. Construct a
`VoiceConverseClient` with the socket URL, target and a draft-card container, then call
`bindStart(button)`. Microphone permission is requested only by that button click; captured audio
is echo-cancelled and resampled to 16 kHz PCM. The client and the socket exchange versioned v1
frames defined by `VoiceConverse.Wire` and the JSON Schema in
`packages/aiur-contracts/schemas/voice-converse.v1.schema.json`.
