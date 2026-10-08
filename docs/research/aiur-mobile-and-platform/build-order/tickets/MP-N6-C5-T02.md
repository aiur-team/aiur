---
ticket_id: MP-N6-C5-T02
feature_id: MP-N6
chunk_id: MP-N6-C5
bucket: 3-mobile-watch
title: Watch mic — Dictate/Converse choice on the watch or hand-off to the phone
status: blocked
blocked_by: [DESIGN-N6, DESIGN-N7 D-N7-3/D-N7-4 (OQ-N6-3), DESIGN-E5, MP-N6-C5-T01, MP-N7-C4-T02, MP-N7-C4-T05]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N7, MP-E5]
prior_findings: [RQ-N6-1 (watch on-device transcription via client_text, with MP-N7), D16]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C5-T02 — Watch mic

## Identity and outcome

Bucket 3, MP-N6, chunk C5. The watch Mic offers the same explicit Dictate / Converse choice
(D16). Dictate uses the watch system recognizer (client capability model §5 row "Mic →
Dictate (system recognizer, watch)") or the server path per MP-N7; Converse runs on the
watch or hands off to the phone per DESIGN-N7 D-N7-3/D-N7-4 (the owner; DESIGN-N6 D-3 links
there, review G-7).

## Dependencies and blockers

**Blocked on DESIGN-N7 D-N7-3/D-N7-4 (OQ-N6-3; DESIGN-N6 D-3 is a link)** — decides whether
Converse exists on the watch at all; plus DESIGN-N6, DESIGN-N7, DESIGN-E5, MP-N7 watch voice: MP-N7-C4-T02
(Dictate) and MP-N7-C4-T05 (Converse).

## Verified starting point

Client capability model §5 watch dictation row; voice-session §3.5 device path.

## Chosen design

Fixed now (independent of D-3):

- The watch Mic always opens a choice with **Dictate** and **Converse** rows and no
  default (D16). An unavailable row stays visible with its reason.
- Dictate: MP-N7-C4-T02 (system recognizer → review → Send; or the relay path if OQ-N7-2
  picks it). The answer carries `via: "dictate"` and shows "via voice".
- Voice errors on the watch use the same voice-session §8.1 rows as the phone, through
  `packages/aiur-mobile/fixtures/contract/voice/end-reasons.json` (MP-N7-C4-T05 tests
  it; this ticket only routes the codes to that view). `cost_cap` and `provider_quota`
  never offer Retry.
- Rules are pinned in `packages/aiur-mobile/fixtures/watch-link/voice-choice-cases.json`
  (this ticket): capability input → `{dictate: state+reason, converse: state+reason |
  "on_phone"}`.

Decided by DESIGN-N7 D-N7-3/D-N7-4 (DESIGN-N6 D-3 links there); both branches are specified so the ticket does
not change shape after the answer:

| D-3 answer | Converse row on the watch | Work in this ticket |
| --- | --- | --- |
| Converse on the watch | opens MP-N7-C4-T05 `ConverseView` | fixture rows only; no extra screen |
| Hand off to phone (proposal if DV-W6 misses the latency figure) | "Continue on phone" | send the Command destination with `intent: "converse"` over the C5-T03 hand-off; the phone opens the Command screen with the C4-T01 sheet open (the user still taps Converse there, D16) |

## Implementation steps

1. Write `voice-choice-cases.json` (both D-3 branches, keyed `d3: "watch" | "phone"`).
2. Watch choice view models: `WatchVoiceChoiceModel.swift` (watchOS) and
   `WatchVoiceChoiceViewModel.kt` (Wear OS), reading the fixture branch for the approved
   D-3 value (a build constant).
3. If D-3 = phone: add `intent: "converse"` to the C5-T03 hand-off payload and handle it in
   `landOn` (C2-T02) by opening the sheet without choosing.
4. Docs: the mobile guide's watch section states where watch Converse runs (same PR as the
   MP-N7 watch docs, `website/docs-app/guide/mobile.md`).

## Non-happy paths

- Recognizer unavailable → Dictate unavailable with reason.
- `voice.conversation` unavailable → Converse unavailable with reason (both branches).
- Phone unreachable during hand-off → "Phone not reachable" (C5-T03).

## Compatibility and rollout

watchOS 10 / Wear OS per MP-N7. Copy is DESIGN-N6/N7 (design-pending).

## Verification

```text
xcodebuild test -workspace packages/aiur-mobile/ios/aiur.xcworkspace -scheme AiurWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' -only-testing:AiurWatchTests/WatchVoiceChoiceModelTests
packages/aiur-mobile/wear/gradlew -p packages/aiur-mobile/wear :app:testDebugUnitTest --tests '*WatchVoiceChoiceViewModelTest'
npm --prefix packages/aiur-mobile test -- test/landing/landOn.test.ts
```

| Test | Expected | Must fail without |
| --- | --- | --- |
| `watchChoiceHasNoDefault` (both platforms) | no row preselected; dismiss starts no capture | the no-default rule |
| `casesMatchFixture` (both platforms) | every `voice-choice-cases.json` row | each mapping |
| `S15_unavailableRowKeepsReason` | unavailable row shown with reason, not hidden | the keep rule |
| `converseIntentOpensSheetNotSession` (only if D-3 = phone) | `landOn` opens the sheet; no audio session | the D16 guard (auto-start Converse → fails) |

Device: V-W2; DV-W5 (dictate), DV-W6 (converse latency, decides D-3).

## Completion and handoff

- [ ] D-3 recorded with DESIGN-N7; the unused branch's rows and test are deleted in the same PR.
- [ ] Each test fails with its hunk reverted in a worktree.
