/** Legacy drawing compatibility only; the runtime displays daemon frames. Remove with SD-105. */
const palette = {
  "states": {
    "alert": {
      "rank": 0,
      "glow": "linear-gradient(180deg,#ffc061,#e08a1e)",
      "face": "linear-gradient(180deg,#241d0e,#15110a)",
      "accent": "#ffcf87",
      "label": "Needs input",
      "pulse_seconds": 1.6
    },
    "stuck": {
      "rank": 1,
      "glow": "linear-gradient(180deg,#ff6a5e,#c0392b)",
      "face": "linear-gradient(180deg,#271317,#160c0e)",
      "accent": "#ff9a90",
      "label": "Stuck",
      "pulse_seconds": 1.4
    },
    "running": {
      "rank": 2,
      "glow": "linear-gradient(180deg,#3f8bff,#7b4bf5)",
      "face": "linear-gradient(180deg,#18212d,#0f151d)",
      "accent": "#9fd0ff",
      "label": "Running"
    },
    "paused": {
      "rank": 3,
      "glow": "linear-gradient(180deg,#4a4d55,#33363d)",
      "face": "linear-gradient(180deg,#1e2025,#131419)",
      "accent": "#c2c6cf",
      "label": "Paused"
    },
    "queued": {
      "rank": 4,
      "glow": "linear-gradient(180deg,#3a3f47,#23262c)",
      "face": "linear-gradient(180deg,#191b21,#111318)",
      "accent": "#9096a4",
      "label": "Unstarted"
    }
  },
  "progress": {
    "minimum": 0,
    "maximum": 100,
    "fill": "#3fb950",
    "complete_fill": "#74d47f"
  },
  "direction_badges": {
    "EMIT": {
      "color": "#9fd0ff"
    },
    "CONSUME": {
      "color": "#88e0a6"
    },
    "AGENT": {
      "color": "#9fd0ff"
    },
    "SYSTEM": {
      "color": "#ffcf87"
    },
    "INFO": {
      "color": "#c2c6cf"
    }
  },
  "footers": {
    "progress": {
      "kind": "progress"
    },
    "queued": {
      "kind": "queued",
      "ready_when": true,
      "ready_label": "Unblocked",
      "blocked_label": "Blocked"
    }
  }
} as const;

export const BUCKET_IDS = ["alert", "stuck", "running", "paused", "queued"] as const;
export type BucketId = (typeof BUCKET_IDS)[number];

export const BADGE_IDS = ["EMIT", "CONSUME", "AGENT", "SYSTEM", "INFO"] as const;
export type DirectionBadge = (typeof BADGE_IDS)[number];

export interface LegacyBucketStyle {
  readonly rank: number;
  readonly glow: string;
  readonly face: string;
  readonly accent: string;
  readonly label: string;
  readonly pulse_seconds?: number;
}

export interface LegacyProgressStyle {
  readonly minimum: number;
  readonly maximum: number;
  /** One fill colour for every measured value. */
  readonly fill: string;
  /** Slightly brighter fill at 100% so completion reads at a glance. */
  readonly complete_fill: string;
}

export interface LegacyQueuedFooter {
  readonly kind: "queued";
  /** The only readiness value that paints the queued footer as unblocked. */
  readonly ready_when: boolean;
  readonly ready_label: string;
  readonly blocked_label: string;
}

interface LegacyStyle {
  readonly states: Readonly<Record<BucketId, LegacyBucketStyle>>;
  readonly progress: LegacyProgressStyle;
  readonly direction_badges: Readonly<Record<DirectionBadge, Readonly<{ color: string }>>>;
  readonly footers: {
    readonly progress: Readonly<{ kind: "progress" }>;
    readonly queued: LegacyQueuedFooter;
  };
}

export const LEGACY_STYLE = palette as LegacyStyle;

/** Flat neutral fill shared by every Stream Deck surface with no progress reading. */
export const UNKNOWN_PROGRESS_COLOR = "rgba(255,255,255,0.22)";

export function bucketContract(bucket: BucketId): LegacyBucketStyle {
  const state = LEGACY_STYLE.states[bucket];
  if (state === undefined) throw new Error(`unhandled Stream Deck key state: ${bucket}`);
  return state;
}

/**
 * The one fill colour for a progress bar, with the brighter completion shade at
 * 100%. This is deliberately a single colour rather than a hue ramp: a ramp
 * reads the bar as two segments of data and, on the device, as two tones of
 * grey at low saturation. Completion is a shade change, not a different hue.
 */
export function progressBarColor(percent: number): string {
  const { minimum, maximum, fill, complete_fill } = LEGACY_STYLE.progress;
  const clamped = Math.max(minimum, Math.min(maximum, percent));
  return clamped >= maximum ? complete_fill : fill;
}

export function directionBadgeColor(badge: DirectionBadge): string {
  return LEGACY_STYLE.direction_badges[badge].color;
}
