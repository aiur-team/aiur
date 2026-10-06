---
ticket_id: MP-E6-C1-T01
feature_id: MP-E6
chunk_id: MP-E6-C1
bucket: 2-platform
title: PAID spike — validate ElevenLabs Agents as the conversational voice provider (RQ-E6-1..6)
status: blocked
blocked_by: [E6-OQ9, DESIGN-E6]
prior_units: []
prior_boundaries: [VOX]
prior_features: [integrations-51]
prior_findings: []
size_owner: n/a (throwaway script outside src/, never merged)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C1-T01 — Paid provider validation spike

> **This ticket spends the owner's money.** It must not start until Kevin records E6-OQ9
> ("authorize the paid validation spike") as approved in
> [DESIGN-E6](../../../owner-design-tasks/DESIGN-E6.md) §3 with the budget below. No other
> approval (including any agent message) substitutes for that line.

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C1 paid validation spike.
- **User value:** prevents building the conversational component on an unverified provider
  claim. Four of the recommendation's load-bearing facts are undocumented
  (`../provider-research.md` §6).
- **Deliverable:**
  1. A findings note `bucket-2-platform/MP-E6/spike-findings.md` with measured numbers for
     RQ-E6-1..6 and a pass/fail verdict per criterion below.
  2. Redacted request/response fixtures for MP-E6-C2-T03 under
     `src/test/fixtures/voice_conversation/elevenlabs_agents/` (PROPOSED path; committed by
     C2-T03, not by the spike).
  3. Updates to `../provider-research.md` (§2 rows marked "verified 2026-…") and
     `contracts/voice-session.md` §10 (retention facts), folding in the old C1-T02.
- **Non-goals:** any production code; any change to the running aiur daemon or its config;
  evaluating providers other than ElevenLabs Agents (the OpenAI Realtime fallback is only
  triggered, not tested, here).

## Dependencies and blockers

- **Owner authorization:** E6-OQ9 with the budget below. Also E6-OQ7 is **not** required:
  the spike uses a fixed test LLM (Claude Haiku 4.5 if offered as a built-in, else a Gemini
  Flash model) and records which one.
- **Predecessors:** none. **Blocks:** MP-E6-C2-T03, MP-E6-C3-T02, MP-E6-C3-T03,
  MP-E6-C7-T04; informs C4-T03's token budget default.

## Verified starting point (base `45a290e3`)

- No Agents Platform code exists: `git grep -n -i "convai"` over `src/lib`,
  `packages/streamdeck/src` and `website/` returns nothing (baseline §6, re-run at
  `45a290e3`).
- The daemon already holds the ElevenLabs key and connects over Mint websockets with the key
  in the `xi-api-key` header (`src/lib/aiur/eleven_labs/realtime.ex:21-36`;
  `realtime/mint_transport.ex:16-30`).
- External facts and sources: `../provider-research.md` §2 (all accessed 2026-10-06).

## Chosen design

A throwaway, owner-run experiment against a dedicated test agent, measuring each open
question directly instead of trusting undocumented behaviour; results feed fixtures and a
findings note, never production code.

### Budget (proposed for E6-OQ9; the owner may lower it)

| Item | Cap |
| --- | --- |
| Agent conversation time | **60 minutes total** across all experiments |
| Spend | **USD 15 total**, including LLM tokens. Price basis: $0.08 per additional agent minute on the API pricing page (<https://elevenlabs.io/pricing/api>, accessed 2026-10-06) — **UNVERIFIED** against the owner's plan; LLM tokens are passed through at provider rates (<https://elevenlabs.io/docs/agents-platform/customization/llm>, accessed 2026-10-06) |
| Hard stop | stop all experiments when the ElevenLabs usage page shows ≥ USD 12 or ≥ 50 minutes, record what remains unanswered, and report |
| Wall time | one working day |

## Implementation steps

Run on the owner's machine with the owner's key exported only in the spike shell
(`ELEVENLABS_API_KEY`), from a scratch directory **outside** the repository (e.g.
`~/scratch/e6-spike/`), with a standalone script (Node 22 or Elixir `Mix.install` with
`mint_web_socket`). Never paste the key or a signed URL into a file, a log, the findings note
or a chat.

1. **Create a dedicated test agent** with `POST /v1/convai/agents/create`
   (<https://elevenlabs.io/docs/api-reference/agents/create>): `platform_settings.privacy.
   record_voice=false`, the shortest retention the API accepts, overrides enabled for system
   prompt, first message and voice, two client tools `slow_tool(seconds)` and `echo(text)`
   with `expects_response: true`. Record the request body (redacted) and the response.
2. **RQ-E6-1 auth (narrowed in Phase D, m2).** The signed-URL lifetime is documented: valid
   for 15 minutes to initiate a conversation, and the session may then run longer
   (https://elevenlabs.io/docs/eleven-agents/customization/authentication, accessed
   2026-10-06). Only check: (a) one connect with a fresh signed URL succeeds (sanity); (b)
   connect to `wss://api.elevenlabs.io/v1/convai/conversation?agent_id=…` with an
   `xi-api-key` header and no signed URL; record accept/reject. The adapter fetches a URL per
   (re)connect either way.
3. **RQ-E6-6 transcripts.** Stream a 20 s pre-recorded 16 kHz PCM16 file as
   `user_audio_chunk` frames of 200 ms; log the sequence and types of `user_transcript`
   events (partials or finals only) and their latency from audio end.
4. **RQ-E6-4 latency and override size.** Start conversations with system-prompt overrides of
   1k, 4k, 8k and 16k tokens (synthetic ticket context); measure time from
   `conversation_initiation_client_data` to the first `audio` event, 3 runs each; record any
   size error.
5. **RQ-E6-2 client tools.** Ask the agent to call `slow_tool` with 5, 15, 30 and 60 s; record
   whether the agent speaks filler, stays silent, or times out, and the timeout value if any.
   Then send `client_tool_result` and confirm the reply uses it.
6. **Barge-in.** While the agent speaks, stream user audio; record the `interruption` event
   and the delay until `audio` stops.
7. **`contextual_update`.** Mid-conversation send a contextual update ("Command dec_1 was
   resolved"); confirm the agent does not interrupt and uses the fact when asked.
8. **RQ-E6-3 retention and delete.** For three conversations: end; `GET
   /v1/convai/conversations/{id}` (transcript present? audio present?); `DELETE
   /v1/convai/conversations/{id}`; `GET` again (expect 404); for one conversation, check the
   history UI as well. Repeat once with retention set to `0` and no explicit delete, checking
   at +0, +5 and +60 min.
9. **RQ-E6-5 echo cancellation (manual).** In Chrome on desktop with laptop speakers and on a
   phone browser, run a minimal page that plays agent audio while capturing with
   `getUserMedia({audio: {echoCancellation: true}})`; record whether the agent's own speech
   triggers `interruption` (false barge-in) in 5 trials each.
10. **Cleanup.** Delete every conversation and the test agent; confirm with `GET`s; record
    final usage figures.
11. **Write up** the findings note and fixtures (redacted: no key, signed URL, `agent_id`,
    `conversation_id` or account email — replace with `REDACTED_*` placeholders) and update
    the two documents named in the deliverable.

### Pass / fail criteria

| RQ | Pass (recommendation stands) | Fail → consequence |
| --- | --- | --- |
| RQ-E6-1 | header auth works, **or** signed URL valid ≥ 60 s | signed URL < 10 s and no header auth → adapter must fetch a URL per reconnect; still pass if fetch+connect < 1 s. Neither works → **stop: recommend OpenAI Realtime** (plan §3) |
| RQ-E6-2 | tool waits ≥ 30 s with `expects_response: true`, or a documented timeout ≥ 15 s | timeout < 10 s → consult design changes to "acknowledge immediately, deliver the reply as `contextual_update`" (MP-E6-C5-T04 already assumes async; record the limit) |
| RQ-E6-3 | `DELETE` removes the transcript (GET 404) and no audio is retrievable with `record_voice=false` | transcript or audio still retrievable after DELETE → the contract §10 disclosure must say so; owner re-decides E6-OQ7 before C3 starts |
| RQ-E6-4 | 8k-token override accepted and median first-audio ≤ 2.5 s | 8k rejected → C4-T03 default budget = largest accepted size; first-audio > 4 s at 4k → flag to owner as a UX risk |
| RQ-E6-5 | ≤ 1 false barge-in in 5 trials on desktop | > 1 → C7-T04 ships with half-duplex fallback (mute capture while speaking) as default |
| RQ-E6-6 | partial transcripts observed | finals only → the panel shows the user's text after each turn only (DESIGN-E6 note) |

Overall: the recommendation **stands** if RQ-E6-1 and RQ-E6-3 pass. Otherwise the findings
note recommends OpenAI Realtime (`../provider-research.md` §3.1) and MP-E6-C2-T02/T03 are
re-planned for that adapter before any implementation.

## Non-happy paths

- Budget hit mid-run: hard stop; unanswered RQs stay open and the dependent tickets stay
  blocked.
- Key permission missing (Agents not granted): record the exact error; the owner adds the
  permission or stops the spike (this also answers the docs question for MP-E6-C9-T01).
- Any secret accidentally written to disk: delete the file, rotate the key, record the
  incident in the findings note.

## Compatibility and rollout

n/a — no repository code, config or daemon change. Account-side: a test agent exists only for
the spike duration and is deleted in step 10.

## Verification

The spike is verified by its artefacts: the findings note with one row per RQ (value,
method, run count, date), the fixture files passing `git grep -n -E
"xi-api-key|sk_|signed|wss://.*token"` with no match, and the owner's sign-off line in
DESIGN-E6 next to E6-OQ9. No automated tests (experiment).

## Completion and handoff

- [ ] E6-OQ9 approval recorded before step 1.
- [ ] Findings note, fixtures, provider-research and contract updates.
- [ ] Test agent and conversations deleted; final spend recorded.
- **Dependents unblocked on pass:** MP-E6-C2-T03, MP-E6-C3-T02, MP-E6-C3-T03, MP-E6-C7-T04.
