---
ticket_id: MP-N6-C4-T01
feature_id: MP-N6
chunk_id: MP-N6-C4
bucket: 3-mobile-watch
title: Mic button availability and the Dictate / Converse choice sheet on the Command screen
status: blocked
blocked_by: [DESIGN-E5 (mic control, choice sheet), DESIGN-N6 (mic placement), MP-N6-C3-T01, MP-N1-C3-T02, MP-N6-C1-T04]
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
C3-T01; N1-C3-T02 (affordance resolver).

## Verified starting point

Client capability model §5 (Mic rows incl. client reasons `insecure_context`,
`tls_websocket_untrusted`); voice-session contract §3.2 join payload with
`surface: "command_response"`.

## Chosen design (fixed parts)

- The sheet passes `target = {kind: command, instance_id, decision_id, expected_version}`
  (voice-session §5.1) to C4-T02/T03.
- `micAffordance(caps) → {state: ready | unavailable, options: [{mode, state, reason?}]}`
  is a pure function over the MP-N1-C3-T02 resolver output: Dictate from `voice.stt`,
  Converse from `voice.conversation`; Mic is `ready` if either option is `ready` or
  `degraded` (client-capability-model §5). An unavailable option keeps its row with the
  reason (`not_configured`, `not_installed`, `disabled`, `dependency_unavailable`,
  `insecure_context`, `tls_websocket_untrusted`, `unknown`).
- The sheet has **no** preselected option and no default action on dismiss (D16).
- Choosing an option is the only path to an audio session (AC-N6-2).

## Implementation steps

1. `packages/aiur-mobile/src/commands/micAffordance.ts` (pure).
2. `packages/aiur-mobile/src/commands/MicButton.tsx` and `VoiceChoiceSheet.tsx`.
3. Mount in `CommandScreen` (C3-T01) at the slot DESIGN-N6 places.
4. Docs: covered by the C4-T02/T03 guide section (same page, `guide/mobile.md`); this
   ticket adds the "Mic unavailable" reasons list there.

## Non-happy paths

Both options unavailable → Mic shown disabled with the reasons (S15; DESIGN-E5 decides
disabled vs hidden — default disabled per the client model rule "not removed silently").
Text answering keeps working (AC-N6-7). Capabilities `unknown` (older daemon) → option
unavailable with reason `unknown`, never `ready`.

## Compatibility and rollout

Copy and placement are DESIGN-E5 / DESIGN-N6 (design-pending).

## Verification

```text
npm --prefix packages/aiur-mobile test -- test/commands/micAffordance.test.ts test/commands/VoiceChoiceSheet.test.tsx
```

| Test | Expected | Must fail without |
| --- | --- | --- |
| `S15_micDisabledWithReasonWhenVoiceAbsent` (AC-N6-7) | disabled, both reasons listed | the disabled-with-reason branch (remove button or enable → fails) |
| `micReadyIfEitherOptionDegraded` | one degraded option → Mic ready | the either rule |
| `unknownCapabilityIsNotReady` | `unknown` → option unavailable `unknown` | the unknown branch (plausible default `ready` → fails) |
| `choiceSheetHasNoDefault` (D16) | no option preselected; dismiss starts nothing | the no-default rule |
| `noAudioSessionBeforeChoice` (AC-N6-2) | native audio mock untouched until an option is chosen | the gate |
| `targetPassedToVoice` | chosen option receives the Command target and version | the pass-through |

## Completion and handoff

- [ ] Each test fails with its hunk reverted in a worktree.
- Dependents: C4-T02, C4-T03, C4-T04, C5-T02.
