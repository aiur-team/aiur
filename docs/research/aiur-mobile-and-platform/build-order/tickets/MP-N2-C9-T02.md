---
ticket_id: MP-N2-C9-T02
feature_id: MP-N2
chunk_id: MP-N2-C9
bucket: 3-mobile-watch
title: "Physical-device validation of pairing, discovery, relink, revoke and unpair-all"
status: blocked
blocked_by: [DESIGN-N2, OQ-N1-4, MP-N2-C5-T06, MP-N2-C6-T02, MP-N2-C7-T04, MP-N2-C10-T05, MP-N3-C4-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N1, MP-N3]
prior_findings: []
size_owner: n/a (validation only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C9-T02 — Pairing device validation

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C9.
- **User value:** "pair once per machine, keep working through restarts and address changes, and
  revoke reliably" is shown on real phones, not only in ExUnit.
- **Deliverable:** a results table (rows below × device slots) attached to the PR that closes MP-N2,
  and a ticket filed per failing required row. No production code.

## Dependencies and blockers

Every MP-N2 user-facing ticket; transport validated first (MP-N2-C10-T05 rows TR-1..TR-8 cover ATS,
cleartext, LiveView over HTTPS and certificate renewal — not repeated here); a meta-dashboard build
(MP-N3-C4-T01) to observe discovery; OQ-N1-4 for the device list.

## Verified starting point (base `45a290e3`)

Procedure rules: `bucket-3-mobile-watch/MP-N1/device-validation.md` §4 (record model, OS build, app
build + SHA, aiur version, network path, timestamps; measured latencies with units and counts).

## Chosen design — device slots

| Slot | Exact target (pending OQ-N1-4) |
|---|---|
| iPhone-min | iPhone on iOS 17.x (minimum per D-N1-3) |
| iPhone-cur | iPhone on the current iOS 26.x release |
| Android-cur | Pixel-class phone on Android 13 or later, with Google Play services |
| Second device | Any of the above, for revoke-from-another-device rows |
| Host | One aiur machine with two instances (one started `--no-dashboard`), mobile enabled, transport configured per the owner's choice, reachable over the tailnet and over a LAN |

## Implementation steps (procedure)

| Row | Steps | Pass condition | Required |
|---|---|---|---|
| P1 Pair over tailnet | Phone on cellular with Tailscale on. `aiur mobile qr`; scan; confirm fingerprint matches `aiur mobile status` | Machine appears; both instances listed (the `--no-dashboard` one with "Dashboard off") | Yes |
| P2 Pair over LAN | Second phone on the same Wi-Fi, no overlay; QR from `aiur mobile qr --open` page | Pairs if a LAN endpoint is advertised; otherwise the QR refusal lists the reason — record which | Yes |
| P3 Relink | Re-scan a fresh QR for an already-paired machine | No second row in `aiur mobile devices` | Yes |
| P4 Gateway restart | `aiur mobile gateway stop && aiur mobile gateway start` with the app open | App recovers within one refresh; no re-pair; tokens refreshed | Yes |
| P5 Instance restart | `aiurdev restart` on instance 1 while its dashboard is open in the app | WebView re-bootstraps once silently; no password prompt | Yes |
| P6 IP / endpoint change | Change `gateway.endpoints` (or the tailnet IP) and restart the gateway | App picks up the new endpoints on the next call; if all old ones fail, re-scan relinks without a new row | Yes |
| P7 Crashed instance | `kill -9` the BEAM of instance 2 | Row shows `crashed` with age, never 0 agents as live | Yes |
| R1 Revoke from second device | From device B, revoke device A | A's next request shows "removed from <machine>"; A's local data for the machine is gone (debug screen) | Yes |
| R2 Unpair-all from CLI | `aiur mobile unpair-all` | All phones removed on next request; result shows control done, push pending/complete | Yes |
| R3 Revoke while offline | Airplane-mode device A; revoke it; reconnect | A shows the removed state on first request | Yes |
| L1 Lockout | Submit five bad claims with a test client | Lockout status visible in `aiur mobile status`; legitimate claim refused until it expires | Advisory |

Pairing latency (scan → list visible) is recorded as median and count per slot.

## Non-happy paths

A missing slot is reported as not validated. A failing required row blocks "MP-N2 complete".

## Compatibility and rollout

n/a — validation only.

## Verification

This ticket is verification; evidence is the filled table, `aiur mobile devices --json` before and
after R1–R3, and `journal.ndjson` excerpts (no secrets — verify by grep before attaching).

## Completion and handoff

- [ ] All required rows pass on iPhone-min, iPhone-cur and Android-cur.
- [ ] Results linked from the readiness report.
