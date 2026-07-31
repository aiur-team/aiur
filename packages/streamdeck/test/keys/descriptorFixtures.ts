import {
  type AgentKey,
  type BucketId,
  type BucketStyle,
  type Footer,
  type Vendor,
} from "../../src/keys/descriptor.js";

/**
 * Minimal bucket styles for tests. Mirrors the shape #1350 produces; only the
 * fields the key pipeline reads (face/accent/glow/label/pulseSeconds) matter
 * here. #1350 owns the real design tokens.
 */
const STYLES: Readonly<Record<BucketId, BucketStyle>> = {
  running: { accent: "#4fd6c4", glow: "glow-running", face: "#112524", label: "Running" },
  paused: { accent: "#8fbcff", glow: "glow-paused", face: "#142035", label: "Paused" },
  stuck: { accent: "#e3b341", glow: "glow-stuck", face: "#2a2112", label: "Stuck", pulseSeconds: 1.4 },
  alert: { accent: "#ff7b72", glow: "glow-alert", face: "#2d1718", label: "Alert", pulseSeconds: 1.6 },
  queued: { accent: "#c69bff", glow: "glow-queued", face: "#20172f", label: "Queued" },
};

export interface AgentKeyOverrides {
  readonly identifier?: string;
  readonly title?: string | null;
  readonly vendor?: Vendor;
  readonly bucket?: BucketId;
  readonly progressPercent?: number;
  readonly priority?: boolean;
  readonly dependencyReady?: boolean;
}

/** Build an {@link AgentKey} descriptor for tests, standing in for `layoutKeys`. */
export function agentKey(overrides: AgentKeyOverrides = {}): AgentKey {
  const bucket = overrides.bucket ?? "running";
  const identifier = overrides.identifier ?? "1355";
  const percent = overrides.progressPercent ?? 40;
  const footer: Footer =
    bucket === "queued"
      ? { kind: "queued", label: STYLES.queued.label, unblocked: overrides.dependencyReady ?? true }
      : { kind: "progress", barColor: `bar-${percent}`, percent };
  return {
    kind: "agent",
    identifier,
    title: overrides.title ?? "",
    vendor: overrides.vendor ?? "claude",
    ticketNumber: identifier,
    priority: overrides.priority ?? false,
    bucket,
    style: STYLES[bucket],
    progressPercent: percent,
    footer,
  };
}
