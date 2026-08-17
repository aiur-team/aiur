import { describe, expect, it } from "vitest";
import { AIUR_SPEECH_POLICY, normalizeAiurDictation, prepareAiurForSpeech } from "../src/aiur-speech.js";

describe("Aiur speech policy", () => {
  it.each([
    ["AEOR microphone test", "Aiur microphone test"],
    ["iyer fleet", "Aiur fleet"],
    ["AYer ticket", "Aiur ticket"],
    ["A, your fleet is paused", "Aiur fleet is paused"],
  ])("corrects unambiguous dictation %j", (dictation, expected) => {
    expect(normalizeAiurDictation(dictation)).toBe(expected);
  });

  it.each([
    "give this higher priority",
    "raise it to a higher complexity",
    "we need a higher agent count",
    "inspect the iron fixture and IR sensor without ire",
  ])("preserves ambiguous technical speech %j", (text) => {
    expect(normalizeAiurDictation(text)).toBe(text);
  });

  it("changes whole variants only", () => {
    expect(normalizeAiurDictation("player ayerish aeor-team aeorian")).toBe("player ayerish Aiur-team aeorian");
  });

  it("uses the same policy to prepare outbound speech", () => {
    expect(prepareAiurForSpeech("Aiur asks AIUR agents to use aiur-team/aiur.")).toBe(
      "eye-ur asks eye-ur agents to use eye-ur-team/eye-ur.",
    );
    expect(AIUR_SPEECH_POLICY.preservedAmbiguousVariants).toEqual(["higher", "iron", "ire", "IR"]);
  });
});
