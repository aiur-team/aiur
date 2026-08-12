/**
 * Small Phoenix channel client used by the physical sidecar.
 *
 * The browser emulator and this client deliberately share the server channel
 * contract. The sidecar never talks to internal PubSub topics and never
 * reimplements orchestrator controls: it receives projected state and sends
 * `control` through the authenticated channel.
 */

export interface StreamDeckAgentState {
  readonly identifier: string;
  readonly status?: string;
  readonly title?: string;
  readonly priority?: boolean;
  readonly work_state?: string;
  readonly pause_reason?: string;
  readonly tracker_paused?: boolean;
}

export interface StreamDeckSnapshot {
  readonly version: number;
  readonly fleet: { readonly agents: readonly StreamDeckAgentState[] };
  readonly usage: Readonly<Record<string, unknown>>;
  readonly decisions: Readonly<Record<string, unknown>>;
  readonly grid?: StreamDeckGrid;
}

export interface StreamDeckGrid {
  readonly agents: readonly Record<string, unknown>[];
  readonly total: number;
  readonly windows: number;
  readonly max_column_offset: number;
}

export interface StreamDeckChannelEvents {
  snapshot(snapshot: StreamDeckSnapshot): void;
  fleet(agents: readonly StreamDeckAgentState[]): void;
  grid(grid: StreamDeckGrid): void;
  usage(usage: Readonly<Record<string, unknown>>): void;
  transcript(line: string): void;
  control(payload: Readonly<Record<string, unknown>>): void;
  closed(error: unknown): void;
}

export interface WebSocketLike {
  binaryType: string;
  onopen: (() => void) | null;
  onmessage: ((event: { data: string }) => void) | null;
  onerror: ((error: unknown) => void) | null;
  onclose: (() => void) | null;
  send(data: string): void;
  close(): void;
}

export type WebSocketFactory = (url: string) => WebSocketLike;
export type FetchLike = (input: string, init?: { method?: string; headers?: Record<string, string>; body?: string }) => Promise<{
  ok: boolean;
  json(): Promise<unknown>;
}>;

export interface StreamDeckChannelOptions {
  readonly baseUrl: string;
  readonly username: string;
  readonly password: string;
  readonly fetch: FetchLike;
  readonly websocket: WebSocketFactory;
  readonly events: StreamDeckChannelEvents;
}

export interface StreamDeckChannel {
  focus(identifier: string): void;
  control(identifier: string, action: "pause" | "resume"): void;
  close(): void;
}

const tokenPath = "/api/v1/streamdeck/token";

const channelUrl = (baseUrl: string, token: string): string => {
  const url = new URL(baseUrl);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  url.pathname = "/streamdeck/websocket";
  url.search = new URLSearchParams({ token, vsn: "2.0.0" }).toString();
  return url.toString();
};

const parseFrame = (data: string): unknown[] | null => {
  try {
    const value: unknown = JSON.parse(data);
    return Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
};

/** Connects and joins the authenticated `streamdeck:fleet` channel. */
export const connectStreamDeckChannel = async (options: StreamDeckChannelOptions): Promise<StreamDeckChannel> => {
  const response = await options.fetch(new URL(tokenPath, options.baseUrl).toString(), {
    method: "POST",
    headers: {
      Authorization: `Basic ${Buffer.from(`${options.username}:${options.password}`).toString("base64")}`,
      "Content-Type": "application/json",
    },
    body: "{}",
  });
  if (!response.ok) throw new Error(`Stream Deck token request failed (${response.ok ? "ok" : "unauthorized"})`);
  const tokenPayload = (await response.json()) as { token?: unknown };
  if (typeof tokenPayload.token !== "string" || tokenPayload.token.length === 0) throw new Error("Stream Deck token response was invalid");

  const socket = options.websocket(channelUrl(options.baseUrl, tokenPayload.token));
  socket.binaryType = "arraybuffer";
  let reference = 0;
  let joined = false;
  let stopped = false;
  let heartbeat: ReturnType<typeof setInterval> | null = null;
  let closedNotified = false;
  const send = (event: string, payload: Record<string, unknown>): void => {
    if (!joined) return;
    socket.send(JSON.stringify(["4", String(++reference), "streamdeck:fleet", event, payload]));
  };

  socket.onopen = () => {
    socket.send(JSON.stringify(["4", String(++reference), "streamdeck:fleet", "phx_join", {}]));
    heartbeat = setInterval(() => {
      if (!stopped) socket.send(JSON.stringify(["4", String(++reference), "phoenix", "heartbeat", {}]));
    }, 30_000);
  };
  socket.onmessage = ({ data }) => {
    const frame = parseFrame(data);
    if (frame === null) return;
    const event = frame[3];
    const payload = frame[4];
    if (event === "phx_reply" && (payload as { status?: unknown } | undefined)?.status === "ok") {
      joined = true;
      return;
    }
    if (typeof event !== "string" || typeof payload !== "object" || payload === null) return;
    if (event === "snapshot") {
      const snapshot = payload as StreamDeckSnapshot;
      if (snapshot.grid !== undefined) options.events.grid(snapshot.grid);
      options.events.snapshot(snapshot);
    }
    else if (event === "fleet") {
      const fleet = payload as { agents?: readonly StreamDeckAgentState[]; grid?: StreamDeckGrid };
      options.events.fleet(fleet.agents ?? []);
      if (fleet.grid !== undefined) options.events.grid(fleet.grid);
    }
    else if (event === "usage") options.events.usage(payload as Readonly<Record<string, unknown>>);
    else if (event === "transcript") options.events.transcript(String((payload as { body?: unknown }).body ?? ""));
    else if (event === "control") options.events.control(payload as Readonly<Record<string, unknown>>);
  };
  const notifyClosed = (error: unknown): void => {
    if (heartbeat !== null) clearInterval(heartbeat);
    heartbeat = null;
    if (!stopped && !closedNotified) {
      closedNotified = true;
      options.events.closed(error);
    }
  };
  socket.onerror = (error) => notifyClosed(error);
  socket.onclose = () => notifyClosed(new Error("Stream Deck channel closed"));

  return {
    focus: (identifier) => send("focus", { identifier }),
    control: (identifier, action) => send("control", { identifier, action }),
    close: () => { stopped = true; joined = false; if (heartbeat !== null) clearInterval(heartbeat); heartbeat = null; socket.close(); },
  };
};

export const defaultWebSocket: WebSocketFactory = (url) => new WebSocket(url) as unknown as WebSocketLike;
export const defaultFetch: FetchLike = (input, init) => fetch(input, init) as Promise<Awaited<ReturnType<FetchLike>>>;
