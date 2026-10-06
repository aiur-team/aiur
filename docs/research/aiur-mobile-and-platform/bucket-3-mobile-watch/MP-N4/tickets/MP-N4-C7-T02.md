---
ticket_id: MP-N4-C7-T02
feature_id: MP-N4
chunk_id: MP-N4-C7
bucket: 3-mobile-watch
title: Physical-device validation run and dated report (AC-N4-9)
status: blocked
blocked_by: [DESIGN-N4, OQ-N4-1, MP-N4-C2-T06, MP-N4-C7-T01, MP-N4-C4-T03, MP-N4-C4-T04, MP-N4-C5-T03, MP-N4-C5-T04, MP-N4-C6-T01, MP-N4-C6-T02, MP-N5-C3-T03, MP-N6-C3-T02, owner authorization (device-validation-plan.md status line)]
prior_units: []
prior_boundaries: [push-relay, relay service, mobile-app]
prior_features: [MP-N5, MP-N6, MP-N7]
prior_findings: [E-B6, E-F7, E-F9, E-W1, RQ-N4-2..5]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C7-T02 — Physical-device validation run

## Identity and outcome

Bucket 3, MP-N4, chunk C7. Run every scenario in
[device-validation-plan.md](../device-validation-plan.md) §2 on the §1 matrix, fill the
C7-T01 report template, and update platform-evidence.md for every UNVERIFIED item (E-B6,
E-F7, E-F9, E-W1, RQ-N4-2/3/4/5). AC-N4-9 is met only by this report. Includes the 24 h
battery soak and observed latency distributions (no SLA claimed).

## Dependencies and blockers

- **OQ-N4-1** (publisher Apple Developer + Firebase accounts) and C2-T06 (sandbox relay
  with those credentials) — or a self-built app with the operator's own accounts.
- Owner authorization: the plan states running it "is a separately authorized experiment".
- Physical devices of the §1 matrix.
- Every presentation/retraction ticket and the N5/N6 pieces the scenarios exercise.

## Verified starting point

device-validation-plan.md (status: plan — not run).

## Chosen design

Follow the plan verbatim; any failed scenario blocks MP-N4 completion until the plan is
changed and re-run (plan §3).

## Implementation steps

1. External port scan of the machine's public IP (no inbound route).
2. Run scenarios per network setup N-a…N-d; record per C7-T01 template.
3. Update platform-evidence.md and the MP-N4 plan open questions.

## Non-happy paths

A device missing from the matrix → record "not covered" explicitly; never infer from a
simulator.

## Compatibility and rollout

n/a.

## Verification

The report itself; reviewer checks that every §2 row has a result and evidence.

## Completion and handoff

- [ ] Report committed next to the plan with date, sample sizes, devices.
- [ ] UNVERIFIED items resolved one way or the other (AC-N4-9).
