---
ticket_id: MP-N5-C4-T03
feature_id: MP-N5
chunk_id: MP-N5-C4
bucket: 3-mobile-watch
title: Settings offline, stale, save-conflict and unpaired states
status: blocked
blocked_by: [DESIGN-N5 (§4 states), MP-N5-C4-T01, N1-C5-T1, RQ-TRANSPORT (RC-15)]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N1, MP-N2]
prior_findings: [N5 plan §6, client rule "reachability is separate" (identity-and-capabilities §3 rule 4)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C4-T03 — Settings failure states

## Identity and outcome

Bucket 3, MP-N5, chunk C4. Implement the DESIGN-N5 §4 states on the settings screens:
loading, saving, saved, save conflict (`409` → reload, keep the user's change, ask to
re-apply), instance offline (last-fetched options shown as stale with age, save disabled
for that instance's overrides), machine/gateway unreachable (defaults read-only), device
unpaired (`401 device_revoked` → pairing screen, wipe cached settings for that machine).

## Dependencies and blockers

**Blocked** on DESIGN-N5 §4 state designs; C4-T01; N1-C5-T1 (reachability probe that
distinguishes unreachable / stale / revoked without collapsing causes); RQ-TRANSPORT.

## Verified starting point

C1-T03 error shapes; pairing contract §4.2 (`401 device_revoked`), §9 (gateway offline
shown as "Gateway offline", not "no instances").

## Chosen design (fixed parts)

Stale data always shows its age (AGENTS.md "If a surface computes an age, it renders the
age"); unreachable ≠ unavailable ≠ stale (identity-and-capabilities §3 rule 4).

## Implementation steps

After design approval: state machine in the settings view model + component tests.

## Non-happy paths

This ticket is the non-happy paths.

## Compatibility and rollout

n/a.

## Verification

Component tests per state; mutation: render an offline instance with the live toggle
enabled → `"offline instance disables save"` must fail.

## Completion and handoff

- [ ] Every DESIGN-N5 §4 state has a test. Dependents: C5-T01.
