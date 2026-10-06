---
design_task: DESIGN-N7
feature_id: MP-N7
owner: Kevin (operator)
status: open — not approved
blocks: every MP-N7 implementation ticket (../bucket-3-mobile-watch/MP-N7/chunks.md, N7-C1..C5)
shared_with: DESIGN-N6 (Command response content and states), DESIGN-E2 (Command states and copy), DESIGN-E5/E6 (Dictate and Converse controls), DESIGN-N3 (instance status terms), DESIGN-N4 (notification text)
base_main_sha: 45a290e3
date: 2026-10-06
---

# DESIGN-N7 — Kevin: design and approve the watch interactions (Apple Watch and Wear OS)

Deliver the watch screens, states, copy and an explicit approval. **MP-N7
implementation stays blocked until this task is approved.**

Command states, option rules and answer copy come from DESIGN-E2 and DESIGN-N6. The
Dictate and Converse controls come from DESIGN-E5/E6. This task designs only the
**watch-sized layout and the watch-only states**.

## 1. Fixed scope (do not expand)

The watch has exactly: notifications, a compact Command card, suggested options,
explicit voice (a Dictate or Converse choice, D16), and a compact instance/status list.
**No pause, resume, spawn, or other orchestration controls** (brief §3). No transcript
browsing.

## 2. Platform facts that constrain the design

From [../bucket-3-mobile-watch/MP-N7/plan.md](../bucket-3-mobile-watch/MP-N7/plan.md)
and [framework-evidence.md](../bucket-3-mobile-watch/MP-N1/framework-evidence.md):

- Both watches depend on the phone being nearby for any live data or action. "Needs phone" is a normal, frequent state, not an error.
- Apple Watch shows the iPhone's notification only when the iPhone is locked and the watch is on the wrist (S15).
- Live, duplex voice is not available on the watch. Converse is turn-based: talk, wait, hear the reply.
- Watch dictation through the system recognizer is processed by Apple or Google, not by your ElevenLabs key.

## 3. Decisions needed from you

| # | Decision | Recommendation |
|---|---|---|
| D-N7-1 | Phone-dependent watch apps only in v1 (OQ-N7-1) | Yes |
| D-N7-2 | Default Dictate path: system recognizer, or always through the phone and ElevenLabs (OQ-N7-2) | System recognizer, with a disclosure line |
| D-N7-3 | Converse latency acceptance: the maximum acceptable time from end of speech to the reply starting | Set a number (for example 4 s); DV-W6 measures it |
| D-N7-4 | If Converse misses D-N7-3: "Continue on phone" hand-off acceptable? (OQ-N7-3) | Yes |
| D-N7-5 | Glanceables: complication or Tile with the blocking count (OQ-N7-4) | Yes, count + oldest age |
| D-N7-6 | Apple Watch and Wear OS together in v1, or Apple Watch first (OQ-N7-5) | Your devices decide |
| D-N7-7 | Short labels for the list: executor state, active agents, awaiting count, build % | Reuse dashboard terms, abbreviated |
| D-N7-8 | Context depth on the Command card: summary only, or summary + 2-line excerpt + recommendation marker | Summary + 2 lines + marker |

## 4. Screens to design

1. **Instance list:** one row per instance (machine label, `owner/name`, executor state, active agents, awaiting count, build % when available, freshness).
2. **Instance detail:** that instance's open Commands only, ordered as DESIGN-E2 orders them.
3. **Command card:** short summary, context (per D-N7-8), 2–3 options, recommendation marker, mic button.
4. **Answer feedback:** sending, delivered, conflict (show the winner), failed, stale ("question changed").
5. **Mic choice sheet:** Dictate or Converse; each shows its availability.
6. **Dictate review:** recognised text, Edit (re-dictate), Send, Cancel.
7. **Converse session:** talking, waiting, reply playing, reply text, end.
8. **Notification (long look):** what the expanded watch notification shows, given that its text comes from the phone.
9. **Glanceables** (if D-N7-5).

## 5. States to cover

| State | Applies to | Must show |
|---|---|---|
| Loading | list, card | A minimal indicator; no fake rows |
| Empty | list | "No instances" vs "No Commands waiting", distinct |
| Needs phone | all | The last data with its age; actions disabled |
| Machine unreachable (phone fine) | list, card | Per-instance unreachable, not zero |
| Stale | list, card | Age visible |
| Unavailable capability | list fields, mic options | Field hidden or the reason shown; no zeros |
| Permission denied | mic | Which permission; "Open the Watch app on iPhone" or watch Settings |
| Resolved elsewhere | card | Who resolved it and when; options hidden |
| Error | answer, voice | Typed cause, or "unknown" |
| Success | answer | A short confirmation (haptic + text); return to the list |

## 6. Acceptance conditions

- Screens 1–8 (and 9 if chosen) designed for both a small and a large watch size on each platform you ship (D-N7-6).
- Every state in §5 covered where it applies.
- D-N7-1..D-N7-8 answered.
- An inventory of interactive controls per screen shows no orchestration control (AC6 in the plan).
- Kevin records "DESIGN-N7 approved" with the date in this file. Until then every MP-N7 ticket is blocked.
