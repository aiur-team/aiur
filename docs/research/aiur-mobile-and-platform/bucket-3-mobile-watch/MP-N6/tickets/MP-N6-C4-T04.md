---
ticket_id: MP-N6-C4-T04
feature_id: MP-N6
chunk_id: MP-N6-C4
bucket: 3-mobile-watch
title: OS microphone permission at first press and the cloud-voice disclosure line
status: blocked
blocked_by: [DESIGN-N6, DESIGN-E5 (permission and disclosure placement), MP-N6-C4-T01]
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

**Blocked** on DESIGN-N6 (RC-33) and DESIGN-E5 placement/copy; C4-T01.

## Verified starting point

Voice-session §10 table (normative copy source); capability reports provider (voice-session
§7).

## Chosen design (fixed parts)

- Disclosure text comes from a shared string table generated from voice-session §10, not
  re-written per screen: `packages/aiur-mobile/src/voice/disclosure.ts` exports one entry
  per §10 row, including the Phase D row "System dictation (phone keyboard): audio to
  Apple or Google under their policy; aiur receives text only" (security m10).
- Which line shows is keyed by mode and provider from the capability report (§7):
  Dictate → Dictate row; Converse → Converse row (audio, context and the LLM vendor
  pass-through). Encrypted push is never presented as making voice local.
- Permission is requested on the first option choice only, through the MP-N1 native
  permission module; the result is cached in memory for the session.

## Implementation steps

1. `src/voice/disclosure.ts` (table from §10) and `src/voice/micPermission.ts`.
2. Disclosure line inside `VoiceChoiceSheet` (C4-T01) under each option.
3. Denied → S16 with "Open Settings" (`Linking.openSettings()`); text answering stays.
4. Docs (same PR): `website/docs-app/guide/mobile.md` § "Voice privacy" links the
   voice-session §10 disclosure (or its published docs page).

## Non-happy paths

- Permission "ask every time" (iOS) → treated as granted for the session only.
- Denied → S16; the choice sheet still opens, both options show "Microphone access off".
- Provider unknown in the capability report → the generic "audio leaves this machine"
  line, never "local".

## Compatibility and rollout

Copy placement is DESIGN-E5 (design-pending); the text source is fixed (§10).

## Verification

```text
npm --prefix packages/aiur-mobile test -- test/voice/disclosure.test.ts test/voice/micPermission.test.ts
```

| Test | Expected | Must fail without |
| --- | --- | --- |
| `permissionRequestedOnlyAfterChoice` | no permission call on screen open or sheet open | the lazy request |
| `S16_deniedShowsSettingsLink` | denied → S16 with Settings action; text answering enabled | the denied branch |
| `disclosureShownForElevenLabs` | Converse row names audio, context and the LLM vendor | the table row |
| `disclosureMatchesContractRows` | every §10 row id present in `disclosure.ts` | a row (delete one → fails) |
| `unknownProviderNeverSaysLocal` | unknown provider → generic line | the fallback |

## Completion and handoff

- [ ] Each test fails with its hunk reverted in a worktree.
- [ ] Docs: `website/docs-app/guide/mobile.md` "Voice privacy" (same PR).
