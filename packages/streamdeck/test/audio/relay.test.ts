import { describe, expect, it, vi, type Mock } from "vitest";
import { createRelayTranscriber, type VoiceRelayPort } from "../../src/audio/relay.js";
import type { TranscriberHandlers, TranscriptEvent } from "../../src/audio/stt.js";

/** Records everything the relay asked the host to send to Aiur. */
const portHarness = (): {
  [K in keyof VoiceRelayPort]: Mock<VoiceRelayPort[K]>;
} => ({
  start: vi.fn<() => void>(),
  audio: vi.fn<(base64: string) => void>(),
  stop: vi.fn<() => void>(),
});

const handlerHarness = (): {
  [K in keyof TranscriberHandlers]: Mock<TranscriberHandlers[K]>;
} => ({
  onTranscript: vi.fn<(event: TranscriptEvent) => void>(),
  onError: vi.fn<(reason: string) => void>(),
});

/** Deterministic stand-in for base64, so assertions read as bytes not padding. */
const fakeBase64 = (bytes: Uint8Array): string => `b64:${[...bytes].join("-")}`;

describe("relay transcriber when voice is unavailable", () => {
  const unavailable = (reason: string | null) =>
    createRelayTranscriber({ port: portHarness(), unavailableReason: reason });

  it("carries the reason Aiur gave rather than failing to construct", () => {
    const relay = unavailable("Aiur has no key");
    expect(relay.transcriber.available).toBe(false);
    expect(relay.transcriber.unavailableReason).toBe("Aiur has no key");
  });

  it("reports the reason through onError and sends nothing to Aiur", () => {
    const port = portHarness();
    const relay = createRelayTranscriber({ port, unavailableReason: "Aiur has no key" });
    const handlers = handlerHarness();

    const session = relay.transcriber.open(handlers);
    session.push(new Uint8Array([1, 2]));
    session.close();
    session.close();

    expect(handlers.onError).toHaveBeenCalledWith("Aiur has no key");
    expect(handlers.onTranscript).not.toHaveBeenCalled();
    // No key means no audio leaves the machine, while capture, the waveform and
    // the decibel bar keep working.
    expect(port.start).not.toHaveBeenCalled();
    expect(port.audio).not.toHaveBeenCalled();
    expect(port.stop).not.toHaveBeenCalled();
  });

  it("ignores pushes from Aiur, since no session was ever opened", () => {
    const relay = unavailable("Aiur has no key");
    expect(() => {
      relay.deliver({ kind: "partial", text: "hello" });
      relay.fail("channel dropped");
      relay.finish();
    }).not.toThrow();
  });

  it("treats a null reason as configured", () => {
    expect(unavailable(null).transcriber.available).toBe(true);
  });

  it("treats an empty reason as configured, not as a blank explanation", () => {
    // An unavailable transcriber whose reason prints as nothing is worse than
    // an available one: the deck would show silent failure.
    expect(unavailable("").transcriber.available).toBe(true);
  });

  it("treats an omitted reason as configured", () => {
    expect(createRelayTranscriber({ port: portHarness() }).transcriber.available).toBe(true);
  });
});

describe("relay transcriber streaming", () => {
  const openRelay = () => {
    const port = portHarness();
    const handlers = handlerHarness();
    const relay = createRelayTranscriber({ port, encodeBase64: fakeBase64 });
    const session = relay.transcriber.open(handlers);
    return { port, handlers, relay, session };
  };

  it("is available and carries no reason when Aiur is configured", () => {
    const relay = createRelayTranscriber({ port: portHarness(), encodeBase64: fakeBase64 });
    expect(relay.transcriber.available).toBe(true);
    expect(relay.transcriber.unavailableReason).toBeNull();
  });

  it("asks Aiur to open a provider session exactly once per hold", () => {
    const { port } = openRelay();
    expect(port.start).toHaveBeenCalledTimes(1);
  });

  it("base64-encodes each frame and relays the string verbatim", () => {
    // Relaying the string means Aiur does zero transcode: what is encoded here
    // is what the provider receives.
    const { port, session } = openRelay();
    session.push(new Uint8Array([1, 2, 3]));
    session.push(new Uint8Array([4]));

    expect(port.audio.mock.calls).toEqual([["b64:1-2-3"], ["b64:4"]]);
  });

  it("encodes with Buffer when the host injects no encoder", () => {
    const port = portHarness();
    const relay = createRelayTranscriber({ port });
    relay.transcriber.open(handlerHarness()).push(new Uint8Array([104, 105]));

    expect(port.audio).toHaveBeenCalledWith("aGk=");
  });

  it("commits the utterance on close, once, however often close is called", () => {
    const { port, session } = openRelay();
    session.close();
    session.close();

    expect(port.stop).toHaveBeenCalledTimes(1);
  });

  it("drops audio pushed after close instead of reopening a sealed utterance", () => {
    const { port, session } = openRelay();
    session.close();
    session.push(new Uint8Array([9]));

    expect(port.audio).not.toHaveBeenCalled();
  });

  it("delivers partial and final transcripts to the open session", () => {
    const { relay, handlers } = openRelay();
    relay.deliver({ kind: "partial", text: "hel" });
    relay.deliver({ kind: "final", text: "hello" });

    expect(handlers.onTranscript.mock.calls).toEqual([
      [{ kind: "partial", text: "hel" }],
      [{ kind: "final", text: "hello" }],
    ]);
  });

  it("drops a transcript that arrives before any session is open", () => {
    const relay = createRelayTranscriber({ port: portHarness(), encodeBase64: fakeBase64 });
    expect(() => relay.deliver({ kind: "final", text: "stray" })).not.toThrow();
  });

  it("drops a late transcript from a hold that already ended", () => {
    // A frame from a previous hold must not land in the current buffer.
    const { relay, handlers, session } = openRelay();
    session.close();
    relay.deliver({ kind: "final", text: "too late" });

    expect(handlers.onTranscript).not.toHaveBeenCalled();
  });

  it("routes transcripts to the newest session only", () => {
    const port = portHarness();
    const relay = createRelayTranscriber({ port, encodeBase64: fakeBase64 });
    const first = handlerHarness();
    const second = handlerHarness();
    relay.transcriber.open(first);
    relay.transcriber.open(second);

    relay.deliver({ kind: "final", text: "current" });

    expect(first.onTranscript).not.toHaveBeenCalled();
    expect(second.onTranscript).toHaveBeenCalledWith({ kind: "final", text: "current" });
  });

  it("does not let a superseded session's close silence the current one", () => {
    // Closing an old session must seal only itself. Clearing the live slot
    // instead would make the current hold deaf to every transcript.
    const port = portHarness();
    const relay = createRelayTranscriber({ port, encodeBase64: fakeBase64 });
    const first = relay.transcriber.open(handlerHarness());
    const current = handlerHarness();
    relay.transcriber.open(current);

    first.close();
    relay.deliver({ kind: "final", text: "current" });

    expect(current.onTranscript).toHaveBeenCalledWith({ kind: "final", text: "current" });
  });

  it("seals the session before reporting a failure", () => {
    // `session.ts`'s onError synchronously calls close() on this session. An
    // unsealed session would send a `stop` on a connection that just failed.
    const port = portHarness();
    const relay = createRelayTranscriber({ port, encodeBase64: fakeBase64 });
    const onError = vi.fn<(reason: string) => void>(() => {
      opened.close();
    });
    const opened = relay.transcriber.open({ onTranscript: vi.fn(), onError });

    relay.fail("provider closed the stream");

    expect(onError).toHaveBeenCalledWith("provider closed the stream");
    expect(port.stop).not.toHaveBeenCalled();
  });

  it("reports the failure reason to the operator", () => {
    const { relay, handlers } = openRelay();
    relay.fail("channel dropped");

    expect(handlers.onError).toHaveBeenCalledWith("channel dropped");
  });

  it("drops audio pushed after a failure", () => {
    const { port, relay, session } = openRelay();
    relay.fail("channel dropped");
    session.push(new Uint8Array([1]));
    session.close();

    expect(port.audio).not.toHaveBeenCalled();
    expect(port.stop).not.toHaveBeenCalled();
  });

  it("drops a failure that arrives when no session is open", () => {
    const relay = createRelayTranscriber({ port: portHarness(), encodeBase64: fakeBase64 });
    const handlers = handlerHarness();
    const session = relay.transcriber.open(handlers);
    session.close();

    relay.fail("channel dropped");

    expect(handlers.onError).not.toHaveBeenCalled();
  });

  it("seals the session when Aiur reports the provider closed it", () => {
    const { port, relay, session } = openRelay();
    relay.finish();
    session.push(new Uint8Array([1]));
    session.close();

    expect(port.audio).not.toHaveBeenCalled();
    expect(port.stop).not.toHaveBeenCalled();
  });

  it("stops delivering transcripts once the session has finished", () => {
    const { relay, handlers } = openRelay();
    relay.finish();
    relay.deliver({ kind: "final", text: "too late" });

    expect(handlers.onTranscript).not.toHaveBeenCalled();
  });

  it("drops a close notice that arrives when no session is open", () => {
    const relay = createRelayTranscriber({ port: portHarness(), encodeBase64: fakeBase64 });
    expect(() => relay.finish()).not.toThrow();
  });
});
