---
ticket_id: MP-N7-C6-T01
feature_id: MP-N7
chunk_id: MP-N7-C6
bucket: 3-mobile-watch
title: Apple Watch physical-device validation (DV-W1..W6, W9..W13)
status: blocked
blocked_by: [DESIGN-N7, OQ-N1-4, MP-N7-C2-T04, MP-N7-C2-T03, MP-N7-C4-T02, MP-N7-C4-T05, MP-N1-C6-T01, MP-N4-C6-T01, MP-N2-C10-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N1, MP-N4, MP-N6]
prior_findings: ["MP-N1 device-validation.md §3", "MP-N4 device-validation-plan V-W1..V-W2"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C6-T01 — Apple Watch device validation

## Identity and outcome

- Bucket 3, MP-N7, new chunk C6 (watch device validation; split out of the per-chunk "DV"
  references so the run has one owner and one report).
- **User value:** the watch behaviour is proven on real hardware, not on the simulator,
  which always allows networking (TN3135, S7) and cannot reproduce notification forwarding.
- **Deliverable:** a dated report `bucket-3-mobile-watch/MP-N7/validation/<date>-apple-watch.md`
  (in the implementation repo at that time) with one table row per DV ID below: device
  model, OS build, app build + git SHA, daemon version, network path, timestamps, result,
  measured figures with units and counts (AGENTS.md "A claimed saving must be measured").
  Failures are filed as tickets carrying the DV ID. MP-N7 is not "complete" while a required
  row fails or was not run.
- **Non-goals:** phone-only rows (MP-N1 DV-P*, MP-N4 V-*). Overlap with MP-N4 V-W1/V-W2 is
  resolved by running them once here and linking the result from MP-N4-C7
  (CONTRACT-REQUESTS item 5).

## Dependencies and blockers

Builds from C2-T03/T04, C4-T02, C4-T05; MP-N1-C6-T01 (NSE); MP-N4-C6-T01; transport
(MP-N2-C10-T01). **OQ-N1-4** lists the devices the owner actually has.

## Verified starting point

Plan and matrix: `../MP-N1/device-validation.md` §1 and §3 (DV-W1..W9). Facts used:
forwarding rules (MP-N4 E-B1); `sendMessage` wakes the iOS app (S6); WebSockets blocked
on watchOS outside listed cases (S7, revised 2026-07-16); force-quit apps are not relaunched
for background pushes (S41).

## Chosen design — device matrix (exact)

| Slot | Device | OS | Purpose |
|---|---|---|---|
| iPhone A | iPhone 15 or later (record model) | iOS 26.x current release (record build) | primary |
| iPhone M | any iPhone on **iOS 17.x** (minimum, D-N1-3) | iOS 17.x latest | minimum-OS rerun of DV-W1, W2, W4 |
| Watch A | Apple Watch Series 9 / Ultra 2 or later, paired to iPhone A | watchOS 26.x current (record build) | all rows |
| Watch M | any Apple Watch on **watchOS 10.x**, paired to iPhone M | watchOS 10.x | minimum rerun of DV-W1, W2, W4 |
| aiur machine | one host, two instances, HTTPS per RQ-TRANSPORT, reachable over the tailnet | — | reachability |

A missing slot is reported as "not validated on <slot>", never skipped silently.

## Rows and procedures

| ID | Procedure (numbered) | Pass | Req. |
|---|---|---|---|
| DV-W1 | 1. Pair app; 2. lock iPhone, watch on wrist and unlocked; 3. on the machine create a blocking Command; 4. observe watch | **Revised (Phase D feasibility M5).** Pass = the watch shows the **decrypted** short summary, **or** it shows the uniform fallback and its default action opens the right Command card in one tap through the phone (`get_command {latest_notified}`, MP-N7-C2-T04). Record which (E-B6). Fail = neither (no card, or a wrong card) → triggers MP-N7 plan §7 option (b), conditional chunk N7-RQ4. | Yes |
| DV-W1b | Continue DV-W1: tap the notification on the watch | Card for the right instance/Command opens in ≤ 2 taps; no mic indicator appears (orange mic dot absent) | Yes |
| DV-W2 | 1. Background the iPhone app (home screen, wait 10 min); 2. open the watch app, tap a Command | Card loads via `sendMessage` wake. Record latency: median and max over 20 tries (s). | Yes |
| DV-W2b | Force-quit the iPhone app (app switcher swipe), repeat DV-W2 ×5 | Record whether the card loads; if not, the watch shows "Not confirmed / Needs iPhone" (no hang > 15 s) | Yes |
| DV-W3 | Walk the iPhone out of Bluetooth range (or turn Bluetooth and Wi-Fi off on iPhone) | List shows stored data with age and "Needs iPhone nearby"; answer/voice disabled | Yes |
| DV-W4 | Choose an option on the watch | Exactly one answer recorded (`aiur commands <id> --json` shows one action, `client.surface: "watch"`) | Yes |
| DV-W4b | Late answer (the deliberate queued-answer exception, plan §8, feasibility m6): put iPhone in Airplane mode, choose an option (watch queues), change the Command on the machine (revise), wait 11 min, restore iPhone | Answer is **not** submitted; watch shows "stale" (C1-T04) | Yes |
| DV-W5 | Dictate: mic → Dictate → speak 2 sentences → review → Send | Text shown for review before Send; one answer with `custom_response`; record recognizer path (system / relay) | Yes |
| DV-W6b | During watch Converse: (1) restart the daemon; (2) set `voice.conversation.daily_minutes_cap` low and reach it; (3) revoke the phone | (1) `transport_lost` copy with Retry, transcript intact; (2) `cost_cap` copy, **no** Retry offered; (3) `auth_changed` / unpaired copy. Copy matches the `voice/end-reasons.json` fixture rows (M7) | Yes |
| DV-W6 | Converse: 5 turns of ~5 s speech | Record end-of-speech → reply-start latency per turn (median, max, n=5 sessions × 5 turns) for real-time pacing and, in a debug build, fast pacing (RQ-N7-6); compare with D-N7-3 | Yes |
| DV-W9 | Debug build with a test button that opens `URLSessionWebSocketTask` to the daemon from the watch | Task stays `.waiting` on device (S7) — guards against simulator-only designs | Yes |
| DV-W10 | With DV-W1 conditions and the C2-T06 debug flag on: expand long-look | Per-Command option buttons appear with the payload's labels; tapping one records one answer (N7-RQ1 forwarded part) | Yes if C2-T06 is wanted |
| DV-W11 | With a forwarded notification on the watch, answer the Command on the dashboard | Record whether the watch copy is removed when iPhone removes its copy (N7-RQ3). If not removed, file a ticket against MP-N6-C6 for a watch-side cleanup on next snapshot | Yes (record) |
| DV-W12 | After DV-W5 (relay variant) and DV-W6: inspect watch container (Xcode Devices → Download Container) and phone container | No `aiur-turn-*` or reply audio file remains (D17) | Yes |
| DV-W13 | Change blocking count on the machine with the phone app foregrounded | Complication updates within one snapshot; record seconds | Advisory |

## Implementation steps

1. Prepare devices per matrix; install TestFlight internal build.
2. Seed Commands with `aiur` CLI on the machine (no live agents needed; use the MP-N3-C5
   fixture gateway where only list data is needed).
3. Run rows in order; capture screenshots/video for W1, W1b, W3, W10, W11.
4. Write the report table; file failures.

## Non-happy paths

A row that cannot be run (missing device) is recorded with the reason. A row result that
differs between watchOS 26 and 10 is recorded per OS, not merged.

## Compatibility and rollout

n/a — validation only.

## Verification

This ticket *is* verification; its acceptance is the report. Mutation check n/a (no code).

## Completion and handoff

- [ ] Report committed with every row filled; required failures filed.
- [ ] E-B6 (MP-N4), N7-RQ1 (forwarded part), N7-RQ3, RQ-N7-6 updated from results in
  plan.md §12 and MP-N4 platform-evidence (via coordinator).
- Dependents: MP-N7-C2-T06 (needs DV-W10), MP-N4-C6-T01 decision.
