import {
  bucketContract,
  type BucketId,
  KEY_FACE_CONTRACT,
  progressBarColor,
} from "./key-face-contract.js";

export type { BucketId } from "./key-face-contract.js";
export { progressBarColor };
export type Vendor = string;
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
  readonly statusLabel: string;
}

export type Footer = ProgressFooter | QueuedFooter;

export interface AgentKey {
  readonly kind: "agent";
  readonly identifier: string;
  readonly title: string;
  readonly vendor: Vendor;
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
   * Explicitly set to true when no dependency blocks this agent.
   * Absent or false means blocked — fail-closed so a projection bug cannot
   * silently paint every blocked agent as Unblocked.
   */
  readonly dependency_ready?: boolean;
}

const COLUMNS = 4;
const ROWS = 2;
const KEYS_PER_PAGE = COLUMNS * ROWS;

/**
 * Render-ready bucket tokens from the shared data contract. The web emulator
 * reads the same JSON at compile time, while each renderer keeps its own media
 * specific paint routine.
 */
export const BUCKET_STYLES: Readonly<Record<BucketId, Readonly<BucketStyle>>> = Object.freeze(
  Object.fromEntries(
    Object.entries(KEY_FACE_CONTRACT.states).map(([bucket, style]) => [
      bucket,
      Object.freeze({
        accent: style.accent,
        glow: style.glow,
        face: style.face,
        label: style.label,
        ...(style.pulse_seconds === undefined ? {} : { pulseSeconds: style.pulse_seconds }),
      }),
    ]),
  ) as Record<BucketId, Readonly<BucketStyle>>,
);

function clampPercent(percent: number): number {
  return Math.max(0, Math.min(100, percent));
}

function buildFooter(agent: AgentInput): Footer {
  if (agent.bucket === "queued") {
    const footer = KEY_FACE_CONTRACT.footers.queued;
    const unblocked = agent.dependency_ready === footer.ready_when;

    return {
      kind: footer.kind,
      label: bucketContract("queued").label,
      unblocked,
      statusLabel: unblocked ? footer.ready_label : footer.blocked_label,
    };
  }
  const pct = clampPercent(agent.progress_percent);
  return {
    kind: KEY_FACE_CONTRACT.footers.progress.kind,
    barColor: progressBarColor(pct),
    percent: pct,
  };
}

function buildAgentKey(agent: AgentInput): AgentKey {
  const pct = clampPercent(agent.progress_percent);
  const style = BUCKET_STYLES[agent.bucket];
  if (style === undefined) throw new Error(`unhandled Stream Deck key state: ${agent.bucket}`);

  return {
    kind: "agent",
    identifier: agent.identifier,
    title: agent.title ?? "",
    vendor: agent.vendor,
    priority: agent.priority,
    bucket: agent.bucket,
    style,
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
