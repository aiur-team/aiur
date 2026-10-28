/**
 * Process entry point: constructs the real Node primitives and the real libusb
 * device, then hands them to the fully-tested {@link startRuntime}.
 *
 * This file is intentionally excluded from coverage (see vitest.config.ts): it
 * contains only dependency wiring — real `node:net`, `node:child_process`,
 * `node:process`, and the `usb` package adapted to the tested
 * {@link UsbDeviceLike} surface — with no branching logic worth unit-testing in
 * isolation. Everything it wires is covered through the injected fakes in the
 * runtime, backend, and adapter tests. The hardware acceptance items (open by
 * VID/PID, suspend/resume, unplug/replug, feature reports) are verified by
 * running this against a real Stream Deck +.
 *
 * **Backend: libusb.** #1354's acceptance requires brightness, reset/Show Logo,
 * serial, and firmware — all FEATURE reports — to work, and the hidraw/`node:fs`
 * backend cannot issue feature reports (no ioctls). Per the ticket, "if it
 * cannot, use libusb": this wires the {@link file://./usb-backend.ts} backend,
 * which claims the interface and speaks OUTPUT/INPUT reports over the interrupt
 * endpoints and FEATURE reports over control transfers. `usb` ships N-API
 * prebuilt binaries, so it needs no native toolchain at install time.
 */
import { createDeviceInventory } from "./device-inventory.js";
import { createNodeSystem, createFilePreferenceStore } from "./audio/index.js";
import { type DeckSettings, type DeckDevices } from "./deck-settings.js";
import { createDeckAlerts, deckChime } from "./deck-alerts.js";
import { createDeckAudio } from "./deck-audio.js";
import { spawn } from "node:child_process";
import net from "node:net";
import process from "node:process";
import path from "node:path";
import { loadInstances } from "./instances.js";
import { createInstanceSwitcher } from "./instance-switcher.js";
import { guardChannelEvents } from "./instance-events.js";
import { parseBrightness } from "./device-path.js";
import { connectStreamDeckChannel, defaultFetch, defaultWebSocket, type StreamDeckChannel } from "./channel.js";
import type { HidBackend } from "./backend.js";
import { FrameRenderer, offlineFrame, registerFrameFont, type DeckFrame } from "./frame.js";
import { createFrameInput } from "./frame-input.js";
import { startRuntime, type Runtime } from "./runtime.js";
import { openUsbBackend } from "./usb-backend.js";
import { deviceIsPresent, HID_INTERFACE, openStreamDeckDevice } from "./hid-device.js";
import { logLine, micPreferencePath, traceInput } from "./sidecar-wiring.js";

export const main = async (): Promise<void> => {
  registerFrameFont();
  const offline = offlineFrame();
  let latestFrame: DeckFrame = offline;
  const renderer = new FrameRenderer();
  const brightness = parseBrightness(process.env.STREAMDECK_BRIGHTNESS);
  const presentAtStart = process.env.AIUR_STREAMDECK_FORCE_ABSENT === "1" ? false : deviceIsPresent();
  let activeBackend: HidBackend | null = null;
  let channel: StreamDeckChannel | null = null;
  let runtime: Runtime | null = null;
  let settings: DeckSettings | null = null;
  let devices: DeckDevices = { mics: [], speakers: [], instances: [] };
  const system = createNodeSystem();
  const audio = createDeckAudio({ settings: () => settings, devices: () => devices, system });
  const alert = createDeckAlerts({
    choices: () => settings?.alerts ?? {},
    flash: () => runtime?.flash(),
    chime: () => {
      const port = audio.playback();
      void Promise.resolve().then(() => port.write(deckChime())).finally(() => port.close()).catch((error: unknown) => console.warn("[streamdeck] chime failed", error));
    },
  });
  const input = createFrameInput((event) => { instances.resetSelectionChain(); channel?.input(event); });
  const handleInput = (data: Uint8Array): void => { traceInput(data); input.handleReport(data); };
  const repaint = async (backend: HidBackend): Promise<void> => {
    activeBackend = backend;
    await renderer.apply(backend, latestFrame);
  };
  const show = (frame: DeckFrame): void => {
    latestFrame = frame;
    if (activeBackend !== null) void repaint(activeBackend).catch((error: unknown) => {
      console.warn("[streamdeck] repaint failed; recovering the device", error);
      runtime?.notifyWriteFailure(error);
    });
  };
  const registry = loadInstances({
    name: "local",
    baseUrl: process.env.AIUR_PHOENIX_URL ?? "http://127.0.0.1:4000",
    auth: { token: process.env.AIUR_CLIENT_TOKEN, username: process.env.AIUR_DASHBOARD_USERNAME, password: process.env.AIUR_DASHBOARD_PASSWORD },
  });
  if (registry.error) console.warn(`[streamdeck] ${registry.error}`);
  const inventory = createDeviceInventory({
    system, spawn, instances: registry.targets.map((target) => target.name),
    legacyMicId: createFilePreferenceStore(micPreferencePath()).read(),
    changed: (value) => { devices = value; channel?.devices(value); },
    setTimer: (fn, ms) => setTimeout(fn, ms),
    clearTimer: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
  });
  const instances = createInstanceSwitcher<StreamDeckChannel>({
    targets: registry.targets,
    preferencePath: path.join(path.dirname(micPreferencePath()), "streamdeck-instance.json"),
    changed: () => undefined,
    channel: (connected) => { channel = connected; if (connected !== null) void inventory.refresh(); },
    disconnect: () => { input.reset(); show(offline); },
    resetInstance: () => show(offline),
    connect: (target, lifecycle) => connectStreamDeckChannel({
      baseUrl: target.baseUrl,
      ...target.auth,
      fetch: defaultFetch,
      websocket: defaultWebSocket,
      events: guardChannelEvents({
        snapshot: () => { lifecycle.connected(); void inventory.refresh(); },
        settings: (value) => {
          settings = value;
          runtime?.applySettings(value);
          if (value.instance !== null) instances.select(value.instance);
        },
        alert,
        frame: show,
        fleet: () => undefined,
        grid: () => undefined,
        usage: () => undefined,
        transcript: () => undefined,
        logs: () => undefined,
        control: () => undefined,
        commands: () => undefined,
        commandAnswered: () => undefined,
        commandsError: () => undefined,
        voiceStarted: () => undefined,
        voice: () => undefined,
        voiceError: () => undefined,
        voiceClosed: () => undefined,
        voiceAvailability: () => undefined,
        closed: () => lifecycle.closed(),
      }, lifecycle.current),
    }),
  });
  instances.start();
  if (!presentAtStart) console.info("[streamdeck] no Stream Deck + detected; waiting for hotplug");

  runtime = await startRuntime({
    spawn,
    net,
    brightness,
    devicePresentAtStart: presentAtStart,
    openBackend: async () => {
      if (process.env.AIUR_STREAMDECK_FORCE_ABSENT === "1") {
        throw new Error("Stream Deck + not found: forced absent test mode");
      }
      try {
        return openUsbBackend(await openStreamDeckDevice(), { interfaceNumber: HID_INTERFACE });
      } catch (error) {
        if (error instanceof Error && error.message.includes("LIBUSB_ERROR_NO_DEVICE")) {
          console.info("[streamdeck] no Stream Deck + detected; waiting for hotplug");
        }
        throw error;
      }
    },
    onInput: handleInput,
    repaint,
    onBackendClosed: (backend) => {
      if (backend !== null && activeBackend === backend) activeBackend = null;
      input.reset();
      renderer.invalidate();
    },
    registerSignals: (handler) => {
      const shutdown = (): void => {
        inventory.stop();
        instances.close();
        handler();
      };
      process.on("SIGTERM", shutdown);
      process.on("SIGINT", shutdown);
    },
    exit: () => process.exit(0),
    setTimer: (fn, ms) => setTimeout(fn, ms),
    clearTimer: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
    log: logLine,
  });
  if (settings !== null) runtime.applySettings(settings);
};

void main().catch((error) => {
  console.error("[streamdeck] fatal:", error);
  process.exitCode = 1;
});
