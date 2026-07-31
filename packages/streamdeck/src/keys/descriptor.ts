/**
 * Provisional key-descriptor contract — the subset of #1350's public types that
 * the key render/encode pipeline consumes.
 *
 * #1350 (`src/keys.ts`, PR #1394) owns the descriptor model and the
 * `layoutKeys` mapping that produces these values. That work is not yet on
 * `develop`, so to keep this pipeline compiling and tested in isolation we mirror
 * only the *types* it depends on here — no `layoutKeys`, `BUCKET_STYLES`, or any
 * runtime logic, which stay #1350's to own. When #1350 lands, delete this file
 * and re-point the imports below at `../keys.js`; the type shape is identical, so
 * the swap is import-only. Kept type-only deliberately to avoid an add/add
 * conflict on #1350's runtime module.
 */

/** Bucket the agent currently sits in; drives styling and footer. */
export type BucketId = "running" | "paused" | "stuck" | "alert" | "queued";

/** Which coding agent backs the ticket. */
export type Vendor = "claude" | "codex";

/** Visual tokens for a bucket. */
export interface BucketStyle {
  readonly accent: string;
  readonly glow: string;
  readonly face: string;
  readonly label: string;
  readonly pulseSeconds?: number;
}

/** Footer showing a progress bar. */
export interface ProgressFooter {
  readonly kind: "progress";
  readonly barColor: string;
  readonly percent: number;
}

/** Footer for a queued agent. */
export interface QueuedFooter {
  readonly kind: "queued";
  readonly label: string;
  readonly unblocked: boolean;
}

export type Footer = ProgressFooter | QueuedFooter;

/** A key showing one agent. */
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

/** A key with no agent. */
export interface EmptyKey {
  readonly kind: "empty";
}

export type KeyDescriptor = AgentKey | EmptyKey;
