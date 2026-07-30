export type BucketId = "running" | "paused" | "stuck" | "alert" | "queued";
export type Vendor = "claude" | "codex";
export interface BucketStyle {
  readonly accent: string;
  readonly glow: string;
  readonly face: string;
  readonly label: string;
  readonly pulseSeconds?: number;
}

export interface ProgressFooter {
  readonly kind: "progress";
  readonly barColor: string;
  readonly percent: number;
}

export interface QueuedFooter {
  readonly kind: "queued";
  readonly label: string;
  readonly unblocked: boolean;
}

export type Footer = ProgressFooter | QueuedFooter;

export interface AgentKey {
  readonly kind: "agent";
  readonly identifier: string;
  readonly title: string;
  readonly vendor: Vendor;
  readonly ticketNumber: string;
  readonly priority: boolean;
  readonly bucket: BucketId;
  readonly style: BucketStyle;
  readonly progressPercent: number;
  readonly footer: Footer;
}

export interface EmptyKey {
  readonly kind: "empty";
}

export type KeyDescriptor = AgentKey | EmptyKey;

export interface AgentInput {
  readonly identifier: string;
  readonly title?: string | null;
  readonly vendor: Vendor;
  readonly bucket: BucketId;
  readonly progress_percent: number;
  readonly priority: boolean;
  /**
   * When absent, treated as true (no known dependency blocks this agent).
   * Explicitly set to false for agents waiting on a dependency.
   */
  readonly dependency_ready?: boolean;
}

const COLUMNS = 4;
const ROWS = 2;
const KEYS_PER_PAGE = COLUMNS * ROWS;

export const BUCKET_STYLES: Readonly<Record<BucketId, Readonly<BucketStyle>>> = Object.freeze({
  running: Object.freeze({
    accent: "#4fd6c4",
    glow: "rgba(79,214,196,0.35)",
    face: "#112524",
    label: "Running",
  }),
  paused: Object.freeze({
    accent: "#8fbcff",
    glow: "rgba(143,188,255,0.32)",
    face: "#142035",
    label: "Paused",
  }),
  stuck: Object.freeze({
    accent: "#e3b341",
    glow: "rgba(227,179,65,0.38)",
    face: "#2a2112",
    label: "Stuck",
    pulseSeconds: 1.4,
  }),
  alert: Object.freeze({
    accent: "#ff7b72",
    glow: "rgba(255,123,114,0.4)",
    face: "#2d1718",
    label: "Alert",
    pulseSeconds: 1.6,
  }),
  queued: Object.freeze({
    accent: "#c69bff",
    glow: "rgba(198,155,255,0.32)",
    face: "#20172f",
    label: "Queued",
  }),
});

export function progressBarColor(percent: number): string {
  const p = Math.max(0, Math.min(100, percent));
  const hue = (p / 100) * 125;
  return `hsl(${hue} 72% 50%)`;
}

function clampPercent(percent: number): number {
  return Math.max(0, Math.min(100, percent));
}

function buildFooter(agent: AgentInput): Footer {
  if (agent.bucket === "queued") {
    return {
      kind: "queued",
      label: BUCKET_STYLES.queued.label,
      unblocked: agent.dependency_ready ?? true,
    };
  }
  const pct = clampPercent(agent.progress_percent);
  return {
    kind: "progress",
    barColor: progressBarColor(pct),
    percent: pct,
  };
}

function buildAgentKey(agent: AgentInput): AgentKey {
  const pct = clampPercent(agent.progress_percent);
  return {
    kind: "agent",
    identifier: agent.identifier,
    title: agent.title ?? "",
    vendor: agent.vendor,
    ticketNumber: agent.identifier,
    priority: agent.priority,
    bucket: agent.bucket,
    style: BUCKET_STYLES[agent.bucket],
    progressPercent: pct,
    footer: buildFooter(agent),
  };
}

const EMPTY_KEY: EmptyKey = Object.freeze({ kind: "empty" });

/**
 * Maps a sorted agent list and a column offset to exactly 8 key descriptors.
 *
 * Layout is column-major: key i occupies col = i % 4, row = i < 4 ? 0 : 1,
 * and resolves to agents[(columnOffset + col) * 2 + row]. Missing indices
 * produce an explicit empty descriptor rather than a partial agent.
 *
 * The input order is preserved verbatim — do not re-sort client-side.
 */
export function layoutKeys(
  agents: readonly AgentInput[],
  columnOffset: number,
): KeyDescriptor[] {
  return Array.from({ length: KEYS_PER_PAGE }, (_, i) => {
    const col = i % COLUMNS;
    const row = i < COLUMNS ? 0 : 1;
    const agent = agents[(columnOffset + col) * ROWS + row];
    return agent !== undefined ? buildAgentKey(agent) : EMPTY_KEY;
  });
}
