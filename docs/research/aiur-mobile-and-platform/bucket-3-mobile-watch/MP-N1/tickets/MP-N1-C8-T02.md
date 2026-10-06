---
ticket_id: MP-N1-C8-T02
feature_id: MP-N1
chunk_id: MP-N1-C8
bucket: 3-mobile-watch
title: "Privacy disclosures: App Store privacy details and manifest, Play Data safety, in-app privacy text separating push privacy from cloud voice"
status: blocked
blocked_by: [DESIGN-N1, OQ-N1-1, MP-N4-C3-T06, MP-E6-C2-T2, MP-N1-C6-T01, MP-N1-C5-T02]
prior_units: []
prior_boundaries: [SITE]
prior_features: [MP-N4, MP-E5, MP-E6, MP-N7]
prior_findings: []
size_owner: n/a (docs and metadata)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C8-T02 — Privacy disclosures

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C8.
- **User value:** the operator (and any store reviewer) reads an accurate statement of what leaves
  the phone and to whom: encrypted push through Apple/Google and the relay, versus opted-in cloud
  voice processing (ElevenLabs, or Apple/Google system dictation on watches). Brief §7 forbids
  presenting encrypted push as "all voice processing is local".
- **Deliverable:**
  1. `packages/aiur-mobile/ios/PrivacyInfo.xcprivacy` content (via config plugin) for the app and
     the NSE target, declaring no tracking and listing any required-reason APIs actually used
     (e.g. `UserDefaults`, file timestamps) — determined by an inventory of the built app.
  2. A disclosures matrix `packages/aiur-mobile/docs/privacy-matrix.md` (PROPOSED): one row per
     data flow (pairing, device token, sealed push payload, relay routing metadata per MP-N4,
     dashboard traffic, server STT via the machine, MP-E6 conversation provider, watch system
     dictation), with who can read it.
  3. Store answers derived from the matrix: App Store privacy details; Play Data safety (only if
     distributed beyond internal testing).
  4. In-app "Privacy" screen text (DESIGN-N1 copy) rendering the same matrix.
- **Non-goals:** legal privacy policy hosting (owner decision under OQ-N1-1).

## Dependencies and blockers

- OQ-N1-1 (which stores and tracks); MP-N4-C3-T06 (privacy tests define what the relay sees);
  MP-E6-C2-T2 (conversation provider adapter: what reaches the provider); MP-N1-C6-T01;
  MP-N1-C5-T02 (ATS justification text, if the degraded mode exists).

## Verified starting point (base `45a290e3`)

- Brief §7 and contract `notification-destination-and-payload.md` (MP-N4) define relay visibility.
- Google Play Data safety (accessed 2026-10-06,
  <https://support.google.com/googleplay/android-developer/answer/10787469>): all apps on Play
  must complete it, "including apps on closed, open, or production testing tracks"; apps only on
  internal testing are exempt. Data that is "end-to-end encrypted" so that no intermediary can read
  it, or processed ephemerally, need not be declared as collected.
- Apple privacy manifests: `PrivacyInfo.xcprivacy`
  (<https://developer.apple.com/documentation/bundleresources/privacy-manifest-files>, accessed
  2026-10-06; the page body did not render in the research tool, so the exact required-reason
  categories are **UNVERIFIED** here and must be read from Xcode's privacy report at implementation).

## Chosen design

- Single source of truth: the matrix. Store answers and the in-app screen are generated from it by
  hand review, and a test asserts the in-app text and the matrix list the same flows.
- Push: declared as end-to-end encrypted to the device for content; routing metadata (device
  token, timing, size) declared as visible to the relay operator and Apple/Google.
- Voice: declared per provider and only when the user enables it; raw audio is not retained (D17).

## Implementation steps

Matrix file, privacy screen, plist plugin, store answer worksheet in the runbook. About 80 lines of
code plus docs.

## Non-happy paths

A new data flow added later without a matrix row → the test below fails when the flow's module
registers a `privacyFlow` id that the matrix lacks.

## Compatibility and rollout

Docs and metadata; no runtime change except the Privacy screen.

## Verification

Jest `src/screens/privacy/__tests__/privacyMatrix.test.ts`: every registered `privacyFlow` id
(pairing, push, voice_server, voice_conversation, watch_dictation) has a matrix row and an
in-app paragraph (mutation: delete the voice row → fails). Manual: Xcode "Generate Privacy Report"
on the archive from MP-N1-C8-T01 matches the manifest; record it.

```bash
npm --prefix packages/aiur-mobile test -- src/screens/privacy
```

## Completion and handoff

- [ ] Matrix reviewed against MP-N4 and MP-E6 owners; store answers recorded in the runbook.
- [ ] Docs: mobile guide "Privacy" page (from the matrix).
