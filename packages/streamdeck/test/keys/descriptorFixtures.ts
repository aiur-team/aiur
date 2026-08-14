import {
  type AgentKey,
  type BucketId,
  type Footer,
  type Vendor,
  BUCKET_STYLES,
  progressBarColor,
} from "../../src/keys.js";
import { KEY_FACE_CONTRACT } from "../../src/key-face-contract.js";

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
      ? {
          kind: KEY_FACE_CONTRACT.footers.queued.kind,
          label: BUCKET_STYLES.queued.label,
          unblocked: overrides.dependencyReady === true,
          statusLabel:
            overrides.dependencyReady === true
              ? KEY_FACE_CONTRACT.footers.queued.ready_label
              : KEY_FACE_CONTRACT.footers.queued.blocked_label,
        }
      : { kind: KEY_FACE_CONTRACT.footers.progress.kind, barColor: progressBarColor(percent), percent };
  return {
    kind: "agent",
    identifier,
    title: overrides.title ?? "",
    vendor: overrides.vendor ?? "claude",
    icon: "",
    role: "agent",
    subLabel: "",
    timeLabel: "",
    selected: false,
    priority: overrides.priority ?? false,
    bucket,
    style: BUCKET_STYLES[bucket],
    progressPercent: percent,
    footer,
  };
}
