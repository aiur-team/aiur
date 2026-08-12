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

import { spawn } from "node:child_process";
import net from "node:net";
import process from "node:process";

import { findByIds, InEndpoint, type Interface, LibUSBException, OutEndpoint, usb } from "usb";

import { parseBrightness } from "./device-path.js";
import { connectStreamDeckChannel, defaultFetch, defaultWebSocket, type StreamDeckGrid } from "./channel.js";
import { decodeInputReport, risingEdges } from "./input.js";
import type { HidBackend } from "./backend.js";
import { columnOffsetFromDial, maxColumnOffset, applyStep } from "./dial.js";
import { POLL_INTERVAL_MS, PRODUCT_ID, VENDOR_ID } from "./report.js";
import { startRuntime } from "./runtime.js";
import type { Runtime } from "./runtime.js";
import { createPhysicalSurface, type PhysicalSurfaceState } from "./surface.js";
import { openUsbBackend, type UsbDeviceLike } from "./usb-backend.js";

/** HID interface number on the Stream Deck +. */
const HID_INTERFACE = 0;
/** Timeout for feature-report control transfers. */
const CONTROL_TIMEOUT_MS = 1000;

/** True when a matching Stream Deck + is present on the USB bus right now. */
const deviceIsPresent = (): boolean => findByIds(VENDOR_ID, PRODUCT_ID) !== undefined;

/**
 * Opens the Stream Deck + over libusb and adapts it to {@link UsbDeviceLike}.
 * Wraps the callback-based `usb` primitives as promises and maps a libusb
 * timeout on the interrupt-IN endpoint to a poll `timeout` rather than an error.
 */
const openStreamDeckDevice = async (): Promise<UsbDeviceLike> => {
  const device = findByIds(VENDOR_ID, PRODUCT_ID);
  if (device === undefined) {
    throw new Error("Stream Deck + not found: no USB device with VID 0x0fd9 / PID 0x0084");
  }

  device.open();
  // Everything after open() must close the handle on failure, or a leaked open
  // handle makes the next reconnect attempt fail with LIBUSB_ERROR_BUSY — a
  // self-inflicted "present but won't open" that would trip the operator alert.
  let inEndpoint: InEndpoint;
  let outEndpoint: OutEndpoint;
  let iface: Interface;
  try {
    device.timeout = CONTROL_TIMEOUT_MS;
    device.setAutoDetachKernelDriver(true);

    iface = device.interface(HID_INTERFACE);
    const foundIn = iface.endpoints.find((endpoint): endpoint is InEndpoint => endpoint.direction === "in");
    const foundOut = iface.endpoints.find((endpoint): endpoint is OutEndpoint => endpoint.direction === "out");
    if (foundIn === undefined || foundOut === undefined) {
      throw new Error("Stream Deck + interface is missing an interrupt endpoint");
    }
    inEndpoint = foundIn;
    outEndpoint = foundOut;
    // A read timeout means "no event pending", so bound the poll to the interval.
    inEndpoint.timeout = POLL_INTERVAL_MS;
    // Bulk OUT (the 1024-byte key-stream reset, image chunks) can legitimately
    // take longer than the control timeout; use no timeout so a slow-but-healthy
    // write is not misread as a failure.
    outEndpoint.timeout = 0;
  } catch (error) {
    device.close();
    throw error;
  }

  return {
    claim: async () => {
      iface.claim();
    },
    controlOut: (bmRequestType, bRequest, wValue, wIndex, data) =>
      new Promise<void>((resolve, reject) => {
        device.controlTransfer(bmRequestType, bRequest, wValue, wIndex, Buffer.from(data), (error) =>
          error ? reject(error) : resolve(),
        );
      }),
    controlIn: (bmRequestType, bRequest, wValue, wIndex, length) =>
      new Promise((resolve, reject) => {
        device.controlTransfer(bmRequestType, bRequest, wValue, wIndex, length, (error, buffer) =>
          error ? reject(error) : resolve(Uint8Array.from(buffer as Buffer)),
        );
      }),
    transferOut: (data) =>
      new Promise<void>((resolve, reject) => {
        outEndpoint.transfer(Buffer.from(data), (error?: LibUSBException) => (error ? reject(error) : resolve()));
      }),
    transferIn: (length) =>
      new Promise((resolve, reject) => {
        inEndpoint.transfer(length, (error: LibUSBException | undefined, data?: Buffer) => {
          if (error) {
            if (error.errno === usb.LIBUSB_ERROR_TIMEOUT) {
              resolve({ timedOut: true });
              return;
            }
            reject(error);
            return;
          }
          resolve({ timedOut: false, data: Uint8Array.from(data ?? Buffer.alloc(0)) });
        });
      }),
    close: async () => {
      await new Promise<void>((resolve) => iface.release(true, () => resolve()));
      device.close();
    },
  };
};

export const main = async (): Promise<void> => {
  const brightness = parseBrightness(process.env.STREAMDECK_BRIGHTNESS);
  const presentAtStart = deviceIsPresent();
  let latestGrid: StreamDeckGrid = { agents: [], total: 0, windows: 0, max_column_offset: 0 };
  let latestUsage: Readonly<Record<string, unknown>> = {};
  let activeBackend: HidBackend | null = null;
  let channel: Awaited<ReturnType<typeof connectStreamDeckChannel>> | null = null;
  let pressed = new Set<string>();
  let currentMode: "grid" | "cmd" | "logs" = "grid";
  let focusedIdentifier: string | null = null;
  let runtime: Runtime | null = null;
  let columnOffset = 0;
  let dial3Value = 0;
  let transcriptLines: string[] = [];
  let repaintChain: Promise<void> = Promise.resolve();
  const surface = createPhysicalSurface();

  const repaint = async (backend: HidBackend): Promise<void> => {
    activeBackend = backend;
    const state: PhysicalSurfaceState = { mode: currentMode, focusedIdentifier, columnOffset, transcriptLines };
    const next = repaintChain.then(() => surface.repaint(backend, latestGrid, latestUsage, runtime ?? undefined, state));
    repaintChain = next.catch(() => undefined);
    await next;
  };

  const handleInput = (data: Uint8Array): void => {
    const decoded = decodeInputReport(data);
    for (const input of decoded) {
      if (input.type !== "encoder-turn") continue;
      if (input.index === 3 && (currentMode === "grid" || currentMode === "cmd")) {
        dial3Value = applyStep(dial3Value, input.ticks > 0 ? 1 : -1);
        columnOffset = columnOffsetFromDial(dial3Value, latestGrid.total);
      }
    }
    const edges = risingEdges(decoded, pressed);
    pressed = new Set(edges.pressed);
    for (const input of edges.events) {
      if (input.type === "key") {
        const agent = latestGrid.agents[(columnOffset * 2) + (input.index % 8)];
        const identifier = typeof agent?.identifier === "string" ? agent.identifier : null;
        const bucket = typeof agent?.bucket === "string" ? agent.bucket : null;
        if (identifier !== null && currentMode === "grid") {
          focusedIdentifier = identifier;
          channel?.focus(identifier);
          currentMode = "cmd";
        } else if (identifier !== null && currentMode === "cmd" && input.index === 2) {
          currentMode = "logs";
        } else if (identifier !== null && currentMode === "cmd" && input.index === 0 && (bucket === "running" || bucket === "paused")) {
          channel?.control(identifier, bucket === "running" ? "pause" : "resume");
        }
      }
      if (input.type === "encoder-button" && input.index === 0 && currentMode === "logs") currentMode = "cmd";
      else if (input.type === "encoder-button" && input.index === 0 && currentMode === "cmd") currentMode = "grid";
      else if (input.type === "encoder-button" && input.index === 3 && currentMode === "grid") {
        columnOffset = Math.min(columnOffset + 4, maxColumnOffset(latestGrid.total));
      }
    }
  };

  const baseUrl = process.env.AIUR_PHOENIX_URL;
  if (baseUrl && process.env.AIUR_DASHBOARD_USERNAME && process.env.AIUR_DASHBOARD_PASSWORD) {
    let reconnectAttempt = 0;
    const connectDaemon = (): void => {
      void connectStreamDeckChannel({
        baseUrl,
        username: process.env.AIUR_DASHBOARD_USERNAME as string,
        password: process.env.AIUR_DASHBOARD_PASSWORD as string,
        fetch: defaultFetch,
        websocket: defaultWebSocket,
        events: {
          snapshot: (snapshot) => { reconnectAttempt = 0; if (snapshot.grid !== undefined) latestGrid = snapshot.grid; latestUsage = snapshot.usage; if (activeBackend !== null) void repaint(activeBackend); },
          fleet: () => undefined,
          grid: (grid) => { latestGrid = grid; if (activeBackend !== null) void repaint(activeBackend); },
          usage: (usage) => { latestUsage = usage; if (activeBackend !== null) void repaint(activeBackend); },
          transcript: (line) => { transcriptLines = [...transcriptLines.slice(-20), line]; if (activeBackend !== null) void repaint(activeBackend); },
          control: () => undefined,
          closed: (error) => {
            console.warn("[streamdeck] channel closed; renewing token and reconnecting", error);
            channel = null;
            const delay = Math.min(30_000, 500 * 2 ** reconnectAttempt++);
            setTimeout(connectDaemon, delay);
          },
        },
      }).then((connected) => { channel = connected; if (focusedIdentifier !== null) channel.focus(focusedIdentifier); }).catch((error) => {
        console.warn("[streamdeck] daemon channel unavailable; retrying", error);
        const delay = Math.min(30_000, 500 * 2 ** reconnectAttempt++);
        setTimeout(connectDaemon, delay);
      });
    };
    connectDaemon();
  } else {
    console.warn("[streamdeck] AIUR_PHOENIX_URL and dashboard credentials are required for fleet controls");
  }

  if (!presentAtStart) {
    console.info("[streamdeck] no Stream Deck + detected; waiting for hotplug");
  }

  runtime = await startRuntime({
    spawn,
    net,
    brightness,
    devicePresentAtStart: presentAtStart,
    openBackend: async () => {
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
    registerSignals: (handler) => {
      const shutdown = (): void => {
        channel?.close();
        handler();
      };
      process.on("SIGTERM", shutdown);
      process.on("SIGINT", shutdown);
    },
    exit: () => process.exit(0),
    setTimer: (fn, ms) => setTimeout(fn, ms),
    clearTimer: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
    log: ({ level, message, cause }) => {
      const line = `[streamdeck] ${message}`;
      if (level === "error") {
        console.error(line, cause ?? "");
      } else if (level === "warn") {
        console.warn(line, cause ?? "");
      } else {
        console.info(line);
      }
    },
  });
};

void main().catch((error) => {
  console.error("[streamdeck] fatal:", error);
  process.exitCode = 1;
});
