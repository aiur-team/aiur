---
ticket_id: MP-N4-C5-T03
feature_id: MP-N4
chunk_id: MP-N4-C5
bucket: 3-mobile-watch
title: Android channels, notification rendering, POST_NOTIFICATIONS flow and force-stop warning
status: blocked
blocked_by: [DESIGN-N4 (D-1, D-2, D-5, §4 states), DESIGN-E2 §4.1, MP-N4-C5-T02, RQ-N4-9]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N1]
prior_findings: [E-F7, E-F8]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C5-T03 — Android presentation and permission states

## Identity and outcome

Bucket 3, MP-N4, chunk C5. Create the channels (Commands, Progress, Other — DESIGN-N4
§2), map accepted payloads to `NotificationCompat` (title, subtitle as sub-text or
content text per design, group per instance, tag = `nid`, tap `PendingIntent` carrying
the destination to MP-N6-C2), the `POST_NOTIFICATIONS` request flow (Android 13+, E-F8),
reporting `notifications_permitted` to the machine (C5-T05 record field), and the
force-stopped warning (E-F7).

## Dependencies and blockers

**Blocked** on design content: DESIGN-N4 D-1 (fallback copy), D-2 (copy per kind), D-5
(grouping), §4 states (permission denied, force-stopped); DESIGN-E2 §4.1 (title fallback).

**RQ-N4-9 (new):** how the app detects that it was force-stopped. Candidate:
`ApplicationExitInfo.REASON_USER_REQUESTED` via `ActivityManager.getHistoricalProcessExitReasons`
(API 30+) — not verified in Phase C; E-F7 itself is a search summary to be re-read
(platform-evidence.md). The detection method changes code, so it blocks that part.

## Verified starting point

- E-F8: `POST_NOTIFICATIONS` runtime permission from API 33; notifications off by default
  for new installs (developer.android.com, updated 2026-10-01).
- E-F7: force-stopped apps receive no messages until reopened (search summary; re-read).

## Chosen design (fixed parts)

- Channel ids `aiur.commands`, `aiur.progress`, `aiur.other`; importance per DESIGN-N4.
- Permission requested only after pairing, never at first launch (DESIGN-N2/N4 timing).
- No action buttons (DESIGN-N6: no answering from the banner).

## Implementation steps

After unblocking: `Presentation.kt`, `Channels.kt`, permission flow screen hooks (N1
shell), force-stop detector.

## Non-happy paths

- Permission denied: notifications not shown; registration still reports
  `notifications_permitted: false` so the machine shows "phone notifications blocked".
- Channel disabled by user: OS drops; app settings screen shows it (DESIGN-N5 surface).

## Compatibility and rollout

API 33 permission path vs older (no runtime permission).

## Verification

Robolectric tests per kind and per permission state; unknown `kind` → `aiur.other`
(must fail if mapped to Commands). Device: V-A1, V-A4 (force-stop warning), A3 slot
(API 33) in C7.

## Completion and handoff

- [ ] DESIGN-N4 answers applied; RQ-N4-9 evidence recorded.
- Dependents: MP-N4-C7, MP-N5-C4 (permission state surfacing).
