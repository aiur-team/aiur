import { describe, expect, it } from "vitest";

import {
  BUCKET_STYLES,
  layoutKeys,
  progressBarColor,
  type AgentInput,
  type AgentKey,
  type EmptyKey,
  type QueuedFooter,
  type ProgressFooter,
} from "../src/keys.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function agent(identifier: string, overrides: Partial<AgentInput> = {}): AgentInput {
  return {
    identifier,
    title: `Ticket ${identifier}`,
    vendor: "codex",
    bucket: "running",
    progress_percent: 50,
    priority: false,
    ...overrides,
  };
}

function agentKey(key: ReturnType<typeof layoutKeys>[number]): AgentKey {
  if (key.kind !== "agent") throw new Error(`Expected agent key, got ${key.kind}`);
  return key;
}

function emptyKey(key: ReturnType<typeof layoutKeys>[number]): EmptyKey {
  if (key.kind !== "empty") throw new Error(`Expected empty key, got ${key.kind}`);
  return key;
}

// ---------------------------------------------------------------------------
// Core layout contract
// ---------------------------------------------------------------------------

describe("layoutKeys", () => {
  it("always returns exactly 8 descriptors", () => {
    expect(layoutKeys([], 0)).toHaveLength(8);
    expect(layoutKeys([agent("1")], 0)).toHaveLength(8);
    expect(layoutKeys(Array.from({ length: 8 }, (_, i) => agent(String(i))), 0)).toHaveLength(8);
    expect(layoutKeys(Array.from({ length: 20 }, (_, i) => agent(String(i))), 0)).toHaveLength(8);
  });

  it("returns all empty descriptors for an empty fleet", () => {
    const keys = layoutKeys([], 0);
    for (const key of keys) {
      expect(key.kind).toBe("empty");
    }
  });

  it("uses column-major layout, not row-major", () => {
    // 8 agents labelled by their natural index 0..7.
    // Column-major: key i → col = i%4, row = i<4 ? 0 : 1
    //   → agents[(0 + col)*2 + row]
    //
    // Key positions with columnOffset=0:
    //   key 0: col=0, row=0 → agents[0]
    //   key 1: col=1, row=0 → agents[2]
    //   key 2: col=2, row=0 → agents[4]
    //   key 3: col=3, row=0 → agents[6]
    //   key 4: col=0, row=1 → agents[1]
    //   key 5: col=1, row=1 → agents[3]
    //   key 6: col=2, row=1 → agents[5]
    //   key 7: col=3, row=1 → agents[7]
    //
    // Under naive row-major (agents[i]) the order would be 0,1,2,3,4,5,6,7.
    // Column-major produces 0,2,4,6,1,3,5,7 — these differ, so the test would
    // fail under a naïve agents[columnOffset + i] implementation.
    const agents = Array.from({ length: 8 }, (_, i) => agent(String(i)));
    const keys = layoutKeys(agents, 0);
    const ids = keys.map((k) => agentKey(k).identifier);
    expect(ids).toEqual(["0", "2", "4", "6", "1", "3", "5", "7"]);

    // Row-major order (the wrong answer) must differ
    const rowMajorOrder = agents.map((a) => a.identifier);
    expect(ids).not.toEqual(rowMajorOrder);
  });

  it("applies the column offset for paging", () => {
    // With columnOffset=1, each column address is shifted by 1:
    //   key 0: col=0 → agents[(1+0)*2+0] = agents[2]
    //   key 1: col=1 → agents[(1+1)*2+0] = agents[4]
    //   key 4: col=0 → agents[(1+0)*2+1] = agents[3]
    const agents = Array.from({ length: 12 }, (_, i) => agent(String(i)));
    const keys = layoutKeys(agents, 1);
    expect(agentKey(keys[0]!).identifier).toBe("2");
    expect(agentKey(keys[1]!).identifier).toBe("4");
    expect(agentKey(keys[4]!).identifier).toBe("3");
  });

  it("preserves the input order without re-sorting", () => {
    // Deliberately out-of-bucket order to confirm no client-side sort
    const agents = [
      agent("queued", { bucket: "queued" }),
      agent("running", { bucket: "running" }),
    ];
    const keys = layoutKeys(agents, 0);
    // col=0, row=0 → agents[0] = queued
    expect(agentKey(keys[0]!).bucket).toBe("queued");
    // col=0, row=1 → agents[1] = running
    expect(agentKey(keys[4]!).bucket).toBe("running");
  });
});

// ---------------------------------------------------------------------------
// Empty slots
// ---------------------------------------------------------------------------

describe("empty slots", () => {
  it("produces explicit empty descriptors for missing indices", () => {
    const keys = layoutKeys([agent("0")], 0);
    // key 0: agents[(0+0)*2+0] = agents[0] → agent
    expect(keys[0]!.kind).toBe("agent");
    // key 1: agents[(0+1)*2+0] = agents[2] → undefined → empty
    expect(keys[1]!.kind).toBe("empty");
    // key 4: agents[(0+0)*2+1] = agents[1] → undefined → empty
    expect(keys[4]!.kind).toBe("empty");
  });

  it("never partially populates an empty descriptor", () => {
    const keys = layoutKeys([], 0);
    for (const key of keys) {
      emptyKey(key); // throws if not empty
      expect(Object.keys(key)).toEqual(["kind"]);
    }
  });
});

// ---------------------------------------------------------------------------
// Footer variants
// ---------------------------------------------------------------------------

describe("footer variants", () => {
  it("queued agents use the queued footer with a status label", () => {
    const keys = layoutKeys([agent("q", { bucket: "queued", dependency_ready: true })], 0);
    const footer = agentKey(keys[0]!).footer as QueuedFooter;
    expect(footer.kind).toBe("queued");
    expect(footer.label).toBe("Queued");
  });

  it("queued footer reports unblocked=true when dependency_ready is true", () => {
    const keys = layoutKeys([agent("q", { bucket: "queued", dependency_ready: true })], 0);
    expect((agentKey(keys[0]!).footer as QueuedFooter).unblocked).toBe(true);
  });

  it("queued footer reports unblocked=false when dependency_ready is false", () => {
    const keys = layoutKeys([agent("q", { bucket: "queued", dependency_ready: false })], 0);
    expect((agentKey(keys[0]!).footer as QueuedFooter).unblocked).toBe(false);
  });

  it("queued footer defaults to unblocked=true when dependency_ready is absent", () => {
    const a: AgentInput = { identifier: "q", vendor: "codex", bucket: "queued", progress_percent: 0, priority: false };
    const keys = layoutKeys([a], 0);
    expect((agentKey(keys[0]!).footer as QueuedFooter).unblocked).toBe(true);
  });

  it("non-queued agents use the progress footer with a status dot and bar", () => {
    for (const bucket of ["running", "paused", "stuck", "alert"] as const) {
      const keys = layoutKeys([agent("x", { bucket, progress_percent: 50 })], 0);
      const footer = agentKey(keys[0]!).footer as ProgressFooter;
      expect(footer.kind).toBe("progress");
      expect(footer.percent).toBe(50);
      expect(footer.barColor).toMatch(/^hsl\(/);
    }
  });
});

// ---------------------------------------------------------------------------
// Progress bar hue mapping
// ---------------------------------------------------------------------------

describe("progress bar colour", () => {
  it("maps 0% to red (hue 0)", () => {
    expect(progressBarColor(0)).toBe("hsl(0 72% 50%)");
  });

  it("maps 50% to ~yellow-green (hue 62.5)", () => {
    expect(progressBarColor(50)).toBe("hsl(62.5 72% 50%)");
  });

  it("maps 100% to green (hue 125)", () => {
    expect(progressBarColor(100)).toBe("hsl(125 72% 50%)");
  });

  it("clamps when called directly with out-of-range values", () => {
    expect(progressBarColor(-10)).toBe("hsl(0 72% 50%)");
    expect(progressBarColor(150)).toBe("hsl(125 72% 50%)");
  });

  it("clamps progress_percent below 0 to 0", () => {
    const keys = layoutKeys([agent("x", { progress_percent: -10 })], 0);
    const footer = agentKey(keys[0]!).footer as ProgressFooter;
    expect(footer.percent).toBe(0);
    expect(footer.barColor).toBe("hsl(0 72% 50%)");
  });

  it("clamps progress_percent above 100 to 100", () => {
    const keys = layoutKeys([agent("x", { progress_percent: 150 })], 0);
    const footer = agentKey(keys[0]!).footer as ProgressFooter;
    expect(footer.percent).toBe(100);
    expect(footer.barColor).toBe("hsl(125 72% 50%)");
  });
});

// ---------------------------------------------------------------------------
// Bucket design tokens
// ---------------------------------------------------------------------------

describe("bucket styles", () => {
  it("running carries exact design tokens", () => {
    expect(BUCKET_STYLES.running).toEqual({
      accent: "#4fd6c4",
      glow: "rgba(79,214,196,0.35)",
      face: "#112524",
      label: "Running",
    });
    expect(BUCKET_STYLES.running.pulseSeconds).toBeUndefined();
  });

  it("paused carries exact design tokens", () => {
    expect(BUCKET_STYLES.paused).toEqual({
      accent: "#8fbcff",
      glow: "rgba(143,188,255,0.32)",
      face: "#142035",
      label: "Paused",
    });
    expect(BUCKET_STYLES.paused.pulseSeconds).toBeUndefined();
  });

  it("stuck carries exact design tokens with 1.4s pulse", () => {
    expect(BUCKET_STYLES.stuck).toEqual({
      accent: "#e3b341",
      glow: "rgba(227,179,65,0.38)",
      face: "#2a2112",
      label: "Stuck",
      pulseSeconds: 1.4,
    });
  });

  it("alert carries exact design tokens with 1.6s pulse", () => {
    expect(BUCKET_STYLES.alert).toEqual({
      accent: "#ff7b72",
      glow: "rgba(255,123,114,0.4)",
      face: "#2d1718",
      label: "Alert",
      pulseSeconds: 1.6,
    });
  });

  it("queued carries exact design tokens", () => {
    expect(BUCKET_STYLES.queued).toEqual({
      accent: "#c69bff",
      glow: "rgba(198,155,255,0.32)",
      face: "#20172f",
      label: "Queued",
    });
    expect(BUCKET_STYLES.queued.pulseSeconds).toBeUndefined();
  });

  it("BUCKET_STYLES is deeply frozen — runtime mutation throws in strict mode", () => {
    expect(Object.isFrozen(BUCKET_STYLES)).toBe(true);
    expect(Object.isFrozen(BUCKET_STYLES.running)).toBe(true);
    expect(Object.isFrozen(BUCKET_STYLES.alert)).toBe(true);
  });

  it("agent key carries the correct style for its bucket", () => {
    for (const bucket of ["running", "paused", "stuck", "alert", "queued"] as const) {
      const extra = bucket === "queued" ? { dependency_ready: true as const } : {};
      const keys = layoutKeys([agent("x", { bucket, ...extra })], 0);
      expect(agentKey(keys[0]!).style).toBe(BUCKET_STYLES[bucket]);
    }
  });
});

// ---------------------------------------------------------------------------
// Agent key fields
// ---------------------------------------------------------------------------

describe("agent key fields", () => {
  it("populates identifier, title, vendor, ticketNumber, and priority", () => {
    const keys = layoutKeys(
      [agent("1350", { title: "My ticket", vendor: "claude", priority: true })],
      0,
    );
    const key = agentKey(keys[0]!);
    expect(key.identifier).toBe("1350");
    expect(key.title).toBe("My ticket");
    expect(key.vendor).toBe("claude");
    expect(key.ticketNumber).toBe("1350");
    expect(key.priority).toBe(true);
  });

  it("defaults title to empty string when absent", () => {
    const a: AgentInput = { identifier: "x", vendor: "codex", bucket: "running", progress_percent: 0, priority: false };
    const keys = layoutKeys([a], 0);
    expect(agentKey(keys[0]!).title).toBe("");
  });
});
