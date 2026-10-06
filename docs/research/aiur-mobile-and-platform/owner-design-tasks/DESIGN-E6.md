---
design_task: DESIGN-E6
feature_id: MP-E6
owner: Kevin (operator)
status: open — not approved
blocks: MP-E6-C5-T3/T4, C7, C8 (see ../bucket-2-platform/MP-E6/chunks.md); MP-E6-C1 needs E6-OQ9 authorization
shared_with: DESIGN-E5 (the Dictate/Converse choice), DESIGN-E2 §4 (Command answers), DESIGN-E3 and DESIGN-E4 (conversation views and anchors), DESIGN-E7 (listener mode shown on consults), DESIGN-N6/N7 (phone/watch converse)
base_main_sha: 45a290e3
date: 2026-10-06
---

# DESIGN-E6 — Kevin: design and approve the conversational voice assistant UX

Deliver the interaction design, states, copy and an explicit approval. **MP-E6 user-visible
implementation stays blocked until this task is approved.** Backend chunks C2–C4 and C6 may
proceed (C2-T3 also waits on the paid spike).

## 1. What this is (and what exists today)

- **Today** the dashboard "interactive voice chat" sends your speech straight to the worker and
  reads its reply aloud. There is no assistant. (`conversation-voice-controller.js:354-396`.)
- **E6** adds a voice **assistant** you talk with *about* a worker's ticket or, with the
  Executor, about the project. It listens, asks questions, and drafts instructions. **It never
  sends anything to an agent until you confirm a draft.** It may ask the agent a question
  ("consult") under the rule you set in E6-OQ2.
- Provider (recommended, research MP-Q3): ElevenLabs Agents with a built-in LLM, run through the
  aiur daemon. See `../bucket-2-platform/MP-E6/provider-research.md`.

## 2. Surfaces

| Surface | Design needed |
| --- | --- |
| Converse panel (opened from the D16 choice on a worker or Executor view) | layout, transcript, speaking/listening indicators, End |
| Draft cards inside the panel | instruction draft, Command-answer draft, consult; Confirm, Edit, Discard; status after confirm |
| Transcript history per target | list of past sessions, full transcript view, Continue |
| Settings (or setup output) | role selection, voice, cost caps, privacy disclosure |
| Agent conversation (MP-E4) | how a consult and a voice-originated instruction look in the agent's transcript |

## 3. Decisions needed from you

| ID | Decision | Engineering recommendation |
| --- | --- | --- |
| E6-OQ1 | How a draft becomes an instruction: on-screen Confirm only, or may a spoken "send it" confirm? | On-screen Confirm only. Speech can *ask* to send; the button sends. (Parked spec §18 precedent.) |
| E6-OQ2 | Must you confirm before the assistant consults the agent? | Yes on the first consult in a session; later consults in the same session may go when you ask aloud. |
| E6-OQ3 | Role pre-context: where are roles authored, and which roles ship? | Files under the instance config folder (e.g. `.aiur/voice/roles/*.md`); ship "ticket discussion" and "project discussion". |
| E6-OQ4 | The assistant's voice and name | Reuse `elevenlabs.voice_id`; no persona name. |
| E6-OQ5 | May you delete a transcript? | Allow deletion of a whole session by you only, with confirmation; never automatic. |
| E6-OQ6 | Cost caps | 20-minute session cap, 120 s idle end, a daily minute cap you set. |
| E6-OQ7 | Accept the cloud disclosure (contract §10) and pick the LLM | Claude Haiku 4.5 or a Gemini Flash model as default. |
| E6-OQ8 | One target per session? | Yes; switching target starts a new session. |
| E6-OQ9 | Authorize the paid validation spike (MP-E6-C1) | Needed before the adapter's event mapping is built. |

## 4. States to design

| State | Must show |
| --- | --- |
| Unavailable | not configured / not installed / privacy preflight failed (with the fix) |
| Connecting | building context, opening the session |
| Listening / you are speaking | live user transcript |
| Thinking | the assistant is preparing a reply |
| Speaking | assistant text appearing; you can interrupt by speaking |
| Interrupted | playback stopped because you spoke |
| Consulting | waiting for the real agent; how long; that the question is visible to the agent |
| Draft proposed | the exact text and target; Confirm / Edit / Discard |
| Draft sent / delivered / failed / stale | the delivery state from the send path; for stale, why (Command resolved, agent ended) |
| Reconnecting / error | reason; transcript so far is saved |
| Ended | reason (you ended, idle, time cap, target gone); link to the transcript |
| Context gaps | which context the assistant does not have (e.g. "Command data unavailable") |
| Empty history | no past sessions for this target |

## 5. Copy to approve

Panel title; the consult framing text the agent sees (plan §6); draft card labels; state
lines; the privacy disclosure (what goes to ElevenLabs and to the LLM vendor; no audio kept by
aiur; provider deletion after each session; Zero Retention only on Enterprise plans).

## 6. Acceptance conditions

- Every surface in §2 and state in §4 designed; E6-OQ1..OQ9 answered.
- The design makes it impossible to mistake discussion for an instruction: a draft is visibly
  different from a spoken turn, and nothing is sent without your Confirm (per E6-OQ1).
- The full transcript is reviewable; no design element replaces it with a summary.
- Phone/watch notes handed to DESIGN-N6/N7 (e.g. draft confirmation on a watch).
- Explicit written approval recorded here.

## 7. Approval

- [ ] Approved by Kevin — date: ____ — notes: ____
