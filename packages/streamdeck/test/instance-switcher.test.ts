import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { createInstanceSwitcher } from "../src/instance-switcher.js";
import { InstanceAuthError } from "../src/channel-types.js";
import type { InstanceTarget } from "../src/instances.js";

const dirs: string[] = [];
const setup = () => {
  const dir = mkdtempSync(path.join(tmpdir(), "sd207-switch-")); dirs.push(dir);
  const preferencePath = path.join(dir, "config", "streamdeck-instance.json");
  const targets: InstanceTarget[] = [
    { name: "local", baseUrl: "http://localhost:4000", auth: { username: "op", password: "private" } },
    { name: "remote", baseUrl: "https://remote.test", auth: { token: "bearer-secret" } },
  ];
  const connect = vi.fn(async (target: unknown, lifecycle: unknown) => { void target; void lifecycle; return { close: vi.fn() }; });
  return { targets, preferencePath, connect, changed: vi.fn(), disconnect: vi.fn(), channel: vi.fn() };
};
afterEach(() => { vi.useRealTimers(); dirs.splice(0).forEach((dir) => rmSync(dir, { recursive: true, force: true })); });

it("browses without network, closes before connecting and remembers activation", async () => {
  const options = setup(); const order: string[] = [];
  options.connect.mockImplementation(async (target) => { const { name } = target as InstanceTarget; order.push(`open:${name}`); return { close: vi.fn(() => order.push(`close:${name}`)) }; });
  const switcher = createInstanceSwitcher(options); switcher.start(); await switcher.idle();
  switcher.turn(1);
  expect(switcher.label()).toBe("local · connecting | ◀ remote ▶ · press to connect");
  expect(options.connect).toHaveBeenCalledTimes(1);
  switcher.press(); await switcher.idle();
  expect(order).toEqual(["open:local", "close:local", "open:remote"]);
  expect(options.connect.mock.calls[1]![0]).toMatchObject({ baseUrl: "https://remote.test", auth: { token: "bearer-secret" } });
  expect(JSON.parse(readFileSync(options.preferencePath, "utf8"))).toBe("remote");
  expect(switcher.label()).not.toContain("bearer-secret");
  switcher.close();
  const restored = createInstanceSwitcher(options); restored.start(); await restored.idle();
  expect(options.connect.mock.calls[2]![0]).toMatchObject({ name: "remote" }); restored.close();
});

it("refuses invalid URL or file mode before closing the current instance", async () => {
  const options = setup(); const switcher = createInstanceSwitcher(options); switcher.start(); await switcher.idle();
  const local = options.connect.mock.results[0]!; const channel = await local.value;
  options.targets[1]!.baseUrl = "http://remote.test";
  switcher.turn(1); switcher.press(); await switcher.idle();
  expect(switcher.label()).toContain("Instance URL must be HTTPS");
  expect(channel.close).not.toHaveBeenCalled(); expect(options.connect).toHaveBeenCalledTimes(1);
  options.targets[1]!.baseUrl = "https://remote.test";
  mkdirSync(path.dirname(options.preferencePath), { recursive: true });
  writeFileSync(options.preferencePath + ".token", "secret", { mode: 0o644 });
  chmodSync(options.preferencePath + ".token", 0o644);
  options.targets[1]!.auth = { token_file: options.preferencePath + ".token" };
  switcher.press(); expect(switcher.label()).toContain("mode 0600"); expect(channel.close).not.toHaveBeenCalled(); switcher.close();
});

it("shows authentication failure with no fallback, retry or secret output", async () => {
  vi.useFakeTimers(); const options = setup(); const switcher = createInstanceSwitcher(options);
  switcher.start(); await switcher.idle();
  options.connect.mockRejectedValueOnce(new InstanceAuthError("bearer-secret"));
  switcher.turn(1); switcher.press(); await switcher.idle();
  expect(switcher.label()).toBe("remote · auth failed");
  await vi.advanceTimersByTimeAsync(60_000); expect(options.connect).toHaveBeenCalledTimes(2); switcher.close();
});

it("serializes in-flight connects and suppresses late lifecycle events", async () => {
  const options = setup(); let complete!: (channel: Awaited<ReturnType<typeof options.connect>>) => void;
  options.connect.mockImplementationOnce(() => new Promise((resolve) => { complete = resolve; }));
  const switcher = createInstanceSwitcher(options); switcher.start(); await Promise.resolve();
  const old = options.connect.mock.calls[0]![1] as { current(): boolean; connected(): void; closed(): void };
  switcher.turn(1); switcher.press(); await Promise.resolve();
  expect(options.connect).toHaveBeenCalledTimes(1); expect(old.current()).toBe(false);
  old.connected(); old.closed(); expect(switcher.label()).toBe("remote · connecting");
  const closed = vi.fn(); complete({ close: closed }); await switcher.idle();
  expect(closed).toHaveBeenCalledOnce(); expect(options.connect).toHaveBeenCalledTimes(2);
  const current = options.connect.mock.calls[1]![1] as typeof old;
  current.connected(); expect(switcher.label()).toBe("remote · connected"); switcher.close();
});

it("retries the selected unreachable daemon and discards closed connections", async () => {
  vi.useFakeTimers(); const options = setup(); options.connect.mockRejectedValueOnce(new Error("private network details"));
  const switcher = createInstanceSwitcher(options); switcher.start(); await switcher.idle();
  expect(switcher.label()).toBe("local · unreachable"); await vi.advanceTimersByTimeAsync(500); await switcher.idle();
  const lifecycle = options.connect.mock.calls[1]![1] as { current(): boolean; connected(): void; closed(): void };
  lifecycle.connected(); lifecycle.closed(); lifecycle.closed(); expect(lifecycle.current()).toBe(false);
  expect(switcher.label()).toBe("local · unreachable");
  await vi.advanceTimersByTimeAsync(500); await switcher.idle(); expect(options.connect).toHaveBeenCalledTimes(3); switcher.close();
});

it("skips superseded queued attempts, handles preferences and save failures", async () => {
  const options = setup();
  writeFileSync(path.dirname(options.preferencePath), "not a directory");
  const switcher = createInstanceSwitcher(options);
  switcher.start(); switcher.turn(-1); switcher.press(); await switcher.idle();
  expect(options.connect).toHaveBeenCalledTimes(1); expect(switcher.label()).toContain("Cannot save instance preference");
  switcher.close();
  rmSync(path.dirname(options.preferencePath)); writeFileSync(path.dirname(options.preferencePath), '"unknown"');
  const next = createInstanceSwitcher({ ...options, preferencePath: path.dirname(options.preferencePath) }); next.start(); await next.idle();
  expect(options.connect.mock.calls[1]![0]).toMatchObject({ name: "local" }); next.close();
});

it("does not retain a socket that closed during construction", async () => {
  vi.useFakeTimers(); const options = setup(); const close = vi.fn();
  options.connect.mockImplementationOnce(async (_target, lifecycle) => { (lifecycle as { closed(): void }).closed(); return { close }; });
  const switcher = createInstanceSwitcher(options); switcher.start(); await switcher.idle();
  expect(close).toHaveBeenCalledOnce(); expect(switcher.label()).toBe("local · unreachable"); switcher.close();
});

it("times out a connection that never supplies a joined snapshot", async () => {
  vi.useFakeTimers(); const options = setup(); const switcher = createInstanceSwitcher(options);
  switcher.start(); await switcher.idle();
  expect(switcher.label()).toBe("local · connecting");
  await vi.advanceTimersByTimeAsync(10_000);
  expect(switcher.label()).toBe("local · unreachable");
  const opened = await options.connect.mock.results[0]!.value;
  expect(opened.close).toHaveBeenCalledOnce();
  switcher.close();
});
