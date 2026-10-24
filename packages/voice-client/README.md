# @aiur/voice-client

Portable ESM client primitives for the versioned Aiur voice wire protocol. The
core runs in browsers and Node without importing DOM or Node-only modules.

The package does not mint or persist credentials. Pass the endpoint and
short-lived token issued by the voice host when opening a connection.

## Install

```sh
npm install @aiur/voice-client
```

## Connect

Provide a codec backed by the matching wire-contract schemas. The codec must
throw when an outbound or inbound frame fails validation; the client converts
that failure into a redacted `VoiceClientError` and closes the connection.

```ts
import {
  connectVoiceWire,
  createQueryTokenSocketFactory,
  type WireCodec,
} from "@aiur/voice-client";

type OutboundFrame = { kind: "start" } | { kind: "audio"; pcm16: number[] };
type InboundFrame = { kind: "transcript"; text: string };

declare const codec: WireCodec<OutboundFrame, InboundFrame>;
declare const endpoint: string;
declare const token: string;

const connection = connectVoiceWire({
  endpoint,
  token,
  codec,
  socketFactory: createQueryTokenSocketFactory(),
  events: {
    frame: (frame) => {
      if (frame.kind === "transcript") console.log(frame.text);
    },
    error: (error) => console.error(error.code, error.message),
  },
});

connection.send({ kind: "start" });
```

Frames sent while the socket is connecting are validated immediately and
queued until it opens. Incoming data is delivered only after the codec accepts
it. Tokens and transport exception details are not exposed on the returned
connection or copied into client errors.

`createQueryTokenSocketFactory` uses platform `URL` and `WebSocket` globals by
default. A Node application without a compatible global can inject structural
implementations through its dependency options.

## Browser audio

Browser-only audio helpers live in a separate export so importing the core has
no DOM or Web Audio dependency.

```ts
import {
  createBrowserAudioCapture,
  createBrowserAudioPlayback,
} from "@aiur/voice-client/browser";

declare const agentPcm16: Int16Array;

const capture = createBrowserAudioCapture({ targetSampleRateHz: 16_000 });
await capture.start((chunk) => {
  // Encode chunk.samples and chunk.sampleRateHz in a contract audio frame.
});

const playback = createBrowserAudioPlayback();
playback.enqueue({ samples: agentPcm16, sampleRateHz: 16_000 });

const { playedUntilMs } = playback.interrupt();
await capture.stop();
await playback.close();
```

Capture and playback use signed 16-bit mono PCM chunks. Both accept injected
platform dependencies for tests or alternate browser integrations. Applications
may replace them entirely through the exported `AudioCaptureAdapter` and
`AudioPlaybackAdapter` interfaces.

## Errors and lifecycle

Connection states are `connecting`, `open`, `closing`, `failed`, and `closed`.
Operational failures are reported as `VoiceClientError` values with stable
codes. Error messages are intentionally generic so host tokens, endpoints, and
browser device details do not leak into logs.
