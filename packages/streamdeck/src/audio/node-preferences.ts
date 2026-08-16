/**
 * The file-backed implementation of the microphone `PreferenceStore`.
 *
 * `preferences.ts` decides *what* a remembered microphone means; this decides
 * only *where* it is kept. Like `node-system.ts` it is an adapter with no
 * decisions of its own beyond degradation, and the filesystem reaches it
 * through an injected three-function port — so the rest of `src/audio/` still
 * imports no Node built-in and still lifts into its own package unchanged.
 *
 * The stored document is `{"deviceId": "<id>"}`. JSON rather than a bare line
 * so a later preference can be added without a migration.
 */

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { PreferenceStore } from "./preferences.js";

export interface FileSystemPort {
  readFileSync(path: string): string;
  writeFileSync(path: string, data: string): void;
  mkdirSync(path: string): void;
}

const nodeFileSystem: FileSystemPort = {
  readFileSync: (path) => readFileSync(path, "utf8"),
  writeFileSync: (path, data) => {
    writeFileSync(path, data, "utf8");
  },
  mkdirSync: (path) => {
    mkdirSync(path, { recursive: true });
  },
};

export function createFilePreferenceStore(path: string, fs: FileSystemPort = nodeFileSystem): PreferenceStore {
  return {
    read(): string | null {
      // Every failure degrades to "no choice remembered" rather than throwing:
      // a missing file is the first run, and a truncated or hand-edited file
      // must not be the reason the sidecar fails to start. Forgetting which
      // microphone was picked costs one click; not starting costs the deck.
      let raw: string;
      try {
        raw = fs.readFileSync(path);
      } catch {
        return null;
      }

      let parsed: unknown;
      try {
        parsed = JSON.parse(raw);
      } catch {
        return null;
      }

      if (typeof parsed !== "object" || parsed === null) return null;
      const deviceId = (parsed as { deviceId?: unknown }).deviceId;
      if (typeof deviceId !== "string" || deviceId === "") return null;
      return deviceId;
    },

    write(value: string): void {
      // The directory is created first: the settings path lives under a config
      // directory that does not exist on a fresh machine, and the first write
      // is exactly when it is missing.
      fs.mkdirSync(dirname(path));
      fs.writeFileSync(path, `${JSON.stringify({ deviceId: value })}\n`);
    },
  };
}
