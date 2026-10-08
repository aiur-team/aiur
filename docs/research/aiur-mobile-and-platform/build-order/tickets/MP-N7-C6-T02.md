---
ticket_id: MP-N7-C6-T02
feature_id: MP-N7
chunk_id: MP-N7-C6
bucket: 3-mobile-watch
title: Wear OS physical-device validation (DV-W2..W8, W12, W13 Wear columns)
status: blocked
blocked_by: [DESIGN-N7, OQ-N1-4, MP-N7-C3-T03, MP-N7-C3-T04, MP-N7-C4-T02, MP-N7-C4-T05, MP-N4-C5-T02, MP-N4-C6-T02, MP-N2-C10-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N1, MP-N4]
prior_findings: ["MP-N1 device-validation.md §3", "MP-N4 V-W3, V-W4"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C6-T02 — Wear OS device validation

## Identity and outcome

- Bucket 3, MP-N7, chunk C6. Wear twin of MP-N7-C6-T01; same report format
  (`…/validation/<date>-wear-os.md`).
- **Non-goals:** iPhone-paired Wear watches (out of scope, S32/S38).

## Dependencies and blockers

C3-T03/T04, C4-T02, C4-T05 builds; MP-N4-C5-T02 (FCM service); MP-N4-C6-T02 (bridge tag
and dismissal id on phone notifications); MP-N2-C10-T01; OQ-N1-4. Skipped entirely if
DESIGN-N7 D-N7-6 defers Wear OS (recorded as "deferred", not "passed").

## Verified starting point

Bridging, dismissal ids and "open on phone" facts as cited in MP-N7-C3-T04
(<https://developer.android.com/training/wearables/notifications/bridger>,
<https://developer.android.com/training/wearables/notifications>, both updated 2026-09-22).
Network proxying: "When a watch has a Bluetooth connection to a phone, the watch's network
traffic is generally proxied through the phone" and the page does not discuss VPNs
(<https://developer.android.com/training/wearables/data/network-access>, updated 2026-09-22).

## Chosen design — device matrix (exact)

| Slot | Device | OS | Purpose |
|---|---|---|---|
| Android A | Pixel 8 or later (record model), Google Play services | current Android release (record build) | primary |
| Android M | any Android phone on **Android 13 (API 33)** with Play services | Android 13 | `POST_NOTIFICATIONS` + minimum rerun of W4, W7 |
| Wear A | Pixel Watch 2 or 3 (or Galaxy Watch on Wear OS 5+), paired to Android A | **Wear OS 5 or later** (record build) | all rows |
| aiur machine | as MP-N7-C6-T01 | — | — |

## Rows and procedures

| ID | Procedure | Pass | Req. |
|---|---|---|---|
| DV-W2 (Wear) | Phone app swiped away from recents for 10 min; open Wear app; tap a Command | Card loads via `MessageClient.sendRequest`/RPC service. Record median/max latency over 20 tries; record whether the phone process was started (logcat `ActivityManager: Start proc`) | Yes |
| DV-W3 (Wear) | Turn phone Bluetooth off | "Needs phone" with age; writes disabled | Yes |
| DV-W4 (Wear) | Choose an option | One answer, `client.surface: "watch"` | Yes |
| DV-W5 (Wear) | Dictate via `RecognizerIntent` | Review before Send; one answer | Yes |
| DV-W6 (Wear) | Converse, 5 sessions × 5 turns | Latency figures as in C6-T01 | Yes |
| DV-W7 | Command notification with the Wear app installed (C3-T04 flag on) | Exactly **one** notification on the watch (the Wear-local one, not a bridged duplicate); tap opens the Wear card. Verifies that `BridgingConfig` from a non-standalone app is honoured | Yes |
| DV-W7b | Dismiss on the watch; then (new Command) resolve on the dashboard | Watch dismissal dismisses the phone copy (dismissal id); dashboard resolution removes both (via `notify_cancel` + phone removal) | Yes |
| DV-W7c | Uninstall the Wear app; send a Command | Phone notification bridges (default) with the "open on phone" button | Yes |
| DV-W8 | Phone powered off | Wear app shows "Needs phone" (non-standalone). **Advisory (N7-RQ5):** with phone on and Tailscale VPN active on the phone, from a debug build on the watch make one HTTPS request to the tailnet daemon address and record success/failure — informs only a future standalone path | Yes / advisory part |
| DV-W12 (Wear) | Inspect app storage (`adb shell run-as <pkg> ls cache files`) on watch and phone after voice rows | No turn or reply audio files | Yes |
| DV-W13 (Wear) | Tile update after a count change | Record seconds | Advisory |

## Implementation steps

1. Prepare devices; install Play internal-testing builds (phone + Wear).
2. Run rows in order; `adb logcat` captured per row for W2/W7.
3. Report + filed failures; set the C3-T04 flag default from DV-W7/W7b.

## Non-happy paths

DV-W7 failure → C3-T04 flag default off (bridging fallback) and a DESIGN-N7 note; not an
improvised alternative.

## Compatibility and rollout

n/a — validation only.

## Verification

The report is the verification. Mutation check n/a.

## Completion and handoff

- [ ] Report with every row; N7-RQ2 device parts and N7-RQ5 advisory recorded in plan §12.
- Dependents: MP-N7-C3-T04 flag default; MP-N4-C7 links V-W3/V-W4 results here.
