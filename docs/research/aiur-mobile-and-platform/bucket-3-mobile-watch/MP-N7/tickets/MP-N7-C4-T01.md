---
ticket_id: MP-N7-C4-T01
feature_id: MP-N7
chunk_id: MP-N7-C4
bucket: 3-mobile-watch
title: Watch mic choice sheet (Dictate or Converse, D16) on watchOS and Wear OS, no recording before a choice
status: blocked
blocked_by: [DESIGN-N7, DESIGN-E5, DESIGN-E6, DESIGN-N6, MP-N7-C2-T03, MP-N7-C3-T03, MP-N7-C2-T05, MP-N7-C3-T05]
prior_units: []
prior_boundaries: ["VOX #36"]
prior_features: [MP-E5, MP-E6, MP-N6]
prior_findings: ["D16 explicit choice; brief N6 no auto-record"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C4-T01 — Mic choice sheet on both watches

## Identity and outcome

- Bucket 3, MP-N7, chunk C4 (watch voice).
- **User value:** the operator chooses, every time, whether the mic dictates an answer or
  starts a spoken conversation; nothing listens before that choice.
- **Deliverable:** the card's mic button opens a two-option sheet ("Dictate", "Converse")
  on watchOS (SwiftUI `.sheet`) and Wear (Compose dialog). Each option shows its affordance
  state from the snapshot's pre-resolved `affordances` (`mic_dictate_system`,
  `mic_dictate_server`, `mic_converse`; capability model §7). Choosing an option navigates
  to C4-T02 (Dictate) or C4-T05 (Converse). The `WatchFeatures.voice` flag from C2-T03 /
  C3-T03 is removed.
- **Non-goals:** any capture code.

## Dependencies and blockers

DESIGN-N7 (screen 5), DESIGN-E5/E6 (control vocabulary), DESIGN-N6; card tickets and
inventory tests (this ticket extends both allow-lists with `aiur.mic.dictate`,
`aiur.mic.converse`, `aiur.mic.cancel`).

## Verified starting point

- D16: "Mic activation always offers an explicit choice of buttons (dictate or converse) on
  the dashboard, phone and watch, with no default mode" (`context-and-decisions.md` D16).
- Capability rule: "The Mic button itself is `ready` if either Dictate or Converse resolves
  to `ready` or `degraded` … an unavailable option is shown with its reason, not removed
  silently" (`contracts/client-capability-model.md` §5).
- Existing browser voice controls (for wording consistency only):
  `src/lib/aiur_web/components/conversation_drawer.ex:184-231` (cited by MP-E5-C1-T1).

## Chosen design

- Mic button state = best of the two options; if both unavailable, the button is shown
  disabled with "Voice unavailable" + reason (never hidden; never a working-looking button).
- Dictate option state: `ready` if `mic_dictate_system` is ready (system recognizer needs
  no server voice) or, when the owner chose D-relay (D-N7-2), from `mic_dictate_server`.
- Converse option state: `mic_converse`; plus local mic permission (`needs_permission`).
- Opening the sheet does not touch `AVAudioSession`/`AudioRecord`; the sheet is the only
  path into capture screens; notification routing never opens it (C2-T04/C3-T04 guards).

## Implementation steps

1. `MicChoiceSheet.swift` / `MicChoiceDialog.kt`; shared state-resolution fixture
   `fixtures/watch-link/mic-choice-cases.json`.
2. Extend inventory walks and allow-list.
3. Remove the voice flag.

## Non-happy paths

Phone unreachable → both options `unreachable` "Needs phone" (Dictate via system recognizer
stays available only for composing text; Send is disabled until the phone is reachable, so
the sheet shows Dictate as `degraded: "Send needs phone"`). Permission denied → option shows
`needs_permission` with the platform's settings hint (DESIGN-N7 §5).

## Compatibility and rollout

Watch-only UI.

## Verification

```text
xcodebuild test -workspace packages/aiur-mobile/ios/aiur.xcworkspace -scheme AiurWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' -only-testing:AiurWatchTests/MicChoiceTests
packages/aiur-mobile/wear/gradlew -p packages/aiur-mobile/wear :app:testDebugUnitTest --tests '*MicChoiceTest'
```

| Test | Expected | Must fail without |
|---|---|---|
| `casesMatchFixture` (both) | every row of `mic-choice-cases.json` | each branch; replacing `unavailable` with `ready` fails |
| `noAudioBeforeChoice` (both) | audio session/recorder spies untouched after opening sheet | — (guard for D16/brief N6; commented) |
| `bothUnavailableShowsDisabledWithReason` | disabled button, reason text | the both-unavailable branch |
| inventory tests | pass with the extended allow-list | — |

## Completion and handoff

- [ ] Sheet on both platforms; DESIGN-N7 screen 5 approved states.
- Dependents: MP-N7-C4-T02, MP-N7-C4-T05.
