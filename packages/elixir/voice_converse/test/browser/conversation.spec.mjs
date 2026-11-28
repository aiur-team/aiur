import { test, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

async function installMockSocket(page) {
  await page.addInitScript(() => {
    window.__micCalls = 0;
    window.__frames = [];
    class FakeSocket extends EventTarget {
      static OPEN = 1;
      constructor(url) {
        super();
        this.url = url;
        this.readyState = 0;
        window.__socket = this;
        setTimeout(() => {
          this.readyState = 1;
          this.dispatchEvent(new Event("open"));
        }, 0);
      }
      send(frame) { window.__frames.push(JSON.parse(frame)); }
      close() { this.readyState = 3; this.dispatchEvent(new Event("close")); }
    }
    window.WebSocket = FakeSocket;
    Object.defineProperty(navigator.mediaDevices, "getUserMedia", {
      configurable: true,
      value: async () => {
        window.__micCalls += 1;
        return { getAudioTracks: () => [{ enabled: true, stop() {} }], getTracks: () => [{ stop() {} }] };
      },
    });
  });
  await page.goto("/talk.html?ws=ws%3A%2F%2F127.0.0.1%2Fvoice&target=%7B%22id%22%3A%22ticket-42%22%7D");
  await page.waitForFunction(() => window.voiceConverse);
}

test.beforeEach(async ({ page }, testInfo) => {
  if (testInfo.title.startsWith("smokes a WebSock")) return;
  await installMockSocket(page);
});

test("does not request microphone permission before Start", async ({ page }) => {
  await expect.poll(() => page.evaluate(() => window.__micCalls)).toBe(0);
});

test("smokes a WebSock session with FakeProvider through start, one turn and user end", async ({ browser }) => {
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto("http://127.0.0.1:4187/talk.html?ws=ws%3A%2F%2F127.0.0.1%3A4187%2Fvoice%3Ftoken%3Dbrowser-test-token&target=%7B%22id%22%3A%22browser-target%22%7D");
  await page.evaluate(() => {
    window.__realFrames = [];
    window.__pageErrors = [];
    window.addEventListener("error", (event) => window.__pageErrors.push(event.message));
    const OriginalWebSocket = window.WebSocket;
    window.WebSocket = class extends OriginalWebSocket {
      constructor(...args) {
        super(...args);
        this.addEventListener("message", (event) => window.__realFrames.push(JSON.parse(event.data)));
      }
    };
  });
  await page.getByRole("button", { name: "Text only" }).click();
  await page.getByRole("button", { name: "Start text conversation" }).click();
  await expect(page.locator("#state-detail")).toHaveText("Listening");
  await expect(page.locator("#user-transcript")).toHaveText("Hello there");
  await expect(page.locator("#assistant-text")).toHaveText("Hi");
  const message = page.getByLabel("Message");
  await message.fill("text reaches provider");
  await message.press("Enter");
  await expect(page.locator("#user-transcript")).toHaveText("text reaches provider");
  await page.getByRole("button", { name: "End", exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.__realFrames.some((frame) => frame.type === "ended" && frame.reason === "user_end"))).toBe(true);
  await expect(page.locator("#state-detail")).toHaveText("Ended");
  await expect.poll(() => page.evaluate(() => window.__pageErrors)).toEqual([]);
  await context.close();
});

test("text-only mode starts without a microphone and preserves the focused draft while replies stream", async ({ page }) => {
  await page.getByRole("button", { name: "Text only" }).click();
  await page.getByRole("button", { name: "Start text conversation" }).click();
  await expect.poll(() => page.evaluate(() => window.__frames.some((frame) => frame.type === "start"))).toBe(true);
  await expect.poll(() => page.evaluate(() => window.__micCalls)).toBe(0);
  const input = page.getByLabel("Message");
  await input.fill("keep this text");
  await input.press("Enter");
  await expect.poll(() => page.evaluate(() => window.__frames.some((frame) => frame.type === "text" && frame.text === "keep this text"))).toBe(true);
  await page.evaluate(() => window.voiceConverse.receive({
    data: JSON.stringify({ v: 1, type: "agent_text", turn_id: "t1", text: "A reply", final: false }),
  }));
  await expect(input).toBeFocused();
  await expect(input).toHaveValue("keep this text");
  await expect(page.locator("#assistant-text")).toHaveText("A reply");
});

test("reveals timed text against the audio clock and reports one exact interruption offset", async ({ page }) => {
  await page.evaluate(() => {
    const client = window.voiceConverse;
    client.audioContext = { currentTime: 0 };
    client.receive({ data: JSON.stringify({
      v: 1, type: "agent_text_timing", turn_id: "timed", text: "Hi", audio_offset_ms: 0,
      estimated: false, chars: [{ offset_ms: 0, length: 1 }, { offset_ms: 500, length: 1 }],
    }) });
    client.receive({ data: JSON.stringify({ v: 1, type: "agent_text", turn_id: "timed", text: "Hi", final: false }) });
  });
  await expect(page.locator("#assistant-text")).toHaveText("H");
  await page.evaluate(() => { window.voiceConverse.audioContext.currentTime = 0.6; });
  await expect(page.locator("#assistant-text")).toHaveText("Hi");

  const elapsed = await page.evaluate(() => {
    const client = window.voiceConverse;
    const sent = [];
    let stoppedAt = null;
    client.send = (frame) => sent.push(frame);
    client.audioContext.currentTime = 2.15;
    client.playbackClock = { startedAt: 2, turnId: "timed" };
    client.playing = { stop() { stoppedAt = performance.now(); } };
    const before = performance.now();
    client.receive({ data: JSON.stringify({ v: 1, type: "interrupted", turn_id: "timed" }) });
    client.receive({ data: JSON.stringify({ v: 1, type: "interrupted", turn_id: "timed" }) });
    return { elapsed: stoppedAt - before, frames: sent };
  });
  expect(elapsed.elapsed).toBeLessThan(150);
  expect(elapsed.frames).toEqual([{ type: "playback_state", state: "stopped", turn_id: "timed", played_until_ms: 150 }]);
  await expect(page.locator("#assistant-text")).toHaveText("H");
});

test("a provider with no interruption event still stops on local speech start", async ({ page }) => {
  const result = await page.evaluate(async () => {
    const client = window.voiceConverse;
    const sent = [];
    client.send = (frame) => sent.push(frame);
    client.audioContext = { currentTime: 1.1 };
    client.playbackClock = { startedAt: 1, turnId: "live" };
    let stopped = false;
    client.playing = { stop() { stopped = true; } };
    const source = { connect() {} };
    const analyser = { fftSize: 0, getFloatTimeDomainData(samples) { samples.fill(0.1); }, disconnect() {} };
    client.installLocalBargeIn(source, { createAnalyser: () => analyser });
    await new Promise((resolve) => setTimeout(resolve, 60));
    client.receive({ data: JSON.stringify({ v: 1, type: "session_info", option_id: "provider_without_interruption", label: "Provider without interruption", interruption_supported: false }) });
    await new Promise((resolve) => setTimeout(resolve, 60));
    clearTimeout(client.bargeInTimer);
    return { stopped, sent };
  });
  expect(result.stopped).toBe(true);
  expect(result.sent).toEqual([{ type: "playback_state", state: "stopped", turn_id: "live", played_until_ms: 100 }]);
});

test("browser STT streams live text and interrupts playback on speech start", async ({ page }) => {
  const result = await page.evaluate(() => {
    class Recognition extends EventTarget {
      start() {}
      stop() {}
      emit(type, properties = {}) { this.dispatchEvent(Object.assign(new Event(type), properties)); }
    }
    window.SpeechRecognition = Recognition;
    const client = window.voiceConverse;
    client.browserStt = true;
    client.send = (frame) => window.__frames.push(frame);
    client.audioContext = { currentTime: 1.2 };
    client.playbackClock = { startedAt: 1, turnId: "stt-turn" };
    client.playing = { stop() {} };
    return client.startFromClick().then(() => {
      const recognition = client.speechRecognition;
      recognition.emit("result", { resultIndex: 0, results: [{ 0: { transcript: "start" }, isFinal: false }] });
      const partial = document.querySelector("#user-transcript").textContent;
      recognition.emit("speechstart");
      recognition.emit("result", { resultIndex: 0, results: [{ 0: { transcript: "start run" }, isFinal: true }] });
      return { partial, micCalls: window.__micCalls, frames: window.__frames };
    });
  });
  expect(result.partial).toBe("start");
  expect(result.micCalls).toBe(0);
  expect(result.frames).toEqual([
    { type: "start", target: { id: "ticket-42" } },
    { type: "playback_state", state: "stopped", turn_id: "stt-turn", played_until_ms: 200 },
    { type: "text", text: "start run" },
  ]);
});

test("draft cards confirm once, preserve edits and discard locally", async ({ page }) => {
  const frames = await page.evaluate(() => {
    const client = window.voiceConverse;
    const sent = [];
    client.send = (frame) => sent.push(frame);
    client.receive({ data: JSON.stringify({ v: 1, type: "draft", draft_id: "confirm", kind: "instruction", target: { id: "x" }, text: "Original", status: "proposed" }) });
    const card = client.drafts.get("confirm");
    const buttons = [...card.querySelectorAll("button")];
    buttons.find((button) => button.textContent === "Edit").click();
    const editor = card.querySelector("textarea");
    editor.value = "Edited";
    editor.dispatchEvent(new Event("input", { bubbles: true }));
    const confirm = buttons.find((button) => button.textContent === "Confirm");
    confirm.click();
    confirm.click();
    client.receive({ data: JSON.stringify({ v: 1, type: "draft", draft_id: "discard", kind: "instruction", target: { id: "x" }, text: "Discard me", status: "proposed" }) });
    client.drafts.get("discard").querySelector("button:last-child").click();
    return sent;
  });
  expect(frames).toEqual([
    { type: "confirm_draft", draft_id: "confirm", edited_text: "Edited" },
    { type: "discard_draft", draft_id: "discard" },
  ]);
});

test("hides absent session fields and has no serious axe issues or 360 px overflow", async ({ page }) => {
  await page.evaluate(() => window.voiceConverse.receive({
    data: JSON.stringify({ v: 1, type: "session_info", option_id: "fake", label: "Fake" }),
  }));
  await expect(page.locator('[data-session-info="option"]')).toHaveText("Fake");
  await expect(page.locator('[data-session-info="cost"]')).toBeHidden();
  await page.setViewportSize({ width: 360, height: 800 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(360);
  const accessibility = await new AxeBuilder({ page }).analyze();
  expect(accessibility.violations.filter((violation) => violation.impact === "serious")).toEqual([]);
});
