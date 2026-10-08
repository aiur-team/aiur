---
ticket_id: MP-R5-C4-T01
feature_id: MP-R5
chunk_id: MP-R5-C4
bucket: 1-refactor
title: Docs — voice responsibilities (capture, transport, transcription, delivery) and the cloud-processing statement
status: blocked
blocked_by: [DESIGN-R5]
prior_units: []
prior_boundaries: ["VOX #36"]
prior_features: [integrations-51, ui-07, ui-08]
prior_findings: []
size_owner: n/a (apis/elevenlabs.md is 57 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R5-C4-T01 — Docs: voice responsibilities and cloud processing

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R5 / C4.
- **User value:** the operator can see which part of aiur captures,
  transports, transcribes and delivers speech. The operator can also see that
  transcription is **cloud** processing by ElevenLabs. Brief §7 requires that
  private access and encrypted push are never presented as "voice is local".
- **Deliverable:** edits to `website/docs-app/apis/elevenlabs.md`, plus at most a
  link from `website/docs-app/guide/stream-deck.md` § Where your voice goes
  (`:203`).
- **Non-goals:**
  - converse-mode disclosure (that is MP-E6, contract §10);
  - documenting the internal `Aiur.Voice` module names. This is an operator
    page.

## Dependencies and blockers

- **Blocked by:** DESIGN-R5, which confirms that no user-facing behaviour
  changes. The copy below describes current behaviour only.
- **Not blocked by C1:** the page states behaviour, not module names, so it can
  land before or after C1.
- **May run concurrently with:** every other MP-R5 ticket and MP-R3/R4/R6 docs
  tickets (different pages).

## Verified starting point (base `45a290e3`)

`website/docs-app/apis/elevenlabs.md` (57 lines) has these sections:

- "What voice does" (`:5-12`), including "Aiur holds the credential and makes
  every ElevenLabs call" (`:12`);
- "API key permissions" (`:14-22`);
- "Configure the key" (`:24-33`);
- "What the Units meter measures" (`:35-46`);
- "Privacy and secret handling" (`:48-55`).

`:52` says dictation audio "goes to ElevenLabs". The page has **no
capture/transport/delivery table**, and it does not say that a human presses
Send before text reaches an agent.

`website/tests/gui-docs.spec.ts:246-250` asserts these strings: `Speech to
Text`, `` `User` ``, `Text to Speech`, `audio-minute` and `character pool`.
All must survive.

Facts for the table, with evidence:

| Stage | Fact | Evidence |
| --- | --- | --- |
| Capture | Browser AudioWorklet or the deck sidecar's `parec`, 16 kHz mono PCM16; mic only while held or recording | `src/priv/static/conversation-voice-controller.js`, `voice-capture-worklet.js`; `packages/streamdeck/src/audio/capture.ts`; contract §2 |
| Transport | Authenticated Phoenix sockets `/voice` (dashboard session, CSRF, writable) and `/streamdeck` (token) | `voice_socket.ex:21-35`; `streamdeck_socket.ex:11-25` |
| Transcription | Aiur's daemon opens the ElevenLabs realtime session with its own key; audio and text pass through ElevenLabs | `realtime.ex:14-35,53-54`; `apis/elevenlabs.md:12,52` |
| Delivery | Text returns to the composer or the deck buffer; it reaches an agent only when the operator presses Send | `src/lib/aiur_web/components/operator_control_center/conversation_drawer.ex:229` (contract V5); deck `sendTranscript` (`packages/streamdeck/src/controller.ts:743`) |
| Retention | Aiur writes no audio to disk or logs; sent text is an ordinary chat message | baseline grep (no `File.*` and no audio `Logger` in voice modules); contract V2 |
| Exception | The dashboard "interactive voice chat" (`voice:conversation`) auto-submits after push-to-talk | `conversation-voice-controller.js:225-235,354-366,379-396`; contract §1 note, owner item E5-OQ2 |

## Chosen design

1. Add a section "## Who does what" after "What voice does", with the 5-row
   table (Capture, Transport, Transcription, Delivery, Retention) built from
   the evidence above, in operator language.
2. Add one sentence at the top of "Privacy and secret handling": "Voice
   transcription is cloud processing: while you dictate, your audio and the
   returned text pass through ElevenLabs. A private network (Tailscale) or
   loopback-only dashboard does not change that."
3. Add a footnote row for the existing auto-submit exception: "Interactive
   voice chat on the Dashboard sends each finished utterance to the agent
   without a Send press." This is today's behaviour. MP-E5 decides its future
   (DESIGN-E5).

The page grows by about 15 lines, to about 72.

## Implementation steps

1. Edit `apis/elevenlabs.md` as above.
2. `guide/stream-deck.md` already has "### Where your voice goes" (`:203`).
   Read it at the implementation head. If it already says audio goes to
   ElevenLabs, add only a link to the new section; otherwise add the item 2
   sentence there.
3. Build the docs and run the docs spec.

## Non-happy paths

- **Owner changes the auto-submit behaviour first (MP-E5).** Re-read
  `conversation-voice-controller.js` at the implementation head, and drop or
  adjust the footnote. A wrong doc is worse than a missing one.

## Compatibility and rollout

n/a — docs only. Rollback means reverting the commit.

## Verification

```bash
env -C <worktree>/website/docs-app bun run build
env -C <worktree>/website npx playwright test --project=brand tests/gui-docs.spec.ts
```

Expected: both pass, and the five asserted strings are still present. There is
no mutation check (docs only; review-enforced). The reviewer checks each table
row against the evidence column.

## Completion and handoff

- [ ] The responsibilities table and the cloud-processing sentence are present.
- [ ] The auto-submit exception is stated as current behaviour.
- **Docs:** this ticket is the docs change.
- **Dependents:** MP-E5 and MP-E6 extend this page for converse mode (contract
  §10). MP-N6/N7 link it from the phone and watch voice settings.
