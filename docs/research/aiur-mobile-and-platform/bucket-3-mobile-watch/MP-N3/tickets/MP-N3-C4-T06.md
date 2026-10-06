---
ticket_id: MP-N3-C4-T06
feature_id: MP-N3
chunk_id: MP-N3-C4
bucket: 3-mobile-watch
title: "Physical-device validation of the meta-dashboard (DV-P5 states, navigation, offline cache)"
status: blocked
blocked_by: [DESIGN-N3, MP-N3-C4-T01, MP-N3-C4-T02, MP-N3-C4-T03, MP-N3-C4-T04, MP-N3-C4-T05, MP-N2-C10-T05, OQ-N1-4]
prior_units: []
prior_boundaries: []
prior_features: [MP-N1, MP-N2]
prior_findings: []
size_owner: n/a (validation only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C4-T06 — Meta-dashboard device validation

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C4.
- **User value:** the instance list is proven truthful on real phones and real networks.
- **Deliverable:** a results table (rows MD-1..MD-7 per slot) in the PR, failures filed with row IDs.
- **Non-goals:** transport rows (MP-N2-C10-T05), push rows (MP-N1 DV-P1–P4).

## Dependencies and blockers

All MP-N3-C4 tickets; transport validated (MP-N2-C10-T05); OQ-N1-4 (devices).

## Verified starting point (base `45a290e3`)

Procedure rules: `bucket-3-mobile-watch/MP-N1/device-validation.md` §4 (record device model, OS
build, app SHA, aiur version, network path, timestamps; latency as median and count).

## Chosen design — slots and rows

Slots (pending OQ-N1-4): **iPhone-min** iOS 17.x; **iPhone-cur** current iOS 26.x;
**Android-cur** Pixel-class Android 13+ with Play services; **Host A** and **Host B** two aiur
machines (B may be a second OS user or a VM), each paired.

| Row | Steps | Pass |
|---|---|---|
| MD-1 | Host A: two instances live; Host B: one live, one `--no-dashboard`; open the app | All four rows; B's second row shows "dashboard off" reason |
| MD-2 | `kill -9` one instance's BEAM on A | Row becomes `crashed` within one poll; not counted in totals |
| MD-3 | Turn the phone's tailnet off | Both machines `unreachable` with last-seen ages; no zeros (DV-P5) |
| MD-4 | Stop the gateway on B (`aiur mobile gateway stop`) | B shows "gateway offline"; A unaffected |
| MD-5 | `aiurdev pause` on one instance | Row shows paused, not 0 active |
| MD-6 | Revoke this phone from A (`aiur mobile revoke <id>`) | Removed notice once; A's rows and cache gone (debug screen) |
| MD-7 | Tap a live row, then the Executor-chat button (if MP-E3 shipped) | Dashboard opens without a password; chat opens; Back returns |

## Implementation steps

Run the rows on each slot; fill the table; file failures.

## Non-happy paths

Missing slot → "not validated on <slot>" in the readiness report.

## Compatibility and rollout

n/a — validation only.

## Verification

This ticket is verification; evidence = table + screenshots of MD-3 and MD-5.

Mutation check: **n/a** — this ticket adds no production hunk and no automated test; the
rows are manual device checks. Docs: **none** — it changes no user-facing surface; the evidence
lives in the PR and the readiness report.

## Completion and handoff

- [ ] MD-1..MD-7 pass on iPhone-min, iPhone-cur and Android-cur.
- [ ] MP-N3 AC1–AC8 checked off in the feature plan.
