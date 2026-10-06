---
design_task: DESIGN-E5
feature_id: MP-E5
owner: Kevin (operator)
status: open — not approved
blocks: MP-E5-C3, C4, C5, C6 (see ../bucket-2-platform/MP-E5/chunks.md); the mic choice used by MP-E6-C7
shared_with: DESIGN-E6 (Converse panel), DESIGN-E2 §4 (Command presentation), DESIGN-E3 (Executor composer), DESIGN-N6 and DESIGN-N7 (phone/watch mic choice), DESIGN-R5 (key setup)
base_main_sha: 45a290e3
date: 2026-10-06
---

# DESIGN-E5 — Kevin: design and approve dashboard voice-input UX/UI

Deliver the interaction design, states, copy and an explicit approval. **MP-E5 user-visible
implementation stays blocked until this task is approved.** MP-E5-C1 (component extraction)
and C2 (channel and capability backend) are behaviour-preserving and may proceed.

This task owns the **mic choice** (D16) for every client. DESIGN-N6 and DESIGN-N7 adapt its
layout to phone and watch; they do not redefine the choice, the states or the copy.

## 1. What already exists (do not redesign by accident)

Verified at `45a290e3`, `components/operator_control_center/conversation_drawer.ex:166-236`:

- Two adjacent buttons: **Dictate message** (mic icon) and **Start interactive voice chat**.
- A **Browser microphone** select ("Default microphone"), remembered per browser.
- A waveform canvas and a status line: "Press the microphone to dictate. Review the text, then
  press Send."
- **Dictation fills the message box and waits for Send.** The transcript is reviewed and
  editable before sending. This stays (brief R5 "preserve existing behavior"); you are asked
  only to confirm it, not to choose.
- The interactive voice chat sends your speech to the agent **without review** and reads the
  reply aloud.
- Errors today: permission denied, no microphone, insecure origin, not configured, 5-minute
  limit, connection lost (`conversation-voice-controller.js:18-22,446-454`, `voice_channel.ex`).

## 2. Surfaces

| Surface | Today | E5 adds |
| --- | --- | --- |
| Worker conversation drawer | voice present | the D16 choice; cancel; delivery state |
| Agent log modal composer | no voice | same component |
| Executor conversation composer (MP-E3) | does not exist | same component |
| Command response — custom response field (`/commands/:id`, card and detail) | no voice | mic on the field; layout within DESIGN-E2 §4 |
| Command revision form | no voice | same as Command response |

## 3. Decisions needed from you

| ID | Decision | Options | Engineering recommendation |
| --- | --- | --- | --- |
| E5-OQ1 | How the D16 choice appears | (a) two always-visible buttons, Dictate and Converse; (b) one mic button that opens a two-button chooser | Either works. (b) is the same shape on phone and watch (brief N6 "explicit mic button"). |
| E5-OQ2 | The existing auto-send voice chat | (a) remove when MP-E6 ships, Converse means the assistant; (b) keep as a third, clearly labelled option; (c) remove now | (a). Until E6 ships, keep it where it is under its current label; do not call it Converse. |
| E5-OQ3 | Dictating a Command answer | auto-select "Custom response" when you start dictating? append to or replace existing text? | auto-select; append. |
| E5-OQ4 | No ElevenLabs key / voice not installed | hide the buttons, or show them disabled with a reason and a link to setup | disabled with reason when not configured; hidden when the package is not installed |
| E5-OQ5 | Keyboard | shortcut to start/stop dictation? hold-to-talk on desktop (the Stream Deck holds)? | toggle stays; add `Escape` to cancel; no hold-to-talk |
| E5-OQ6 | Device picker placement | inline (today) or in a settings popover | your call |

## 4. States to design (each surface)

| State | Must show |
| --- | --- |
| Unavailable | why (not configured / not installed / read-only dashboard) and what to do |
| Idle | the D16 choice |
| Requesting permission | that the browser is asking |
| Permission denied | how to allow it; typing still works |
| No microphone / insecure origin | reason; typing still works |
| Listening | live waveform, partial text appearing, Stop and Cancel |
| Finishing | "finishing transcription" (≤ 5 s today) |
| Ready to review | text in the field; Send is the only way to deliver |
| Cancelled | field restored to what it held before recording |
| Error (provider auth, quota, connection lost, 5-minute limit) | reason; text captured so far kept |
| Sending / sent / delivered / failed | the delivery state from the send path (MP-E7 or MP-E2), not a voice-only state |
| Stale target | Command resolved or revised elsewhere, or the agent ended: show why Send failed; text kept to copy |

## 5. Copy to approve

Button labels and tooltips for Dictate and Converse; each status line above; the unavailable
reasons; the privacy line next to the mic ("Audio is sent to ElevenLabs for transcription;
aiur keeps no audio" — final wording from contract §10).

## 6. Acceptance conditions

- The choice, every state in §4 and all copy are designed for all five surfaces in §2 (one
  design may cover several surfaces if stated).
- E5-OQ1..OQ6 are answered.
- You confirm dictation keeps review-then-Send.
- The mic never activates on page load, on opening a Command, or from a notification.
- Phone/watch implications noted for DESIGN-N6/N7.
- Explicit written approval recorded in this file (date and your name).

## 7. Approval

- [ ] Approved by Kevin — date: ____ — notes: ____
