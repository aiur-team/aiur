---
ticket_id: MP-N7-C4-T02
feature_id: MP-N7
chunk_id: MP-N7-C4
bucket: 3-mobile-watch
title: Dictate with the system recognizer (D-sys) on both watches, review before Send, provider disclosure
status: blocked
blocked_by: [DESIGN-N7, DESIGN-E5, DESIGN-N6, OQ-N7-2, MP-N7-C4-T01]
prior_units: []
prior_boundaries: ["VOX #36"]
prior_features: [MP-E5, MP-N6]
prior_findings: ["framework-evidence S9, S11, S36"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C4-T02 — System-recognizer dictation on the watch

## Identity and outcome

- Bucket 3, MP-N7, chunk C4. Merges candidate N7-C4-T02 and N7-C4-T06 (disclosure copy):
  the disclosure is part of the screen that triggers the recognizer.
- **User value:** dictate a custom answer on the wrist, read it, and send it.
- **Deliverable:** "Dictate" opens the platform's text input with dictation; the result
  appears on a review screen (Edit = dictate again, Send, Cancel); Send submits
  `answer{custom_response}` through the existing card send path (C2-T03/C3-T03 state
  machine). A one-line disclosure "Speech is processed by Apple/Google" is shown on the
  review screen and in the watch settings section of the phone (DESIGN-N7 D-N7-2 copy). The
  copy source is the `contracts/voice-session.md` §10 row "System dictation (watch/phone
  keyboard): audio to Apple or Google under their policy; aiur receives text only" (Phase D
  security m10); this ticket does not invent its own wording.
- **Non-goals:** relayed dictation through the daemon (C4-T03/T04, used only if the owner
  picks D-relay).

## Dependencies and blockers

- **OQ-N7-2 / DESIGN-N7 D-N7-2** must choose D-sys as the default (recommended). If the
  owner chooses "always through the phone and ElevenLabs", this ticket is reduced to the
  review screen only and Dictate uses C4-T03/T04.
- DESIGN-E5 (review-before-send rule and wording), DESIGN-N6, MP-N7-C4-T01.

## Verified starting point

- watchOS: the Speech framework is not available (S9, `SFSpeechRecognizer` lists no
  watchOS). System text input with dictation is available
  (`presentTextInputController(withSuggestions:…)`, watchOS 2.0+, S11). In SwiftUI a
  `TextField` on watchOS presents the system text input (keyboard/scribble/dictation,
  depending on device and region; exact options **UNVERIFIED** per model, recorded in DV-W5).
- Wear OS: `RecognizerIntent.ACTION_RECOGNIZE_SPEECH` for free-form speech
  (S36, <https://developer.android.com/training/wearables/user-input/voice>, updated 2024-11-12).
- Brief §7: cloud processing must be disclosed separately from push privacy.
- MP-E5 review rule: dictated text is edited before Send (MP-E5 plan; voice-session.md
  table "Dictate … the edited text until Send").

## Chosen design

- watchOS: `DictateReviewView` with a `TextField` whose focus is requested only after the
  user taps "Dictate" (explicit), result bound to `draftText`. If the system input is
  dismissed empty → back to card, nothing sent.
- Wear: `rememberLauncherForActivityResult(StartActivityForResult)` with
  `RecognizerIntent.ACTION_RECOGNIZE_SPEECH`, `EXTRA_LANGUAGE_MODEL = LANGUAGE_MODEL_FREE_FORM`;
  `RESULT_OK` → `EXTRA_RESULTS[0]`; `ActivityNotFoundException` → Dictate option
  `unavailable{reason: no_recognizer}` (recorded in the snapshot-independent local input I4).
- Max 4,000 characters (C1-T01 invariant 3); longer → Send disabled with count.
- Draft text lives in memory only; leaving the card discards it (no transcript retention on
  the watch; transcripts are an MP-E6 server concern, D17 audio rule n/a: no audio file).

## Implementation steps

1. Review screens on both platforms; shared copy keys.
2. Hook Send into the card model's `sendAnswer(custom_response:)`.
3. Disclosure line; phone settings line (small edit in MP-N1 watch settings screen,
   surface-boundary row 16).
4. Tests.

## Non-happy paths

Recognizer unavailable (Wear device without speech service) → `unavailable`. Phone
unreachable at Send → `notConfirmed`, text kept on screen until the user leaves. Command
resolved meanwhile → `resolvedElsewhere`, draft discarded with notice.

## Compatibility and rollout

Watch UI only.

## Verification

```text
xcodebuild test ... -scheme AiurWatch -only-testing:AiurWatchTests/DictateReviewModelTests
packages/aiur-mobile/wear/gradlew -p packages/aiur-mobile/wear :app:testDebugUnitTest --tests '*DictateReviewViewModelTest'
```

| Test | Expected | Must fail without |
|---|---|---|
| `emptyResultSendsNothing` | no answer sent | the empty check |
| `sendUsesCustomResponse` | answer has `custom_response`, no option id | wiring |
| `overLimitDisablesSend` | 4,001 chars → Send disabled | limit |
| `noRecognizerIsUnavailable` (Wear) | exception → `unavailable{no_recognizer}` | the catch branch |
| `disclosureShown` | review screen contains disclosure key | the line |

Device: DV-W5 (both platforms).

## Completion and handoff

- [ ] Dictate works on device with review before Send; disclosure approved in DESIGN-N7.
- [ ] Docs: the mobile guide's privacy section states where watch dictation is processed
  (brief §7), same PR.
- Dependents: MP-N7-C6-T01, C6-T02.
