import {
  VoiceClientError,
  type VoiceConnectionEvents,
  type VoiceConnectionOptions,
  type VoiceConnectionState,
  type VoiceSocket,
  type VoiceSocketFactory,
  type VoiceWireConnection,
  type WireCodec,
} from "./types.js";

const CLIENT_CLOSE = { code: 1000, reason: "client closed" } as const;
const PROTOCOL_CLOSE = { code: 1002, reason: "protocol error" } as const;
const TRANSPORT_CLOSE = { code: 1011, reason: "transport error" } as const;

export const connectVoiceWire = <OutboundFrame, InboundFrame>(
  options: VoiceConnectionOptions<OutboundFrame, InboundFrame>,
): VoiceWireConnection<OutboundFrame> => {
  validateConnectionOptions(options.endpoint, options.token);
  const socket = createSocket(options.socketFactory, options.endpoint, options.token);
  return new ConnectionRuntime(socket, options.codec, options.events ?? {});
};

const validateConnectionOptions = (endpoint: string, token: string): void => {
  if (endpoint.trim().length === 0 || token.trim().length === 0) {
    throw new VoiceClientError("connection_failed", "A voice endpoint and host-issued token are required");
  }
};

const createSocket = (factory: VoiceSocketFactory, endpoint: string, token: string): VoiceSocket => {
  try {
    return factory({ endpoint, token });
  } catch {
    throw new VoiceClientError("connection_failed", "Voice connection could not be created");
  }
};

class ConnectionRuntime<OutboundFrame, InboundFrame> implements VoiceWireConnection<OutboundFrame> {
  #state: VoiceConnectionState = "connecting";
  #queued: string[] = [];

  constructor(
    private readonly socket: VoiceSocket,
    private readonly codec: WireCodec<OutboundFrame, InboundFrame>,
    private readonly events: VoiceConnectionEvents<InboundFrame>,
  ) {
    socket.onopen = () => this.open();
    socket.onmessage = ({ data }) => this.receive(data);
    socket.onerror = () => this.fail("transport_error", TRANSPORT_CLOSE);
    socket.onclose = () => this.closed();
    events.stateChanged?.("connecting");
  }

  get state(): VoiceConnectionState {
    return this.#state;
  }

  send(frame: OutboundFrame): void {
    if (this.#state !== "connecting" && this.#state !== "open") {
      throw new VoiceClientError("connection_not_open", "Voice connection is not open");
    }

    const encoded = this.encode(frame);
    if (this.#state === "connecting") this.#queued.push(encoded);
    else this.sendEncoded(encoded);
  }

  close(): void {
    if (this.#state === "closing" || this.#state === "closed" || this.#state === "failed") return;
    this.#queued = [];
    this.setState("closing");
    this.closeSocket(CLIENT_CLOSE);
  }

  private open(): void {
    if (this.#state !== "connecting") return;
    this.setState("open");
    const pending = this.#queued;
    this.#queued = [];

    for (const encoded of pending) {
      if (!this.isOpen()) break;
      this.sendEncoded(encoded);
    }
  }

  private isOpen(): boolean {
    return this.#state === "open";
  }

  private receive(data: unknown): void {
    if (this.#state !== "open") {
      this.fail("protocol_error", PROTOCOL_CLOSE);
      return;
    }

    try {
      this.events.frame?.(this.codec.decodeInbound(data));
    } catch {
      this.fail("protocol_error", PROTOCOL_CLOSE);
    }
  }

  private encode(frame: OutboundFrame): string {
    try {
      return this.codec.encodeOutbound(frame);
    } catch {
      throw new VoiceClientError("protocol_error", "Outbound voice frame failed contract validation");
    }
  }

  private sendEncoded(encoded: string): void {
    try {
      this.socket.send(encoded);
    } catch {
      this.fail("transport_error", TRANSPORT_CLOSE);
    }
  }

  private fail(
    code: "protocol_error" | "transport_error",
    close: { readonly code: number; readonly reason: string },
  ): void {
    if (this.#state === "closing" || this.#state === "failed" || this.#state === "closed") return;
    this.#queued = [];
    this.setState("failed");
    this.closeSocket(close);
    const message = code === "protocol_error" ? "Voice wire protocol validation failed" : "Voice transport failed";
    this.events.error?.(new VoiceClientError(code, message));
  }

  private closed(): void {
    if (this.#state === "closing" || this.#state === "failed") {
      this.setState("closed");
      return;
    }
    this.fail("transport_error", TRANSPORT_CLOSE);
  }

  private closeSocket(close: { readonly code: number; readonly reason: string }): void {
    try {
      this.socket.close(close.code, close.reason);
    } catch {
      // State and callbacks remain deterministic even if a transport is already gone.
    }
  }

  private setState(next: VoiceConnectionState): void {
    if (next === this.#state) return;
    this.#state = next;
    this.events.stateChanged?.(next);
  }
}
