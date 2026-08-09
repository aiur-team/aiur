import { describe, expect, it } from "vitest";

import {
  BADGE_IDS,
  BUCKET_IDS,
  assertKeyFaceContract,
  bucketContract,
  bucketRank,
  directionBadgeColor,
  KEY_FACE_CONTRACT,
  progressBarColor,
} from "../src/key-face-contract.js";
import { layoutKeys, type AgentInput } from "../src/keys.js";
import { badgeColor } from "../src/logs.js";

const agent = (bucket: AgentInput["bucket"]): AgentInput => ({
  identifier: bucket,
  title: `${bucket} agent`,
  vendor: "codex",
  bucket,
  progress_percent: 50,
  priority: false,
});

describe("key-face contract parity", () => {
  it.each(BUCKET_IDS)("derives the package state token and rank for %s from shared data", (bucket) => {
    const state = KEY_FACE_CONTRACT.states[bucket];
    const key = layoutKeys([agent(bucket)], 0)[0];

    expect(key).toMatchObject({ kind: "agent", style: { accent: state.accent, glow: state.glow, face: state.face, label: state.label } });
    expect(bucketContract(bucket)).toBe(state);
    expect(bucketRank(bucket)).toBe(state.rank);
  });

  it.each([0, 50, 100])("uses the shared progress formula for %i%%", (percent) => {
    const progress = KEY_FACE_CONTRACT.progress;
    const hue = progress.hue_start + ((percent - progress.minimum) / (progress.maximum - progress.minimum)) * (progress.hue_end - progress.hue_start);
    expect(progressBarColor(percent)).toBe(`hsl(${Number(hue.toFixed(progress.round_decimals))} ${progress.saturation}% ${progress.lightness}%)`);
  });

  it.each(BADGE_IDS)("uses the shared direction-badge colour for %s", (badge) => {
    expect(badgeColor(badge)).toBe(KEY_FACE_CONTRACT.direction_badges[badge].color);
    expect(directionBadgeColor(badge)).toBe(KEY_FACE_CONTRACT.direction_badges[badge].color);
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
