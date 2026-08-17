/**
 * Aiur's speech recognition and pronunciation policy.
 *
 * The safe dictation variants are coined/non-words that can be corrected
 * without changing something an operator plausibly meant. Real words and the
 * `IR` acronym are deliberately recorded but never rewritten: a visible
 * mishearing is recoverable, while a confident silent corruption is not.
 */
export const AIUR_SPEECH_POLICY = Object.freeze({
  canonical: "Aiur",
  pronunciation: "eye-ur",
  safeDictationWords: Object.freeze(["aeor", "iyer", "ayer"]),
  safeDictationPhrases: Object.freeze(["A, your"]),
  preservedAmbiguousVariants: Object.freeze(["higher", "iron", "ire", "IR"]),
});

const escaped = (value: string): string => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const safePhrasePattern = new RegExp(
  `\\b(?:${AIUR_SPEECH_POLICY.safeDictationPhrases.map(escaped).join("|").replaceAll(" ", "\\s+")})\\b`,
  "gi",
);
const safeWordPattern = new RegExp(`\\b(?:${AIUR_SPEECH_POLICY.safeDictationWords.map(escaped).join("|")})\\b`, "gi");
const canonicalPattern = new RegExp(`\\b${escaped(AIUR_SPEECH_POLICY.canonical)}\\b`, "gi");

/** Correct only variants that cannot reasonably be intended technical prose. */
export const normalizeAiurDictation = (text: string): string =>
  text
    .replace(safePhrasePattern, AIUR_SPEECH_POLICY.canonical)
    .replace(safeWordPattern, AIUR_SPEECH_POLICY.canonical);

/** Give a speech provider an explicit phonetic spelling for the coined name. */
export const prepareAiurForSpeech = (text: string): string =>
  text.replace(canonicalPattern, AIUR_SPEECH_POLICY.pronunciation);
