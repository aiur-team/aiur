import { describe, expect, it, vi } from "vitest";
import { createDeckAlerts, deckAlertKind, deckChime } from "../src/deck-alerts.js";

describe("deck alert preferences", () => {
  it("applies flash and chime independently and ignores disabled or unknown alerts", () => {
    const flash = vi.fn();
    const chime = vi.fn();
    const alert = createDeckAlerts({
      choices: () => ({ command: { flash: true, chime: true }, ci_red: { flash: true, chime: false }, error: { flash: false, chime: true } }),
      flash, chime,
    });
    alert({ name: "command" });
    expect(flash).toHaveBeenCalledTimes(1);
    expect(chime).toHaveBeenCalledTimes(1);
    alert({ name: "ci_red" });
    expect(flash).toHaveBeenCalledTimes(2);
    expect(chime).toHaveBeenCalledTimes(1);
    alert({ severity: "critical" });
    expect(flash).toHaveBeenCalledTimes(2);
    expect(chime).toHaveBeenCalledTimes(2);
    alert({ name: "usage_limited" });
    alert({ name: "other" });
    expect(flash).toHaveBeenCalledTimes(2);
    expect(chime).toHaveBeenCalledTimes(2);
  });

  it("recognizes delivered names and leaves unrelated events alone", () => {
    expect(deckAlertKind({ name: "ticket.42.agent.decision.requested" })).toBe("command");
    expect(deckAlertKind({ name: "ticket.42.ci.failed" })).toBe("ci_red");
    expect(deckAlertKind({ name: "ticket.42.usage_limited" })).toBe("usage_limited");
    expect(deckAlertKind({ name: "ticket.42.command" })).toBe("command");
    expect(deckAlertKind({ name: "ticket.42.agent.usage_limit_exhausted", severity: "warning" })).toBe("usage_limited");
    expect(deckAlertKind({ name: "error" })).toBe("error");
    expect(deckAlertKind({})).toBeNull();
  });

  it("produces bounded non-silent PCM for the selected speaker", () => {
    const bytes = deckChime();
    expect(bytes.length).toBe(8820);
    const view = new DataView(bytes.buffer);
    const samples = Array.from({ length: bytes.length / 2 }, (_, i) => view.getInt16(i * 2, true));
    expect(Math.max(...samples)).toBeGreaterThan(4000);
    expect(Math.min(...samples)).toBeLessThan(-4000);
    expect(Math.max(...samples.map(Math.abs))).toBeLessThanOrEqual(5000);
    expect(samples[0]).toBe(0);
  });
});
