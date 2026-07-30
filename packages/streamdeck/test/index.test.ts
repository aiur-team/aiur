import { describe, expect, it } from "vitest";

import { placeholder } from "../src/index.js";

describe("Stream Deck package", () => {
  it("has a working package scaffold", () => {
    expect(placeholder).toBe("streamdeck");
  });
});
