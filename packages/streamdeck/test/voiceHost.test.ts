import { describe, expect, it, vi } from "vitest";

import {
  createRepaintCoalescer,
  createVoiceLink,
  VOICE_LINK_LOST,
  VOICE_REPAINT_INTERVAL_MS,
  VOICE_START_REFUSED,
  type VoiceLinkChannel,
  type VoiceLinkRelay,
} from "../src/voiceHost.js";

const harness = () => {
  const channel = {
    voiceStart: vi.fn<VoiceLinkChannel["voiceStart"]>(),
    voiceAudio: vi.fn<VoiceLinkChannel["voiceAudio"]>(),
    voiceStop: vi.fn<VoiceLinkChannel["voiceStop"]>(),
  };
  const relay: VoiceLinkRelay = { deliver: vi.fn(), fail: vi.fn(), finish: vi.fn() };
  let live: VoiceLinkChannel | null = channel;
  const link = createVoiceLink({ channel: () => live, relay: () => relay });
  return { channel, relay, link, disconnect: () => { live = null; } };
};

describe("createVoiceLink", () => {
  it("asks Aiur to open a session on the first captured frame's hold", () => {
    const { channel, link } = harness();
    link.port.start();
    expect(channel.voiceStart).toHaveBeenCalledOnce();
  });

  /**
   * Capture starts before the reply lands — deliberately, so the recorder does
   * not swallow the first word — so the frames in between have to be kept.
   */
  it("queues audio until the session id arrives, then flushes it in order", () => {
    const { channel, link } = harness();
    link.port.start();
    link.port.audio("aaa");
    link.port.audio("bbb");
    expect(channel.voiceAudio).not.toHaveBeenCalled();

    link.started("s-1", null);
    expect(channel.voiceAudio.mock.calls).toEqual([["s-1", "aaa"], ["s-1", "bbb"]]);

    link.port.audio("ccc");
    expect(channel.voiceAudio).toHaveBeenLastCalledWith("s-1", "ccc");
  });

  it("stops the session the reply names when the hold ended before it arrived", () => {
    const { channel, link } = harness();
    link.port.start();
    link.port.audio("aaa");
    link.port.stop();
    expect(channel.voiceStop).not.toHaveBeenCalled();

    link.started("s-1", null);
    // The buffered audio is still delivered — it is real speech — and only then
    // is the session closed.
    expect(channel.voiceAudio).toHaveBeenCalledWith("s-1", "aaa");
    expect(channel.voiceStop).toHaveBeenCalledWith("s-1");
  });

  it("stops a session whose reply arrives after the link was already dropped", () => {
    const { channel, link } = harness();
    link.port.start();
    link.drop(VOICE_LINK_LOST);
    link.started("s-late", null);
    // Aiur would otherwise hold a provider socket open for a hold that ended.
    expect(channel.voiceStop).toHaveBeenCalledWith("s-late");
  });

  it("ignores a reply for a hold that was never opened, with no session to close", () => {
    const { channel, link } = harness();
    link.started(null, "unconfigured");
    expect(channel.voiceStop).not.toHaveBeenCalled();
  });

  it("fails the relay when Aiur refuses, with and without a reason", () => {
    const refused = harness();
    refused.link.port.start();
    refused.link.started(null, "unconfigured");
    expect(refused.relay.fail).toHaveBeenCalledWith("unconfigured");

    const silent = harness();
    silent.link.port.start();
    silent.link.started(null, null);
    expect(silent.relay.fail).toHaveBeenCalledWith(VOICE_START_REFUSED);
  });

  it("closes the session on a normal stop and stops sending after it", () => {
    const { channel, link } = harness();
    link.port.start();
    link.started("s-1", null);
    link.port.stop();
    expect(channel.voiceStop).toHaveBeenCalledWith("s-1");

    link.port.audio("late");
    link.port.stop();
    expect(channel.voiceAudio).not.toHaveBeenCalled();
    expect(channel.voiceStop).toHaveBeenCalledOnce();
  });

  it("does nothing at all before a hold begins", () => {
    const { channel, link } = harness();
    link.port.audio("orphan");
    link.port.stop();
    expect(channel.voiceAudio).not.toHaveBeenCalled();
    expect(channel.voiceStop).not.toHaveBeenCalled();
  });

  it("delivers transcripts for the open session", () => {
    const { relay, link } = harness();
    link.port.start();
    link.started("s-1", null);
    link.transcript("s-1", { kind: "partial", text: "run the" });
    link.transcript("s-1", { kind: "final", text: "run the tests" });
    expect(relay.deliver).toHaveBeenNthCalledWith(2, { kind: "final", text: "run the tests" });
  });

  /**
   * The reason session ids exist at all: a frame from the previous hold must
   * not land in the buffer of the current one.
   */
  it("drops every frame naming a session it did not open", () => {
    const { relay, link } = harness();
    link.port.start();
    link.started("s-2", null);
    link.transcript("s-1", { kind: "final", text: "stale" });
    link.failed("s-1", "stale failure");
    link.closed("s-1");
    expect(relay.deliver).not.toHaveBeenCalled();
    expect(relay.fail).not.toHaveBeenCalled();
    expect(relay.finish).not.toHaveBeenCalled();
  });

  it("fails and finishes the relay on the matching pushes, once each", () => {
    const failing = harness();
    failing.link.port.start();
    failing.link.started("s-1", null);
    failing.link.failed("s-1", "provider hung up");
    failing.link.failed("s-1", "again");
    expect(failing.relay.fail).toHaveBeenCalledExactlyOnceWith("provider hung up");

    const closing = harness();
    closing.link.port.start();
    closing.link.started("s-1", null);
    closing.link.closed("s-1");
    closing.link.closed("s-1");
    expect(closing.relay.finish).toHaveBeenCalledOnce();
  });

  it("fails an open hold when the channel drops, and only while one is open", () => {
    const { relay, link } = harness();
    link.drop(VOICE_LINK_LOST);
    expect(relay.fail).not.toHaveBeenCalled();

    link.port.start();
    link.started("s-1", null);
    link.drop(VOICE_LINK_LOST);
    expect(relay.fail).toHaveBeenCalledWith(VOICE_LINK_LOST);
  });

  it("survives a missing channel and a missing relay", () => {
    const link = createVoiceLink({ channel: () => null, relay: () => null });
    link.port.start();
    link.port.audio("aaa");
    link.started("s-1", null);
    link.port.audio("bbb");
    link.transcript("s-1", { kind: "final", text: "x" });
    link.port.stop();
    link.started("s-2", null);
    expect(() => link.drop("gone")).not.toThrow();
  });

  it("drops queued audio when the start is refused", () => {
    const { channel, link } = harness();
    link.port.start();
    link.port.audio("aaa");
    link.started(null, "unconfigured");
    link.started("s-1", null);
    expect(channel.voiceAudio).not.toHaveBeenCalled();
  });
});

describe("createRepaintCoalescer", () => {
  /** A hand-driven clock and timer queue: nothing here waits on wall time. */
  const clock = (intervalMs?: number) => {
    let time = 1_000;
    const repaint = vi.fn();
    const timers: { at: number; fn: () => void }[] = [];
    const coalescer = createRepaintCoalescer({
      repaint,
      now: () => time,
      setTimer: (fn, ms) => { timers.push({ at: time + ms, fn }); },
      intervalMs,
    });
    return {
      repaint,
      timers,
      coalescer,
      advance: (ms: number) => { time += ms; },
      runTimers: () => { for (const timer of timers.splice(0)) { time = timer.at; timer.fn(); } },
    };
  };

  it("repaints the first request immediately", () => {
    const host = clock();
    host.coalescer.request();
    expect(host.repaint).toHaveBeenCalledOnce();
    expect(host.timers).toHaveLength(0);
  });

  // 50 Hz of capture updates must not become 50 Hz of 800x100 JPEG encodes.
  it("collapses a burst inside one interval into a single deferred repaint", () => {
    const host = clock();
    host.coalescer.request();
    for (let frame = 0; frame < 20; frame += 1) {
      host.advance(1);
      host.coalescer.request();
    }
    expect(host.repaint).toHaveBeenCalledOnce();
    expect(host.timers).toHaveLength(1);

    host.runTimers();
    expect(host.repaint).toHaveBeenCalledTimes(2);
  });

  it("schedules the deferred repaint for the remainder of the interval", () => {
    const host = clock();
    host.coalescer.request();
    host.advance(30);
    host.coalescer.request();
    expect(host.timers[0].at).toBe(1_000 + VOICE_REPAINT_INTERVAL_MS);
  });

  it("repaints immediately again once the interval has passed", () => {
    const host = clock();
    host.coalescer.request();
    host.advance(VOICE_REPAINT_INTERVAL_MS);
    host.coalescer.request();
    expect(host.repaint).toHaveBeenCalledTimes(2);
    expect(host.timers).toHaveLength(0);
  });

  it("takes an injected interval", () => {
    const host = clock(10);
    host.coalescer.request();
    host.advance(4);
    host.coalescer.request();
    expect(host.timers[0].at).toBe(1_004 + 6);
  });
});
