---
ticket_id: MP-N6-C4-T04
feature_id: MP-N6
chunk_id: MP-N6-C4
bucket: 3-mobile-watch
title: OS microphone permission at first press and the cloud-voice disclosure line
status: blocked
blocked_by: [DESIGN-E5 (permission and disclosure placement), MP-N6-C4-T01]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-E5, MP-N1]
prior_findings: [voice-session §10 (normative disclosure source), brief §7 (push encryption ≠ local voice)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C4-T04 — Mic permission and disclosure

## Identity and outcome

Bucket 3, MP-N6, chunk C4. Request the OS microphone permission only at the first Mic →
option choice (never at launch or on notification tap); on denial explain and link to OS
settings while text answering keeps working. In the choice sheet, show the disclosure line
derived from voice-session §10 when the instance's provider is ElevenLabs (audio leaves the
machine; encrypted push does not make voice local).

## Dependencies and blockers

**Blocked** on DESIGN-E5 placement/copy; C4-T01.

## Verified starting point

Voice-session §10 table (normative copy source); capability reports provider (voice-session
§7).

## Chosen design (fixed parts)

Disclosure text comes from a shared string table generated from §10, not re-written per
screen.

## Implementation steps

After approval.

## Non-happy paths

Permission "ask every time" (iOS) → treated as granted for the session only.

## Compatibility and rollout

n/a.

## Verification

`permissionRequestedOnlyAfterChoice` (must fail if requested on screen open);
`disclosureShownForElevenLabs`.

## Completion and handoff

- [ ] Docs: the notifications/voice guide links the §10 disclosure.
