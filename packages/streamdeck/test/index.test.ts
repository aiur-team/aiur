import { describe, expect, it } from "vitest";

import {
  StripRenderer,
  buildRegionReports,
  composeStrip,
  summaryModel,
} from "../src/index.js";

describe("Stream Deck package", () => {
  it("re-exports the touch-strip public surface", () => {
    expect(typeof buildRegionReports).toBe("function");
    expect(typeof composeStrip).toBe("function");
    expect(typeof summaryModel).toBe("function");
    expect(typeof StripRenderer).toBe("function");
  });
});
