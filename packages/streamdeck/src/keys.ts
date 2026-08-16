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
  /** `null` when no reading exists. Never a substituted zero. */
  readonly percent: number | null;
  readonly freshness: ProgressFreshness;
}

/**
 * How much to trust the progress reading behind a bar.
 *
 * `unknown` is a real state, not a synonym for zero. The daemon used to
 * substitute `0` whenever a reading went stale, so a ticket sitting at 70%
 * dropped to an empty bar about a minute after each emission and jumped back on
 * the next one — the flicker the operator reported. Zero and "no reading" are
 * different facts and must not paint the same.
 */
export type ProgressFreshness = "fresh" | "stale" | "unknown";

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
  readonly progressPercent: number | null;
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
  /** `null` or absent when the daemon has no reading. Not the same as `0`. */
  readonly progress_percent: number | null;
  readonly progress_freshness?: string | null;
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

/** Shared physical key -> column-major agent index mapping for render and input. */
export const agentIndexForKey = (columnOffset: number, key: number): number =>
  (columnOffset + (key % COLUMNS)) * ROWS + (key < COLUMNS ? 0 : 1);

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

/**
 * Clamps a reading to 0-100, or returns `null` when there is nothing to clamp.
 *
 * `NaN` is treated as absent rather than clamped to 0: it arrives from a
 * malformed payload, and a malformed payload is exactly a case where the deck
 * does not know the progress. Clamping it would assert 0% instead.
 */
function clampPercent(percent: number | null | undefined): number | null {
  if (typeof percent !== "number" || !Number.isFinite(percent)) return null;
  return Math.max(0, Math.min(100, percent));
}

/**
 * Freshness the daemon reported, falling back to what the percent itself
 * implies. Fail-closed on an unrecognised value: an unknown freshness label is
 * not evidence that a reading is current.
 */
function readFreshness(agent: AgentInput, percent: number | null): ProgressFreshness {
  const reported = agent.progress_freshness;
  // A daemon that says "unknown" is believed even when a number rides along.
  // The two are supposed to arrive paired, and honouring the number would draw
  // a confident bar under a payload that just said it has no reading.
  if (percent === null || reported === "unknown") return "unknown";
  if (reported === "fresh" || reported === "stale") return reported;
  // Absent and unrecognised are different. A daemon older than the sidecar
  // annotates nothing, and a bare percent is still a reading somebody took —
  // that reads as fresh. A daemon *newer* than the sidecar sending a label this
  // build has never heard of is not evidence the reading is current, so it
  // reads as stale: the bar keeps its value and stops claiming to be now.
  return reported === undefined || reported === null ? "fresh" : "stale";
}

/** Neutral track tint for a bar with no reading behind it. */
const UNKNOWN_BAR_COLOR = "rgba(255,255,255,0.22)";

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
  const clamped = clampPercent(agent.progress_percent);
  const freshness = readFreshness(agent, clamped);
  // Unknown means unknown all the way down: the percent is dropped as well as
  // the colour, so nothing downstream can key a confident branch off a number
  // the payload disowned. Painting an unknown bar green would state a
  // measurement; it renders as a dashed track instead.
  const pct = freshness === "unknown" ? null : clamped;
  return {
    kind: KEY_FACE_CONTRACT.footers.progress.kind,
    barColor: pct === null ? UNKNOWN_BAR_COLOR : progressBarColor(pct),
    percent: pct,
    freshness,
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
  agents: readonly (AgentInput | undefined)[],
  columnOffset: number,
): KeyDescriptor[] {
  return Array.from({ length: KEYS_PER_PAGE }, (_, i) => {
    const agent = agents[agentIndexForKey(columnOffset, i)];
    return agent !== undefined ? buildAgentKey(agent) : EMPTY_KEY;
  });
}

/** Builds descriptors in direct physical-key order for non-grid surfaces. */
export function layoutPhysicalKeys(agents: readonly (AgentInput | undefined)[]): KeyDescriptor[] {
  return Array.from({ length: KEYS_PER_PAGE }, (_, i) => {
    const agent = agents[i];
    return agent !== undefined ? buildAgentKey(agent) : EMPTY_KEY;
  });
}
