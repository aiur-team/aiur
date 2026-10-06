---
ticket_id: MP-N6-C5-T02
feature_id: MP-N6
chunk_id: MP-N6-C5
bucket: 3-mobile-watch
title: Watch mic — Dictate/Converse choice on the watch or hand-off to the phone
status: blocked
blocked_by: [DESIGN-N6 D-3 (OQ-N6-3), DESIGN-N7, DESIGN-E5, MP-N6-C5-T01, MP-N7 watch voice (N7-C4)]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N7, MP-E5]
prior_findings: [RQ-N6-1 (watch on-device transcription via client_text, with MP-N7), D16]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C5-T02 — Watch mic

## Identity and outcome

Bucket 3, MP-N6, chunk C5. The watch Mic offers the same explicit Dictate / Converse choice
(D16). Dictate uses the watch system recognizer (client capability model §5 row "Mic →
Dictate (system recognizer, watch)") or the server path per MP-N7; Converse runs on the
watch or hands off to the phone per DESIGN-N6 D-3.

## Dependencies and blockers

**Blocked on DESIGN-N6 D-3 (OQ-N6-3)** — decides whether Converse exists on the watch at
all; plus DESIGN-N7, DESIGN-E5, MP-N7 watch voice (N7-C4).

## Verified starting point

Client capability model §5 watch dictation row; voice-session §3.5 device path.

## Chosen design

Pending D-3.

## Implementation steps

n/a until unblocked.

## Non-happy paths

Recognizer unavailable → Dictate shown unavailable with reason.

## Compatibility and rollout

n/a.

## Verification

When unblocked: `watchChoiceHasNoDefault`; device V-W2.

## Completion and handoff

- [ ] D-3 recorded with DESIGN-N7.
