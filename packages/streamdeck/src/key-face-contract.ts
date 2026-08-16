import contract from "./key-face-contract.json" with { type: "json" };

export const BUCKET_IDS = ["alert", "stuck", "running", "paused", "queued"] as const;
export type BucketId = (typeof BUCKET_IDS)[number];

export const BADGE_IDS = ["EMIT", "CONSUME", "AGENT", "SYSTEM", "INFO"] as const;
export type DirectionBadge = (typeof BADGE_IDS)[number];

export interface BucketContract {
  readonly rank: number;
  readonly glow: string;
  readonly face: string;
  readonly accent: string;
  readonly label: string;
  readonly pulse_seconds?: number;
}

export interface ProgressContract {
  readonly minimum: number;
  readonly maximum: number;
  /** One fill colour for every measured value. */
  readonly fill: string;
  /** Slightly brighter fill at 100% so completion reads at a glance. */
  readonly complete_fill: string;
}

export interface QueuedFooterContract {
  readonly kind: "queued";
  /** The only readiness value that paints the queued footer as unblocked. */
  readonly ready_when: boolean;
  readonly ready_label: string;
  readonly blocked_label: string;
}

interface KeyFaceContract {
  readonly states: Readonly<Record<BucketId, BucketContract>>;
  readonly progress: ProgressContract;
  readonly direction_badges: Readonly<Record<DirectionBadge, Readonly<{ color: string }>>>;
  readonly footers: {
    readonly progress: Readonly<{ kind: "progress" }>;
    readonly queued: QueuedFooterContract;
  };
}

export const KEY_FACE_CONTRACT = contract as KeyFaceContract;

function assertExactKeys(actual: object, expected: readonly string[], label: string): void {
  const actualKeys = Object.keys(actual).sort();
  const expectedKeys = [...expected].sort();
  if (actualKeys.length !== expectedKeys.length || actualKeys.some((key, index) => key !== expectedKeys[index])) {
    throw new Error(`${label} must handle exactly ${expectedKeys.join(", ")}; received ${actualKeys.join(", ")}`);
  }
}

function assertNonEmptyString(value: unknown, label: string): void {
  if (typeof value !== "string" || value.length === 0) throw new Error(`${label} must be a non-empty string`);
}

function assertFiniteNumber(value: unknown, label: string): void {
  if (typeof value !== "number" || !Number.isFinite(value)) throw new Error(`${label} must be a finite number`);
}

/**
 * Keep this validation at the import boundary. Adding a shared state or badge
 * without adding an exhaustive renderer mapping fails before a key can render
 * with an accidental fallback.
 */
export function assertKeyFaceContract(candidate: KeyFaceContract = KEY_FACE_CONTRACT): void {
  assertExactKeys(candidate.states, BUCKET_IDS, "key-face states");
  assertExactKeys(candidate.direction_badges, BADGE_IDS, "key-face direction badges");

  for (const bucket of BUCKET_IDS) {
    const state = candidate.states[bucket];
    assertFiniteNumber(state.rank, `state ${bucket} rank`);
    for (const field of ["glow", "face", "accent", "label"] as const) assertNonEmptyString(state[field], `state ${bucket} ${field}`);
    if (state.pulse_seconds !== undefined) assertFiniteNumber(state.pulse_seconds, `state ${bucket} pulse_seconds`);
  }

  const progress = candidate.progress;
  for (const field of ["minimum", "maximum"] as const) {
    assertFiniteNumber(progress[field], `progress ${field}`);
  }
  if (progress.maximum <= progress.minimum) throw new Error("progress maximum must exceed minimum");
  assertNonEmptyString(progress.fill, "progress fill");
  assertNonEmptyString(progress.complete_fill, "progress complete_fill");

  for (const badge of BADGE_IDS) assertNonEmptyString(candidate.direction_badges[badge].color, `direction badge ${badge} color`);
  assertNonEmptyString(candidate.footers.progress.kind, "progress footer kind");
  assertNonEmptyString(candidate.footers.queued.kind, "queued footer kind");
  if (typeof candidate.footers.queued.ready_when !== "boolean") throw new Error("queued footer ready_when must be a boolean");
  assertNonEmptyString(candidate.footers.queued.ready_label, "queued footer ready_label");
  assertNonEmptyString(candidate.footers.queued.blocked_label, "queued footer blocked_label");
}

assertKeyFaceContract();

export function bucketContract(bucket: BucketId): BucketContract {
  const state = KEY_FACE_CONTRACT.states[bucket];
  if (state === undefined) throw new Error(`unhandled Stream Deck key state: ${bucket}`);
  return state;
}

export function bucketRank(bucket: BucketId): number {
  return bucketContract(bucket).rank;
}

/**
 * The one fill colour for a progress bar, with the brighter completion shade at
 * 100%. This is deliberately a single colour rather than a hue ramp: a ramp
 * reads the bar as two segments of data and, on the device, as two tones of
 * grey at low saturation. Completion is a shade change, not a different hue.
 */
export function progressBarColor(percent: number): string {
  const { minimum, maximum, fill, complete_fill } = KEY_FACE_CONTRACT.progress;
  const clamped = Math.max(minimum, Math.min(maximum, percent));
  return clamped >= maximum ? complete_fill : fill;
}

export function directionBadgeColor(badge: DirectionBadge): string {
  return KEY_FACE_CONTRACT.direction_badges[badge].color;
}
