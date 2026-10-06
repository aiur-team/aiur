---
ticket_id: MP-N6-C4-T02
feature_id: MP-N6
chunk_id: MP-N6-C4
bucket: 3-mobile-watch
title: Dictate a Command response over the device voice path, reviewed before Send
status: blocked
blocked_by: [DESIGN-E5 (review-before-send rule), MP-N6-C4-T01, MP-E5 device voice path (RC-16), RQ-TRANSPORT (RC-15)]
prior_units: []
prior_boundaries: [mobile-app, VOX #36]
prior_features: [MP-E5, MP-R5]
prior_findings: [voice-session §3.5 (ticket + /voice/device socket), §1 invariants (no raw audio retained, D17)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C4-T02 — Dictate

## Identity and outcome

Bucket 3, MP-N6, chunk C4. After "Dictate": obtain a voice ticket
(`POST /api/v1/device/voice-ticket`), connect `/voice/device?ticket=…`, join
`voice:dictate` with `{v:1, mode:"dictate", surface:"command_response", target, client:
{kind:"phone"}}`, stream audio per the voice-session contract, show the returned
transcript in the custom-response field for review, and submit only on the user's Send
through C1-T03 (`via: "dictate"`).

## Dependencies and blockers

**Blocked** on MP-E5's device voice path (RC-16; voice-session §3.5 defines it, MP-E5 has
not yet ticketed it), DESIGN-E5 (review rule, copy), RQ-TRANSPORT (`wss://` vs tailnet
`ws://`, §3.5 item 7), C4-T01.

## Verified starting point

Voice-session contract §3.2 (join), §3.5 (ticket 60 s, salt `device-voice-v1`, writable
gate, two sessions per device, device row re-check every 15 s), §8 error codes.

## Chosen design (fixed parts)

Transcript never auto-submits (dictation is a single response reviewed before Send);
raw audio is never stored on the phone (D17).

## Implementation steps

After unblocking.

## Non-happy paths

`auth_changed` mid-session (device revoked) → end, discard, pairing state; limiter refusal
→ voice-session §8 code shown; network loss → stop capture, keep partial text as draft.

## Compatibility and rollout

n/a.

## Verification

Integration test against a fake device voice socket: transcript lands in the field and no
answer is posted until Send (must fail if auto-submit); device test on V-N1 run.

## Completion and handoff

- [ ] Dependents: C5-T02 (watch reuse).
