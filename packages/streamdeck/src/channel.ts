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

/**
 * One row of the flattened transcript, in the daemon's shape.
 *
 * `StreamdeckLogs.flatten/1` emits three of these — an `event_header` followed
 * by that event's `diff` and `message` entries, newest event first. Only
 * `message` carries a body, so collapsing every row to one display string
 * printed the literal "[INFO]" for each diff (whose text is its path and its
 * +/- counts) and discarded the badge that marks where an event begins. The
 * headers are also the jump targets for the log keys, so they have to survive
 * the trip to the renderer.
 */
export type TranscriptRow =
  | {
      readonly kind: "event_header";
      /** Direction badge: EMIT, CONSUME, INFO, AGENT or SYSTEM. */
      readonly badge: string;
      readonly body: string;
      /** ISO instant the event was published; null when the feed omits one. */
      readonly timestamp: string | null;
    }
  | {
      readonly kind: "diff";
      readonly path: string;
      readonly additions: number;
      readonly deletions: number;
      /** First changed line of the hunk; null for a summary-only diff. */
      readonly line: string | null;
    }
  | { readonly kind: "message"; readonly role: string; readonly body: string };

export interface StreamDeckLogs {
  readonly event_keys?: readonly Record<string, unknown>[];
  readonly event_keys_visible?: readonly Record<string, unknown>[];
  readonly transcript?: readonly Record<string, unknown>[];
  readonly events_offset?: number;
  readonly events_max_offset?: number;
  readonly transcript_offset?: number;
  readonly transcript_max_offset?: number;
}

export interface StreamDeckChannelEvents {
  snapshot(snapshot: StreamDeckSnapshot): void;
  fleet(agents: readonly StreamDeckAgentState[]): void;
  grid(grid: StreamDeckGrid): void;
  usage(usage: Readonly<Record<string, unknown>>): void;
  transcript(row: TranscriptRow): void;
  logs(logs: StreamDeckLogs): void;
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
  control(identifier: string, action: "pause" | "resume" | "prioritize" | "deprioritize" | "mic"): void;
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
  const pending: Array<{ event: string; payload: Record<string, unknown> }> = [];
  const send = (event: string, payload: Record<string, unknown>): void => {
    if (!joined) {
      pending.push({ event, payload });
      return;
    }
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
      for (const command of pending.splice(0)) send(command.event, command.payload);
      return;
    }
    if (event === "phx_close" || event === "phx_error") {
      notifyClosed(new Error(`Stream Deck channel ${event}`));
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
    else if (event === "transcript") {
      // The live per-message push is the same shape as a flattened `message`
      // row, so it enters the transcript as one rather than as a bare string:
      // the strip renders the speaker, and the row cannot be mistaken for the
      // event header the log keys jump to.
      const message = payload as { role?: unknown; body?: unknown };
      options.events.transcript({
        kind: "message",
        role: typeof message.role === "string" ? message.role : "agent",
        body: typeof message.body === "string" ? message.body : "",
      });
    }
    else if (event === "logs") options.events.logs(payload as StreamDeckLogs);
    else if (event === "control") options.events.control(payload as Readonly<Record<string, unknown>>);
  };
  const notifyClosed = (error: unknown): void => {
    if (heartbeat !== null) clearInterval(heartbeat);
    heartbeat = null;
    if (!stopped && !closedNotified) {
      closedNotified = true;
      socket.close();
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
