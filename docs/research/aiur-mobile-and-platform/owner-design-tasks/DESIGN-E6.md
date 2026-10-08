---
design_task: DESIGN-E6
feature_id: MP-E6
owner: Kevin (operator)
status: open — not approved
blocks: [MP-E5-C3-T02, MP-E6-C1-T01, MP-E6-C3-T01, MP-E6-C3-T02, MP-E6-C4-T04, MP-E6-C5-T03, MP-E6-C5-T04, MP-E6-C6-T04, MP-E6-C7-T01, MP-E6-C7-T02, MP-E6-C7-T03, MP-E6-C7-T04, MP-E6-C8-T01, MP-E6-C8-T02, MP-E6-C8-T03, MP-E6-C9-T01, MP-N6-C4-T03, MP-N7-C4-T01, MP-N7-C4-T03, MP-N7-C4-T05]
blocks_note: "Phase D: the list is the tickets whose blocked_by names DESIGN-E6 (waived entries excluded). Earlier wording: MP-E6-C5-T03/T04, C7, C8 (see ../bucket-2-platform/MP-E6/chunks.md); MP-E6-C1 needs E6-OQ9 authorization"
shared_with: DESIGN-E5 (the Dictate/Converse choice), DESIGN-E2 §4 (Command answers), DESIGN-E3 and DESIGN-E4 (conversation views and anchors), DESIGN-E7 (listener mode shown on consults), DESIGN-N6/N7 (phone/watch converse)
base_main_sha: 45a290e3
date: 2026-10-06
---

# DESIGN-E6 — Kevin: design and approve the conversational voice assistant UX

Deliver the interaction design, states, copy and an explicit approval. **MP-E6 user-visible
implementation stays blocked until this task is approved.** Backend chunks C2–C4 and C6 may
proceed (C2-T03 also waits on the paid spike).

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
| E6-OQ1 | How a draft becomes an instruction: on-screen Confirm only, or may a spoken "send it" confirm? | On-screen Confirm only. Speech may at most *focus* the Confirm button; a draft is confirmed only by the button on an authenticated client, never by a provider tool call or transcript (voice-session V8; security review m4; parked spec §18 precedent). |
| E6-OQ2 | Must you confirm before the assistant consults the agent? | Yes on the first consult in a session; later consults in the same session may go when you ask aloud. |
| E6-OQ3 | Role pre-context: where are roles authored, and which roles ship? | Files under the instance config folder (e.g. `.aiur/voice/roles/*.md`); ship "ticket discussion" and "project discussion". |
| E6-OQ4 | The assistant's voice and name | Reuse `elevenlabs.voice_id`; no persona name. |
| E6-OQ5 | May you delete a transcript? | Allow deletion of a whole session by you only, with confirmation; never automatic. |
| E6-OQ6 | Cost caps | 20-minute session cap, 120 s idle end, and `voice.conversation.daily_minutes_cap` **default 60 minutes per local day** (explicit `null` = no cap; `0` disables Converse). Sessions interrupted by a daemon restart count (last record time − start). You may pick another number. (Phase D, feasibility M8: a null default means the cap never fires.) |
| E6-OQ7 | Accept the cloud disclosure (contract §10) and pick the LLM. Options: Claude Haiku 4.5, or a Gemini Flash model | **Claude Haiku 4.5**, because your code already goes to Anthropic through Claude workers, so it adds no new data processor beyond ElevenLabs; the E6-OQ9 spike confirms its latency. |
| E6-OQ8 | One target per session? | Yes; switching target starts a new session. |
| E6-OQ9 | Authorize the paid validation spike (MP-E6-C1) | **Authorize**, because the adapter's event mapping cannot be built from documentation alone. |
| E6-OQ10 | Label for voice-originated messages in the agent's transcript (Phase D, E6 R-1/R-2): entries with `origin: voice_assistant` (consults and confirmed instructions) are rendered with which label? | A short "via voice assistant" tag beside the operator label. Until approved they render as plain operator messages. |
| E6-OQ11 | Should a Command answer produced through a voice conversation show its `via: voice_assistant` audit tag anywhere besides the Command timeline (E6 R-3)? | Timeline only. |

### 3.1 Added 2026-10-08 — fast conversation over a slow agent

Source: [../bucket-2-platform/MP-E6/realtime-convo-research.md](../bucket-2-platform/MP-E6/realtime-convo-research.md)
(your request of 2026-10-08, quoted there verbatim).

| ID | Decision | Engineering recommendation |
| --- | --- | --- |
| E6-OQ12 | When you press Converse, does the coding agent stop? | **No by default.** The assistant answers from the always-current status card; it asks the agent to refresh its note at the next checkpoint without stopping. "Pause and brief me" is an explicit button (your 5-step flow, opt-in). |
| E6-OQ13 | Provider after the bake-off: ElevenLabs Agents or OpenAI Realtime (speech-to-speech, closest to ChatGPT voice)? | Decide from the measured spike (MP-E6-C1-T01, now a two-provider comparison). Research leans to OpenAI Realtime for feel and to ElevenLabs for reuse of your key and voice. |
| E6-OQ14 | May the assistant speak first when the agent answers, CI changes or a Command opens? | Yes, at the next pause, for agent answers and new Commands only; never mid-sentence. |
| E6-OQ15 | Side queries: may the assistant fork the agent's session (read-only) to answer "why" questions fast, at extra model cost per question? | Yes if the side-query spike (MP-E6-C10-T03) passes isolation; show the cost in the transcript. |

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
| Ended or failed with a typed cause | one state per row of the [client error and end-reason table](../contracts/voice-session-client-errors.md) the dashboard can show: daily cap reached, provider quota, provider unavailable, connection lost, cause-neutral provider error, unknown. Retry only where that table allows it. History views also show "ended by a daemon restart". |
| Ended | reason (you ended, idle, time cap, target gone); link to the transcript |
| Context gaps | which context the assistant does not have (e.g. "Command data unavailable") |
| Microphone permission denied | which permission; how to allow it; typing still works (distinct from Unavailable) |
| History loading | skeleton while past sessions load; never a false "no past sessions" |
| Empty history | no past sessions for this target |

## 5. Copy to approve

Panel title; the consult framing text the agent sees (plan §6); draft card labels; state
lines; the privacy disclosure (what goes to ElevenLabs and to the LLM vendor; no audio kept by
aiur; provider deletion after each session; Zero Retention only on Enterprise plans).

## 6. Acceptance conditions

- Every surface in §2 and state in §4 designed; every decision in §3 answered
  (E6-OQ1…OQ15, including OQ10–OQ15).
- The design makes it impossible to mistake discussion for an instruction: a draft is visibly
  different from a spoken turn, and nothing is sent without your Confirm (per E6-OQ1).
- The full transcript is reviewable; no design element replaces it with a summary.
- Phone/watch notes handed to DESIGN-N6/N7 (e.g. draft confirmation on a watch).
- Explicit written approval recorded here.

## 7. Approval

- [ ] Approved by Kevin — date: ____ — notes: ____
