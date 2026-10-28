import type { StreamDeckChannelEvents } from "./channel-types.js";

/** Late frames from a previous daemon must never reach the current surface. */
export const guardChannelEvents = (events: StreamDeckChannelEvents, current: () => boolean): StreamDeckChannelEvents =>
  new Proxy(events, {
    get: (target, key: keyof StreamDeckChannelEvents) => (...args: never[]) => {
      if (current()) (target[key] as (...args: never[]) => void)(...args);
    },
  });
