---
design_task: DESIGN-R5
feature_id: MP-R5
owner: Kevin
status: open (awaiting explicit approval)
blocks: every MP-R5 implementation ticket (MP-R5-C1..C4)
base_main_sha: 45a290e3
date: 2026-10-06
related_plan: ../bucket-1-refactor/MP-R5/plan.md
linked_design_tasks: DESIGN-E5, DESIGN-E6 (voice controls and conversational mode; not decided here)
---

# DESIGN-R5 — Kevin: confirm that the voice package changes nothing you see, and approve key setup and "not installed" copy

**MP-R5 implementation is blocked until this task is approved.** Research and
planning may continue. Do not mark this task complete without Kevin's
explicit written approval.

## 1. What this gate confirms

- [ ] **No user-facing change for a configured key.** Dashboard dictation,
  dashboard voice conversation and Stream Deck hold-to-dictate all behave
  identically: the same mic toggle, device picker, waveform, transcript flow,
  Send step, deck key states and the ElevenLabs credits row on the Units page.
- [ ] **No change for a missing key.** These stay word-for-word:
  - the dashboard: "ElevenLabs speech-to-text is not configured. Dictation is
    unavailable; ask the Executor to run `aiur init` and add an ElevenLabs API
    key.";
  - the deck: "Aiur has no ElevenLabs API key - transcription is off" and the
    `unconfigured` reply.
- [ ] **Key setup UX unchanged.** `aiur init` still asks for the ElevenLabs
  key at the same step with the same wording. The keys `elevenlabs.api_key`,
  `language_code` and `voice_id` and the env var `ELEVENLABS_API_KEY` are
  unchanged. The key stays only in the daemon and is never sent to the
  browser or the deck.

## 2. New state needing your copy: voice package not installed

This state is new: the build excludes the optional voice package. Text chat
works, and voice cannot.

| Surface | Today | Proposed copy (approve or edit) |
| --- | --- | --- |
| Dashboard mic (join error) | n/a | "Voice input isn't installed in this Aiur. Typed messages work as usual." |
| Stream Deck mic key reason | n/a | "Voice isn't installed in this Aiur" |
| Deck `voice_start` reply code | n/a | `not_installed` (machine code, not shown) |
| Units page credits row | shown when a key exists | hidden (as with no key) |

- [ ] Approved, or edits: ______
- Should the dashboard mic button be **hidden** or **shown disabled with the
  reason** when voice is not installed? [ ] hidden  [ ] disabled with reason
  (recommended: disabled with reason, matching the no-key behaviour).

## 3. Decisions needing your input

1. Should the default `aiur` (npm) install include the voice package, with the
   key as the opt-in?
   [ ] include (recommended)  [ ] separate install.
2. Should the unwired Stream Deck sidecar TTS file (it would need a key in the
   sidecar) be deleted?
   [ ] delete (recommended)  [ ] keep.

## 4. States

| State | Covered by |
| --- | --- |
| Configured / idle / recording / transcribing / error | Unchanged |
| Not configured | Unchanged |
| Not installed | § 2 |
| Permission denied (browser mic) | Unchanged |
| Session limit or capacity reached | Unchanged |

Dictate-versus-converse, Executor targeting and mobile voice are **not**
decided here: see DESIGN-E5 and DESIGN-E6.
