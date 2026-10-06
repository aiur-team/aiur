---
ticket_id: MP-N6-C4-T01
feature_id: MP-N6
chunk_id: MP-N6-C4
bucket: 3-mobile-watch
title: Mic button availability and the Dictate / Converse choice sheet on the Command screen
status: blocked
blocked_by: [DESIGN-E5 (mic control, choice sheet), DESIGN-N6 (mic placement), MP-N6-C3-T01, N1-C3-T2, MP-N6-C1-T04]
prior_units: []
prior_boundaries: [mobile-app, VOX #36]
prior_features: [MP-E5, MP-E6, MP-N1]
prior_findings: [D16, client-capability-model §5 (Mic button ready if either option is ready/degraded)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C4-T01 — Mic button and choice sheet

## Identity and outcome

Bucket 3, MP-N6, chunk C4. Place the Mic button on the phone Command screen; its state
comes from the client capability model (`voice.stt` for Dictate, `voice.conversation` for
Converse; Mic is `ready` if either resolves to `ready`/`degraded`, client-capability-model
§5). Pressing it always opens the choice sheet with **both** options and no default (D16);
an unavailable option is shown with its reason, never hidden. Nothing records until an
option is chosen (AC-N6-2).

## Dependencies and blockers

**Blocked** on DESIGN-E5 (normative mic control and choice sheet) and DESIGN-N6 placement;
C3-T01; N1-C3-T2 (affordance resolver).

## Verified starting point

Client capability model §5 (Mic rows incl. client reasons `insecure_context`,
`tls_websocket_untrusted`); voice-session contract §3.2 join payload with
`surface: "command_response"`.

## Chosen design (fixed parts)

The sheet passes `target = {kind: command, decision_id, version}` (voice-session §5.1) to
C4-T02/T03.

## Implementation steps

After approval.

## Non-happy paths

Both options unavailable → Mic shown disabled with the reasons (DESIGN-E5 decides disabled
vs hidden; default disabled per client model rule "not removed silently"). Text answering
keeps working (AC-N6-7).

## Compatibility and rollout

n/a.

## Verification

`micDisabledWithReasonWhenVoiceAbsent` (AC-N6-7; must fail if the button is removed or
shown enabled), `choiceSheetHasNoDefault`, `noAudioSessionBeforeChoice` (AC-N6-2).

## Completion and handoff

- [ ] Dependents: C4-T02, C4-T03, C4-T04, C5-T02.
