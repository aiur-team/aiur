---
design_task: DESIGN-R5
feature_id: MP-R5
owner: Kevin
status: approved by the Executor 2026-10-08 per EXECUTOR-APPROVALS.md (Kevin may revise)
blocks: [MP-R5-C1-T01, MP-R5-C1-T02, MP-R5-C1-T03, MP-R5-C1-T04, MP-R5-C2-T01, MP-R5-C2-T02, MP-R5-C3-T01, MP-R5-C4-T01, MP-R5-C4-T02]
blocks_note: "Phase D: the list is the tickets whose blocked_by names DESIGN-R5 (waived entries excluded). Earlier wording: every MP-R5 implementation ticket (MP-R5-C1..C4)"
base_main_sha: 45a290e3
date: 2026-10-06
related_plan: ../bucket-1-refactor/MP-R5/plan.md
linked_design_tasks: DESIGN-E5, DESIGN-E6 (voice controls and conversational mode; not decided here)
---

Executor decisions recorded in [EXECUTOR-APPROVALS.md](EXECUTOR-APPROVALS.md) (2026-10-08).

# DESIGN-R5 — Kevin: confirm that the voice package changes nothing you see, and approve key setup and "not installed" copy

**MP-R5 implementation is blocked until this task is approved.** Research and
planning may continue. Do not mark this task complete without Kevin's
explicit written approval.

## 1. What this gate confirms

- [x] (Executor, 2026-10-08) **No user-facing change for a configured key.** Dashboard dictation,
  dashboard voice conversation and Stream Deck hold-to-dictate all behave
  identically: the same mic toggle, device picker, waveform, transcript flow,
  Send step, deck key states and the ElevenLabs credits row on the Units page.
- [x] (Executor, 2026-10-08) **No change for a missing key.** These stay word-for-word:
  - the dashboard: "ElevenLabs speech-to-text is not configured. Dictation is
    unavailable; ask the Executor to run `aiur init` and add an ElevenLabs API
    key.";
  - the deck: "Aiur has no ElevenLabs API key - transcription is off" and the
    `unconfigured` reply.
- [x] (Executor, 2026-10-08) **Key setup UX unchanged.** `aiur init` still asks for the ElevenLabs
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

- [x] (Executor, 2026-10-08) Approved as proposed.
- **Hidden or shown disabled when voice is not installed?** **This gate owns the
  question for every surface** (Phase D, X9): R5 ships first, and DESIGN-E5 E5-OQ4
  links here and keeps only the no-key case. Options: (a) **hidden**; (b) **shown
  disabled with the reason** above. **Recommendation: (b) disabled with reason**,
  because it matches the no-key behaviour and the pack-wide capability rule that an
  unavailable option is shown with its reason, never silently removed (DESIGN-N1 §3
  item 5, DESIGN-N5 §1). This is a recommendation for Kevin, not a decision.
  Consequence (CR-R5-2): **hidden** makes MP-R5-C1-T04 wait for MP-E5-C2 (the
  render-time capability check); **disabled with reason** keeps MP-R5 independent of
  MP-E5. [ ] (a) hidden  [x] (b) disabled with reason (Executor, 2026-10-08)

## 3. Decisions needing your input

1. Should the default `aiur` (npm) install include the voice package, with the
   key as the opt-in?
   [x] include (recommended) (Executor, 2026-10-08)  [ ] separate install.
2. Should the unwired Stream Deck sidecar TTS file (it would need a key in the
   sidecar) be deleted?
   [x] delete (recommended) (Executor, 2026-10-08)  [ ] keep.

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

## 5. Acceptance

The gate is complete when every box in §§ 1–3 carries your approval, the
hidden-or-disabled choice in § 2 and both § 3 answers are recorded, and you
record "DESIGN-R5 approved" with the date in this file.
