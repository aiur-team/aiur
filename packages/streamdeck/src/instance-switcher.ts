import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { resolveInstance, type InstanceTarget } from "./instances.js";

import { InstanceAuthError } from "./channel-types.js";
export type InstanceState = "connecting" | "connected" | "auth failed" | "unreachable";
interface Connection { close(): void; focus(identifier: string): void }
interface Lifecycle { current(): boolean; connected(): void; closed(): void }

export const createInstanceSwitcher = <T extends Connection>(options: {
  targets: InstanceTarget[];
  preferencePath: string;
  connect(target: ReturnType<typeof resolveInstance>, lifecycle: Lifecycle): Promise<T>;
  channel(channel: T | null): void;
  disconnect(): void;
  resetInstance(): void;
  focusedIdentifier?(): string | null;
  changed(): void;
}) => {
  let chosen = options.targets[0]!;
  try {
    const saved: unknown = JSON.parse(readFileSync(options.preferencePath, "utf8"));
    chosen = options.targets.find((target) => target.name === saved) ?? chosen;
  } catch { /* A missing/corrupt preference leaves local selected. */ }
  let highlighted = options.targets.indexOf(chosen);
  let state: InstanceState = "unreachable";
  let message = "";
  let generation = 0;
  let channel: T | null = null;
  let pending = Promise.resolve();
  let timer: ReturnType<typeof setTimeout> | undefined;
  let attempt = 0;
  const connect = (target: InstanceTarget): void => {
    let resolved: ReturnType<typeof resolveInstance>;
    try { resolved = resolveInstance(target); }
    catch (error) { message = (error as Error).message; options.changed(); return; }
    const id = ++generation;
    clearTimeout(timer);
    channel?.close();
    channel = null;
    options.channel(null);
    options.disconnect();
    if (chosen !== target) options.resetInstance();
    chosen = target;
    state = "connecting";
    message = "";
    options.changed();
    let disconnected = false;
    const current = (): boolean => id === generation && !disconnected;
    const failed = (error?: unknown): void => {
      if (!current()) return;
      disconnected = true;
      clearTimeout(timer);
      channel?.close();
      channel = null;
      options.channel(null);
      options.disconnect();
      state = error instanceof InstanceAuthError ? "auth failed" : "unreachable";
      options.changed();
      if (state !== "auth failed") timer = setTimeout(() => connect(chosen), Math.min(30_000, 500 * 2 ** attempt++)).unref();
    };
    // Serialize token requests as well as sockets: a superseded request can
    // finish, but must close before the next target's socket is constructed.
    pending = pending.then(async () => {
      if (!current()) return;
      timer = setTimeout(() => failed(), 10_000).unref();
      try {
        const opened = await options.connect(resolved, {
          current,
          connected: () => { if (current()) { clearTimeout(timer); state = "connected"; attempt = 0; options.changed(); } },
          closed: () => failed(),
        });
        if (!current()) { opened.close(); return; }
        channel = opened;
        options.channel(opened);
        const focused = options.focusedIdentifier?.();
        if (focused != null) opened.focus(focused);
      } catch (error) { failed(error); }
    });
  };
  return {
    start: () => connect(chosen),
    turn: (ticks: number) => {
      highlighted = ((highlighted + ticks) % options.targets.length + options.targets.length) % options.targets.length;
      message = "";
      options.changed();
    },
    press: () => {
      const target = options.targets[highlighted]!;
      connect(target);
      if (chosen !== target) return;
      try {
        mkdirSync(path.dirname(options.preferencePath), { recursive: true });
        writeFileSync(options.preferencePath, JSON.stringify(target.name), { mode: 0o600 });
      } catch { message = "Cannot save instance preference"; options.changed(); }
    },
    label: () => `${chosen.name} · ${state}${message ? ` | ${message}` : ""}${options.targets[highlighted] !== chosen ? ` | ◀ ${options.targets[highlighted]!.name} ▶ · press to connect` : ""}`,
    idle: () => pending,
    close: () => { generation++; clearTimeout(timer); channel?.close(); options.channel(null); options.disconnect(); },
  };
};
