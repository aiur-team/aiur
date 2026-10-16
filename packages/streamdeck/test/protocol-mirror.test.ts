import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// The daemon owns the visual contract (src/priv/streamdeck); src/ here holds
// byte-identical mirrors so the sidecar build (`rootDir: src`) is untouched.
describe("key-face contract mirrors", () => {
  for (const name of ["key-face-contract.json", "key-face-parity-vectors.json"]) {
    it(`${name} matches the daemon's canonical copy`, () => {
      const canonical = readFileSync(new URL(`../../../src/priv/streamdeck/${name}`, import.meta.url));
      const mirror = readFileSync(new URL(`../src/${name}`, import.meta.url));
      expect(
        mirror.equals(canonical),
        `copy src/priv/streamdeck/${name} to packages/streamdeck/src/${name}`,
      ).toBe(true);
    });
  }
});
