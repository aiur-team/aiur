// Future regression guards for retained legacy drawing helpers, pending SD-105.
// These do not establish browser/device parity or cover the SVG migration.
import { expect, it } from "vitest";
import { bucketContract, type BucketId } from "../src/legacy-style.js";
import { layoutKeys } from "../src/keys.js";
import { badgeColor } from "../src/logs.js";

it("rejects unknown states at both legacy drawing boundaries", () => {
  expect(() => bucketContract("invalid" as BucketId)).toThrow("unhandled Stream Deck key state");
  expect(() => layoutKeys([{ identifier: "1", title: "Test", vendor: "codex", bucket: "invalid" as BucketId, progress_percent: null, priority: false }], 0)).toThrow();
});

it("keeps direction inks readable in retained legacy logs", () => {
  expect(badgeColor("EMIT")).toBe("#9fd0ff");
  expect(badgeColor("CONSUME")).toBe("#88e0a6");
  expect(badgeColor("AGENT")).toBe("#9fd0ff");
  expect(badgeColor("SYSTEM")).toBe("#ffcf87");
  expect(badgeColor("INFO")).toBe("#c2c6cf");
});
