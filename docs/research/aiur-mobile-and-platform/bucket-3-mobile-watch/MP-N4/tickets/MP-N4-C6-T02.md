---
ticket_id: MP-N4-C6-T02
feature_id: MP-N4
chunk_id: MP-N4-C6
bucket: 3-mobile-watch
title: Wear OS bridging — bridge tags and dismissal ids for app-posted notifications
status: blocked
blocked_by: [DESIGN-N4, DESIGN-N7, MP-N4-C5-T03, MP-N4-C5-T04]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N7]
prior_findings: [E-W1]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C6-T02 — Wear OS bridging

## Identity and outcome

Bucket 3, MP-N4, chunk C6. Make the phone-posted (already decrypted) notifications
bridge to a paired Wear OS watch with correct grouping, and make phone-side retraction
dismiss the watch copy: set `setDismissalId` (stream key) and bridge tags per channel;
keep Command notifications bridged, decide per DESIGN-N7 whether progress bridges.

## Dependencies and blockers

- **Blocked on DESIGN-N7 / DESIGN-N4**: which kinds appear on the watch (watch looks).
- C5-T03 (posting), C5-T04 (retraction).
- V-W4 (inline reply on bridged notification, E-W1 UNVERIFIED) is **not** needed: no
  banner answering in v1 (DESIGN-N6).

## Verified starting point

- E-W1: phone notifications bridge by default; `BridgingManager`, bridge tags and
  dismissal ids control it; local-only/ongoing do not bridge
  (developer.android.com/training/wearables/notifications/bridger, updated 2026-09-22).
  Because the phone posts after decrypting, the watch receives readable content; no
  watch-side crypto is needed for bridging.

## Chosen design

Dismissal id = stream key from the payload (`cmd:<id>`, `bo:<root>`); bridge tag per
channel; `setLocalOnly(true)` for any kind DESIGN-N7 excludes.

## Implementation steps

After design: small changes in `Presentation.kt` (C5-T03) + tests.

## Non-happy paths

No watch paired → bridging is a no-op.

## Compatibility and rollout

None beyond C5.

## Verification

Robolectric asserts dismissal id and local-only flags per kind (must fail if dismissal id
is omitted); device V-W3.

## Completion and handoff

- [ ] V-W3 passes. Dependents: MP-N7, MP-N6-C5.
