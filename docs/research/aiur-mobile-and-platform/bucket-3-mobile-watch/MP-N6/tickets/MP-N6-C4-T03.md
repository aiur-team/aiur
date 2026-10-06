---
ticket_id: MP-N6-C4-T03
feature_id: MP-N6
chunk_id: MP-N6-C4
bucket: 3-mobile-watch
title: Converse about a Command — MP-E6 session seeded with Command context, confirm-to-answer
status: blocked
blocked_by: [DESIGN-E5, DESIGN-E6, MP-N6-C4-T01, MP-E6 conversation component, MP-E5 device voice path (RC-16), E6-OQ9 (paid ElevenLabs spike), RQ-TRANSPORT (RC-15)]
prior_units: []
prior_boundaries: [mobile-app, VOX #36]
prior_features: [MP-E6, MP-E5]
prior_findings: [voice-session §5.3 (converse delivery: drafts), §10 privacy disclosure]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C4-T03 — Converse

## Identity and outcome

Bucket 3, MP-N6, chunk C4. After "Converse": join `voice:converse` on the device socket
with `surface: "command_response"` and the Command target; the MP-E6 session receives the
Command context; any proposed answer arrives as a **draft** (voice-session §5.3) that the
user confirms in the same response form, then C1-T03 with `via: "converse"`.

## Dependencies and blockers

**Blocked** on MP-E6's conversation component and its provider validation (E6-OQ9 paid
spike), DESIGN-E5/E6, the device voice path (RC-16), RQ-TRANSPORT.

## Verified starting point

Voice-session §5.3 (drafts), §6 (session states), §10 (what leaves the machine).

## Chosen design (fixed parts)

A converse draft is never submitted without explicit confirmation.

## Implementation steps

After unblocking.

## Non-happy paths

Provider unavailable → Converse option unavailable in the sheet (C4-T01) with the reason.

## Compatibility and rollout

n/a.

## Verification

`converseDraftRequiresConfirmation` (must fail if a draft posts automatically).

## Completion and handoff

- [ ] Dependents: MP-N7 (watch converse decision OQ-N6-3).
