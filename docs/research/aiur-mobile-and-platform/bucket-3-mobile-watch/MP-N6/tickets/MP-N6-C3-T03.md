---
ticket_id: MP-N6-C3-T03
feature_id: MP-N6
chunk_id: MP-N6-C3
bucket: 3-mobile-watch
title: Unreachable/offline Command screen — sealed summary, draft retention, manual Retry
status: blocked
blocked_by: [DESIGN-N6 (D-1 / OQ-N6-1, unreachable state), MP-N6-C3-T01, N1-C5-T1, RQ-TRANSPORT (RC-15)]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N1, MP-N4]
prior_findings: [AC-N4-6, V-R3, V-R4]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C3-T03 — Unreachable and offline

## Identity and outcome

Bucket 3, MP-N6, chunk C3. When the instance cannot be reached (machine offline, tailnet
off, transport error), show the sealed summary from the notification plus "Can't reach
<machine>" and Retry; keep the draft (text, selected option, idempotency key) on device;
do **not** queue the answer for automatic later send unless DESIGN-N6 D-1 says so.

## Dependencies and blockers

**Blocked on DESIGN-N6 D-1 (OQ-N6-1)**: "queue offline answers for later automatic send?"
changes what is built (a durable client outbox and its staleness handling) — proposal is
"no". Also N1-C5-T1 (reachability classification: unreachable vs revoked vs TLS mismatch
without collapsing causes) and RQ-TRANSPORT.

## Verified starting point

MP-N4 AC-N4-6, V-R3, V-R4; pairing contract §9 (machine unreachable → last-known with age).

## Chosen design (fixed parts, valid for D-1 = no)

Draft stored in the app's encrypted storage keyed by `(instance_id, decision_id)`; Retry
re-fetches the view first (the Command may have resolved) and only then offers Send.

## Implementation steps

After D-1.

## Non-happy paths

Draft older than the Command's `expires_at` → discarded with a note.

## Compatibility and rollout

n/a.

## Verification

Component tests: draft survives app restart; Retry re-fetches before submitting (must fail
if Retry submits directly). Device V-R3, V-R4.

## Completion and handoff

- [ ] D-1 recorded.
