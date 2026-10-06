---
ticket_id: MP-N5-C4-T01
feature_id: MP-N5
chunk_id: MP-N5-C4
bucket: 3-mobile-watch
title: Phone notification settings — machine defaults, per-instance overrides, unavailable reasons
status: blocked
blocked_by: [DESIGN-N5 (surfaces §2, D-7 wording, D-8), DESIGN-N1, DESIGN-N3, MP-N5-C1-T03, N1-C4-T1, N1-C3-T2, RQ-TRANSPORT (RC-15)]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N1, MP-N3]
prior_findings: [capability-matrix rule 1, AC-N5-7]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C4-T01 — Settings screens

## Identity and outcome

Bucket 3, MP-N5, chunk C4. Phone screens (native per MP-N1 surface boundary, since
settings are a native surface there) for: machine-level notification defaults, the
per-instance override screen (reached from the instance, DESIGN-N3), the progress step
picker (off / 10 / 25 / 50 %) and completion toggle, the opt-in list, and "unavailable"
rows (disabled control + reason + optional "how to enable") driven by the
`notification-options` API (C1-T03). Saves via the gateway `PATCH` with
`expected_version`.

## Dependencies and blockers

**Blocked on DESIGN-N5 content**: every surface in its §2, option wording and reason copy
(D-7), whether queue milestones get their own toggle (D-8). Also DESIGN-N1 (native vs
WebView), DESIGN-N3 (entry point), N1-C4-T1 (navigation), N1-C3-T2 (affordance resolver),
C1-T03 (API), RQ-TRANSPORT (the phone must reach gateway and instances).

## Verified starting point

No mobile code at `45a290e3`. API contract: C1-T03. Capability affordance rules:
`contracts/client-capability-model.md` (MP-N1 owns).

## Chosen design (fixed parts)

- Unavailable options are rendered from `state: unavailable` + `reason` — never as a
  working toggle and never as "off" (AC-N5-7).
- Machine defaults are saved through the gateway; per-instance overrides also go through
  the gateway (single writer) — the instance API is read-only.

## Implementation steps

After DESIGN-N5: screens, view models, API client (typed, from `aiur-contracts`).

## Non-happy paths

Covered in C4-T03 (offline, stale, conflict).

## Compatibility and rollout

Unknown option ids from a newer daemon are ignored (N5 plan §6).

## Verification

Component tests per state; unknown-path mutation: replace the `unavailable` row with an
`off` toggle and the test `"build orders absent shows disabled row with reason"` must fail
(AC-N5-7). Device: settings round-trip on V-PR1 run (MP-N4-C7).

## Completion and handoff

- [ ] DESIGN-N5 approved screens implemented. Dependents: C4-T02, C4-T03, C5-T01.
