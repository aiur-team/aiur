---
ticket_id: MP-N6-C4-T02
feature_id: MP-N6
chunk_id: MP-N6-C4
bucket: 3-mobile-watch
title: Dictate a Command response over the device voice path, reviewed before Send
status: blocked
blocked_by: [DESIGN-N6, DESIGN-E5 (review-before-send rule), MP-N6-C4-T01, MP-E5-C8-T01, RQ-TRANSPORT (RC-15)]
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

**Blocked** on MP-E5's device voice path (RC-16; voice-session §3.5; ticket
**MP-E5-C8-T01**, Phase D), DESIGN-N6 (RC-33), DESIGN-E5 (review rule, copy), RQ-TRANSPORT (`wss://` vs tailnet
`ws://`, §3.5 item 8), C4-T01.

## Verified starting point

Voice-session contract §3.2 (join), §3.5 (ticket 60 s, salt `device-voice-v1`, writable
gate, two sessions per device, device row re-check every 15 s), §8 error codes.

## Chosen design (fixed parts)

- Transcript never auto-submits (dictation is a single response reviewed before Send);
  raw audio is never stored on the phone (D17). The transcript lands in the custom-response
  field and is counted against the 4,000-character limit (C3-T01).
- `deviceVoiceClient` (this ticket) is the one device voice client: `getTicket()` →
  `POST /api/v1/device/voice-ticket`, `connect(ticket)` → `/voice/device?ticket=…`,
  `join(topic, payload)`, `pushAudio(b64)`, `stop()`, `cancel()`, events as an async
  iterator. C4-T03 reuses it. A ticket is used once (single-use, security m7) and is never
  logged; a reconnect fetches a new ticket.
- An answer sent from dictated text carries `via: "dictate"` and shows the neutral
  "via voice" tag (security m4).
- Errors use voice-session §8.1 through `voiceErrors.ts` (created here if C4-T03 has not
  landed; same fixture `fixtures/contract/voice/end-reasons.json`).

## Implementation steps

1. `packages/aiur-mobile/src/voice/deviceVoiceClient.ts` (ticket, socket, join, frames).
2. `packages/aiur-mobile/src/voice/pcmCapture.ts`: PCM16 mono 16 kHz in 100–200 ms chunks
   (voice-session §2) via the MP-N1 native audio module; buffers released on stop.
3. `packages/aiur-mobile/src/voice/voiceErrors.ts` + fixture (shared with C4-T03).
4. `packages/aiur-mobile/src/commands/DictateSheet.tsx`: recording / transcribing /
   review states; on `stopped`, insert the final text into the response field.
5. Docs (same PR): `website/docs-app/guide/mobile.md` § "Answering a Command by voice"
   (Dictate part).

## Non-happy paths

- `auth_changed` mid-session (device revoked) → end, discard, S12 pairing state.
- Limiter refusal (`capacity`, `session_limit`) → §8.1 copy, Retry later.
- `cost_cap`/`provider_quota` (if STT is ever capped, DESIGN-E5) → no Retry.
- Network loss (`transport_lost`) → stop capture, keep partial text as draft, Retry.
- Mic permission denied → S16 (C4-T04).

## Compatibility and rollout

Behind capability `voice.stt` (C4-T01). Unknown codes → `unknown` row.

## Verification

```text
npm --prefix packages/aiur-mobile test -- test/voice/deviceVoiceClient.test.ts test/commands/DictateSheet.test.tsx
```

| Test | Expected | Must fail without |
| --- | --- | --- |
| `transcriptLandsInFieldNoAutoSubmit` (S02) | final transcript in the field; no C1-T03 call until Send | the review rule (auto-submit → fails) |
| `joinPayloadIsCommandResponse` | join has `surface: "command_response"`, `target.decision_id`, `client.kind: "phone"` | the target pass-through |
| `reconnectFetchesNewTicket` | second connect calls `getTicket` again | single-use ticket |
| `ticketNeverLogged` | logger spy sees no ticket value | the redaction |
| `authChangedGoesToPairing` (S12) | `auth_changed` → pairing state, field cleared | the auth branch |
| `transportLostKeepsPartialText` (S11) | partial text kept, Retry shown | the draft keep |
| `sendCarriesViaDictate` | C1-T03 body has `via: "dictate"` | the via field |

Device: V-N1 run on the device (mic inactive until Dictate).

## Completion and handoff

- [ ] Each test fails with its hunk reverted in a worktree.
- [ ] Docs: `website/docs-app/guide/mobile.md` (same PR).
- Dependents: C4-T03 (reuses `deviceVoiceClient`), C5-T02 (watch reuse).
