---
ticket_id: MP-N6-C3-T02
feature_id: MP-N6
chunk_id: MP-N6-C3
bucket: 3-mobile-watch
title: Phone outcome states and the Replace flow (D11)
status: blocked
blocked_by: [DESIGN-N6 (§3 outcome states, §5), DESIGN-E2 §4.4 (outcome copy), MP-N6-C3-T01, MP-N6-C1-T03]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-E2]
prior_findings: [N6 plan §5.2 outcome table, D11]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C3-T02 — Outcome states and Replace

## Identity and outcome

Bucket 3, MP-N6, chunk C3. Map every C1-T03 outcome to a phone state: accepted →
delivering → delivered (live, C6-T01); `duplicate` → same as original; `already_decided`
→ who/when/what, with **Replace** only when `replaceable` (confirmation per DESIGN-N6
§3); `answer_in_flight` → "Delivering now — can't replace"; `answer_delivered` → as
already decided without Replace; `stale_version` → reload, keep draft/selection if option
ids still exist; `withdrawn` → "No longer needed: <status>", form disabled;
`idempotency_conflict` → error, no auto-retry; `401 device_revoked` → pairing screen and
wipe cached data for that machine; typed capability errors (C1-T04) → "answer from the
dashboard" state.

## Dependencies and blockers

**Blocked** on DESIGN-E2 §4.4 copy and DESIGN-N6 placement and Replace confirmation;
C3-T01; C1-T03.

## Verified starting point

C1-T03 outcome table (HTTP + body); command contract §6 rules 1–5.

## Chosen design (fixed parts)

Replace sends `replace: true` with a **new** idempotency key and the current
`expected_version`.

## Implementation steps

After approval.

## Non-happy paths

This ticket is the non-happy paths of submission.

## Compatibility and rollout

Unknown `reason` from a newer daemon → generic conflict state + refresh (never treated as
success).

## Verification

Component test per outcome; unknown-reason test must fail if mapped to `accepted`;
device V-M2, V-M3.

## Completion and handoff

- [ ] Dependents: MP-N4-C7-T02 (V-M1..V-M3).
