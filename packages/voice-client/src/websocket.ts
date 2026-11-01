import { VoiceClientError, type VoiceSocket, type VoiceSocketFactory } from "./types.js";

interface UrlValue {
  readonly searchParams: {
    set(key: string, value: string): void;
  };
  toString(): string;
}

interface UrlConstructor {
  new (value: string): UrlValue;
}

interface WebSocketConstructor {
  new (url: string): VoiceSocket;
}

export interface QueryTokenSocketDependencies {
  readonly Url?: UrlConstructor;
  readonly WebSocket?: WebSocketConstructor;
}

const platformDependencies = (): QueryTokenSocketDependencies => {
  const platform = globalThis as typeof globalThis & {
    readonly URL?: UrlConstructor;
    readonly WebSocket?: WebSocketConstructor;
  };
  return { Url: platform.URL, WebSocket: platform.WebSocket };
};

export const createQueryTokenSocketFactory = (
  dependencies: QueryTokenSocketDependencies = platformDependencies(),
): VoiceSocketFactory => ({ endpoint, token }) => {
  if (!dependencies.Url || !dependencies.WebSocket) {
    throw new VoiceClientError(
      "websocket_unavailable",
      "A standards-compatible URL and WebSocket implementation is required",
    );
  }

  try {
    const url = new dependencies.Url(endpoint);
    url.searchParams.set("token", token);
    return new dependencies.WebSocket(url.toString());
  } catch {
    throw new VoiceClientError("connection_failed", "WebSocket connection could not be created");
  }
};
