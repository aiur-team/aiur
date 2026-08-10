import { describe, expect, it } from "vitest";

// The same golden table `src/test/aiur_web/streamdeck_key_face_contract_test.exs`
// asserts against. These are literal expected renderings, not a restatement of
// the formula: a hue rounded differently in one language, or a contract value
// changed on one side only, fails here rather than drifting silently.
import vectors from "../src/key-face-parity-vectors.json" with { type: "json" };
import {
  BADGE_IDS,
  BUCKET_IDS,
  assertKeyFaceContract,
  bucketContract,
  bucketRank,
  directionBadgeColor,
  KEY_FACE_CONTRACT,
  progressBarColor,
  type DirectionBadge,
} from "../src/key-face-contract.js";
import { layoutKeys, type AgentInput, type AgentKey } from "../src/keys.js";
import { badgeColor } from "../src/logs.js";

function firstAgentKey(input: AgentInput): AgentKey {
  const key = layoutKeys([input], 0)[0];
  if (key.kind !== "agent") throw new Error(`expected an agent key, received ${key.kind}`);
  return key;
}

const agent = (bucket: AgentInput["bucket"], overrides: Partial<AgentInput> = {}): AgentInput => ({
  identifier: bucket,
  title: `${bucket} agent`,
  vendor: "codex",
  bucket,
  progress_percent: 50,
  priority: false,
  ...overrides,
});

describe("key-face contract parity", () => {
  it("covers every contract state and direction badge in the parity table", () => {
    expect(vectors.states.map((vector) => vector.bucket).sort()).toEqual([...BUCKET_IDS].sort());
    expect(vectors.direction_badges.map((vector) => vector.badge).sort()).toEqual([...BADGE_IDS].sort());
  });

  it.each(vectors.states)("renders $bucket with the parity-table state tokens", (vector) => {
    const bucket = vector.bucket as (typeof BUCKET_IDS)[number];
    const key = firstAgentKey(agent(bucket));

    expect(key).toMatchObject({
      kind: "agent",
      style: {
        accent: vector.accent,
        glow: vector.glow,
        face: vector.face,
        label: vector.label,
        ...(vector.pulse_seconds === null ? {} : { pulseSeconds: vector.pulse_seconds }),
      },
    });
    if (vector.pulse_seconds === null) expect(key.style).not.toHaveProperty("pulseSeconds");
    expect(bucketRank(bucket)).toBe(vector.rank);
    expect(bucketContract(bucket).rank).toBe(vector.rank);
  });

  it.each(vectors.progress)("maps $percent%% progress to the parity-table hue", (vector) => {
    expect(progressBarColor(vector.percent)).toBe(vector.color);
  });

  it.each(vectors.direction_badges)("uses the parity-table colour for $badge", (vector) => {
    const badge = vector.badge as DirectionBadge;
    expect(badgeColor(badge)).toBe(vector.color);
    expect(directionBadgeColor(badge)).toBe(vector.color);
  });

  it.each(vectors.footers)("builds the $bucket footer for readiness $dependency_ready", (vector) => {
    const bucket = vector.bucket as (typeof BUCKET_IDS)[number];
    const readiness = vector.dependency_ready === "absent" ? {} : { dependency_ready: vector.dependency_ready as boolean };
    const key = firstAgentKey(agent(bucket, readiness));

    expect(key.footer.kind).toBe(vector.kind);

    if (vector.kind === "queued") {
      expect(key.footer).toMatchObject({ label: vector.label, statusLabel: vector.dependency, unblocked: vector.ready });
    } else {
      expect(vector.dependency).toBeNull();
      expect(key.footer).not.toHaveProperty("statusLabel");
      expect(key.style.label).toBe(vector.label);
    }
  });

  it("does not silently default an unhandled runtime state", () => {
    expect(() => layoutKeys([agent("unknown" as AgentInput["bucket"])], 0)).toThrow("unhandled Stream Deck key state");
    expect(() => bucketContract("unknown" as AgentInput["bucket"])).toThrow("unhandled Stream Deck key state");
  });

  it("rejects a shared contract that adds or removes an unhandled mapping", () => {
    const missingState = { ...KEY_FACE_CONTRACT, states: { ...KEY_FACE_CONTRACT.states } };
    delete (missingState.states as Partial<typeof missingState.states>).queued;

    const missingBadge = { ...KEY_FACE_CONTRACT, direction_badges: { ...KEY_FACE_CONTRACT.direction_badges } };
    delete (missingBadge.direction_badges as Partial<typeof missingBadge.direction_badges>).INFO;

    const missingAccent = { ...KEY_FACE_CONTRACT, states: { ...KEY_FACE_CONTRACT.states, running: { ...KEY_FACE_CONTRACT.states.running, accent: "" } } };
    const nonNumericRank = { ...KEY_FACE_CONTRACT, states: { ...KEY_FACE_CONTRACT.states, running: { ...KEY_FACE_CONTRACT.states.running, rank: "two" } } };
    const infiniteRank = { ...KEY_FACE_CONTRACT, states: { ...KEY_FACE_CONTRACT.states, running: { ...KEY_FACE_CONTRACT.states.running, rank: Infinity } } };
    const zeroRange = { ...KEY_FACE_CONTRACT, progress: { ...KEY_FACE_CONTRACT.progress, maximum: 0 } };
    const invalidPrecision = { ...KEY_FACE_CONTRACT, progress: { ...KEY_FACE_CONTRACT.progress, round_decimals: -1 } };
    const invalidReadyWhen = { ...KEY_FACE_CONTRACT, footers: { ...KEY_FACE_CONTRACT.footers, queued: { ...KEY_FACE_CONTRACT.footers.queued, ready_when: "true" } } };

    expect(() => assertKeyFaceContract(missingState as typeof KEY_FACE_CONTRACT)).toThrow("key-face states must handle exactly");
    expect(() => assertKeyFaceContract(missingBadge as typeof KEY_FACE_CONTRACT)).toThrow("key-face direction badges must handle exactly");
    expect(() => assertKeyFaceContract(missingAccent as typeof KEY_FACE_CONTRACT)).toThrow("state running accent must be a non-empty string");
    expect(() => assertKeyFaceContract(nonNumericRank as unknown as typeof KEY_FACE_CONTRACT)).toThrow("state running rank must be a finite number");
    expect(() => assertKeyFaceContract(infiniteRank as typeof KEY_FACE_CONTRACT)).toThrow("state running rank must be a finite number");
    expect(() => assertKeyFaceContract(zeroRange as typeof KEY_FACE_CONTRACT)).toThrow("progress maximum must exceed minimum");
    expect(() => assertKeyFaceContract(invalidPrecision as typeof KEY_FACE_CONTRACT)).toThrow("progress round_decimals must be a non-negative integer");
    expect(() => assertKeyFaceContract(invalidReadyWhen as unknown as typeof KEY_FACE_CONTRACT)).toThrow("queued footer ready_when must be a boolean");
  });
});
