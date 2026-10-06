---
ticket_id: MP-N4-C4-T03
feature_id: MP-N4
chunk_id: MP-N4-C4
bucket: 3-mobile-watch
title: iOS presentation mapping — title/subtitle/body, thread, category, interruption level
status: blocked
blocked_by: [DESIGN-N4 (D-2, D-3, D-5, D-1), DESIGN-E2 §4.1, MP-N4-C4-T02, OQ-N4-3]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N1, MP-E2]
prior_findings: [E-A7, E-A9]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C4-T03 — iOS presentation mapping

## Identity and outcome

Bucket 3, MP-N4, chunk C4. Map an accepted `ProtectedPayload` to
`UNMutableNotificationContent`: `title`, `subtitle`, `body`, `threadIdentifier`,
`categoryIdentifier`, `interruptionLevel`, `targetContentIdentifier` (destination), and
`userInfo["aiur_destination"]` for the tap handler (MP-N6-C2). Also the in-NSE handling of
`.fallback` (leave original) and `.drop` (empty content if the filtering entitlement is
granted, else a neutral string).

## Dependencies and blockers

**Blocked** — design content decides what is built:
- DESIGN-N4 D-2 (per-kind copy patterns), D-3 (Time Sensitive for blocking Commands),
  D-5 (thread per instance vs per machine), D-1 (fallback copy, used for comparisons).
- DESIGN-E2 §4.1 (title source when `short_label` missing).
- OQ-N4-3 (apply for `com.apple.developer.usernotifications.filtering`, E-A7): decides
  whether `.drop` can suppress display or must show a neutral line.
- C4-T02.

## Verified starting point

- Apple (accessed 2026-10-06): `interruption-level` values passive/active/time-sensitive/
  critical; time-sensitive breaks through Focus and the user can turn it off; `thread-id`
  groups; `target-content-id` selects the scene (E-A9). Filtering entitlement must be
  applied for and requires `apns-push-type: alert` (E-A7).
- Contract v2 §5: no category/thread/interruption level in the clear; set after decrypt.

## Chosen design (fixed parts)

- Fields come only from the decrypted payload; nothing from the clear wrapper.
- `targetContentIdentifier = "aiur://" + machine_id + "/" + instance key + "/" + target`
  (internal scheme owned by N1-C4-T1 route table; exact string agreed there).
- Category ids per kind: `aiur.command`, `aiur.progress`, `aiur.other` — **no actions** in
  v1 (DESIGN-N6: no answering from the banner).
- Pending parts: copy, thread key, interruption level per kind → filled from DESIGN-N4.

## Implementation steps

After approval: `Presentation.swift` (PROPOSED) pure mapper + NSE glue; tests per kind.

## Non-happy paths

- Text longer than the OS truncates: rely on OS truncation (caps already enforced by the
  daemon, contract §3).
- Time Sensitive disabled by the user: the OS downgrades; nothing to handle.

## Compatibility and rollout

Requires the Time Sensitive capability entitlement if D-3 = yes (N1-C6-T1 adds it).

## Verification

XCTest `PresentationTests.swift` (PROPOSED) per kind; unknown-path test: a payload with an
unknown `kind` maps to the `aiur.other` category and neutral copy — must fail if replaced
by the Command mapping. Device: V-I1, V-I5 (Focus/Time Sensitive) in C7.

## Completion and handoff

- [ ] DESIGN-N4 D-1/D-2/D-3/D-5 answers implemented verbatim; screenshots in C7 report.
- Dependents: MP-N4-C7, MP-N6-C2.
