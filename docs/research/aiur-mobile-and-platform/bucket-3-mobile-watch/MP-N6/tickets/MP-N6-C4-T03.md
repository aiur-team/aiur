---
ticket_id: MP-N6-C4-T03
feature_id: MP-N6
chunk_id: MP-N6-C4
bucket: 3-mobile-watch
title: Converse about a Command — MP-E6 session seeded with Command context, confirm-to-answer, typed end reasons
status: blocked
blocked_by: [DESIGN-N6, DESIGN-E5, DESIGN-E6, MP-N6-C4-T01, MP-N6-C4-T02, MP-E6-C7-T01, MP-E6-C5-T05, MP-E5-C8-T01, E6-OQ9 (paid ElevenLabs spike), RQ-TRANSPORT (RC-15)]
prior_units: []
prior_boundaries: [mobile-app, VOX #36]
prior_features: [MP-E6, MP-E5]
prior_findings: [voice-session §5.3 (converse delivery: drafts), §6 (states, end reasons), §8 and §8.1 (codes, retry), §10 privacy disclosure; review-feasibility-failures M2, M7; review-privacy-security m4, M5]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C4-T03 — Converse about a Command (phone)

> **Phase D (feasibility M2/M7, security m4/M5).** Rewritten to brief §9 depth at the level
> of MP-N7-C4-T05: every voice-session end reason and error code has its own phone state,
> confirmation only from the button, a shared end-reason fixture, and no transcript on
> disk. `MP-N6-C4-T02` is added to `blocked_by` because this ticket reuses its
> `deviceVoiceClient` (no cycle: C4-T02 depends only on C4-T01 and E5-C8).

## Identity and outcome

- Bucket 3, MP-N6, chunk C4.
- **User value:** talk a blocker through with the voice assistant from the Command screen,
  then confirm one drafted answer with a tap. When voice stops, the phone says exactly why
  (daily cap, provider quota, provider down, connection lost, device unpaired) and offers
  Retry only when a retry can work.
- **Deliverable:** after "Converse" in the C4-T01 sheet, the phone joins `voice:converse`
  on the device socket (`/voice/device`, voice-session §3.5) with
  `{v: 1, mode: "converse", surface: "command_response", target: {kind: "command",
  instance_id, decision_id, expected_version}, client_session_id, client: {kind: "phone",
  version}}`. It streams PCM per §2, plays assistant audio, shows assistant text, shows each
  `command_answer` **draft** in the Command response form with Confirm / Discard, and maps
  every end reason and error code to a typed state.
- **Non-goals:** the conversation component and the provider (MP-E6); the Dictate path
  (C4-T02); watch Converse (MP-N7-C4-T05); copy and layout (DESIGN-E5/E6/N6).

## Dependencies and blockers

- **Design (copy and layout only):** DESIGN-N6 (RC-33), DESIGN-E5 (choice sheet),
  DESIGN-E6 (draft card, disclosure, end-reason copy).
- **Server:** MP-E6-C7-T01 (`voice:converse` channel), MP-E6-C5-T05 (`propose_command_answer`
  drafts; confirm records the answer through `Aiur.Commands.Answering` with
  `idempotency_key = draft_id`, X-26), MP-E5-C8-T01 (device ticket + `/voice/device`),
  E6-OQ9 (paid spike validates the provider).
- **Client:** C4-T01 (sheet, target), C4-T02 (`deviceVoiceClient`: ticket, socket, join,
  PCM capture), RQ-TRANSPORT (`wss://` vs tailnet `ws://`).

## Verified starting point

- voice-session §3.3/§3.4: client events `audio`, `stop`, `cancel`, `confirm_draft
  {draft_id, edited_text?}`, `discard_draft`, `end`, `playback_state`; daemon events
  `state`, `assistant_text`, `audio`/`audio_done`/`audio_error`, `interrupted`, `draft
  {draft_id, kind, target, text, status}`, `delivery`, `error{reason_code, message}`.
- voice-session §5.3: the daemon (not the phone) records the answer on confirm, with
  `idempotency_key = draft_id` and the draft's base version; draft statuses
  `proposed → confirmed → sent → delivered | failed`, `discarded`, `stale`.
- voice-session §6 end reasons: `user_end`, `idle_timeout`, `max_duration`, `target_gone`,
  `provider_error`, `capability_lost`, `auth_changed`, `cost_cap`, plus `daemon_restart`
  (written to the transcript at boot only; a live client sees `transport_lost`).
- voice-session §8 codes and the §8.1 client table (code → `retry: none | now | later`,
  copy key). `cost_cap_reached` is renamed `cost_cap`.
- MP-E6-C5-T05: E2 conflicts on confirm (`stale_version`, `already_decided`, `resolved`) →
  draft `stale` with E2's reason; the winner comes from `ConflictSummary.for/1` (X-26).
- C1-T03 409 body (`winner{actor_kind, accepted_at, summary, delivery_status}`,
  `replaceable`) is the shape the phone already renders in C3-T02.

## Chosen design

### Session state machine (`converseSession.ts`, pure reducer)

```text
idle ─Converse chosen→ connecting ─state{listening}→ listening ⇄ thinking ⇄ speaking
any live ─tool consult→ consulting ─result→ prior state
any live ─socket closed, no error→ reconnecting ─rejoin ok (same client_session_id)→ prior state
reconnecting ─rejoin refused or 10 s→ ended{transport_lost}
any ─error{reason_code} or state{ended, reason}→ ended{code}  (row from §8.1)
any ─user End / leaves screen→ sends `end` → ended{user_end}
draft{status: proposed} → draftCard(Confirm | Discard | Edit)
draftCard ─Confirm button→ send confirm_draft{draft_id, edited_text?} → confirming
confirming ─delivery{sent|delivered}→ answered (S04/S05, "via voice" tag)
confirming ─draft{status: stale}→ draftStale (S06 or S10 with winner)
```

### Phone behaviour per code (copy keys and retry from voice-session §8.1; the contract wins on any difference)

| Code (end reason / error) | Phone state | Retry | Draft handling |
| --- | --- | --- | --- |
| `user_end` | back to Command screen | — | unconfirmed drafts discarded with a note |
| `idle_timeout`, `max_duration` | ended, "Conversation ended" | now (new session) | unconfirmed drafts stay visible as text to copy |
| `target_gone`, `target_stale`, `target_not_found` | Command refetched (C1-T01) → S09/S10/S13 | none | drafts marked stale |
| `capability_lost`, `unconfigured`, `not_installed` | Converse option unavailable with reason (S15) | none | kept as text |
| `auth_changed` (device revoked mid-session) | S12 pairing screen; in-memory transcript and drafts wiped | none | wiped |
| `read_only`, `unsupported_target`, `invalid_payload`, `chunk_too_large` | ended with its own copy; `invalid_payload`/`chunk_too_large` are client bugs and are logged without text | none | kept as text |
| `cost_cap` | "Daily voice limit reached"; typing still works | none (until the next local day) | kept as text |
| `provider_quota` | "Voice provider quota used up"; typing still works | none | kept as text |
| `provider_auth`, `privacy_preflight_failed` | "Voice is not set up correctly on the machine" (distinct keys) | none | kept as text |
| `provider_unavailable` | "Voice provider unavailable" | later | kept as text |
| `capacity`, `session_limit` | "Too many voice sessions" | later | kept as text |
| `transport_lost` (Wi-Fi→cellular, daemon restart, sleep) | "Connection lost"; transcript stays on the machine | now | unconfirmed drafts kept as text; a `confirming` draft is re-sent with the same `draft_id` on the next session only if the user presses Confirm again |
| `provider_error` | "Voice stopped (provider error)" — cause-neutral | now (once) | kept as text |
| `permission_denied`, `no_device` (client-side) | S16 / "No microphone" | none | n/a |
| `unknown` | "Voice stopped for an unknown reason" — cause-neutral, never relabelled | now | kept as text |
| `daemon_restart` | never received live; shown only when the transcript list (MP-E6-C6) is opened | — | — |

- **Wi-Fi → cellular:** the socket drops without an `error`. The client rejoins once within
  10 s with a fresh voice ticket and the same `client_session_id` (§3.2). If the daemon
  still holds the session, it continues; otherwise `ended{transport_lost}`. A
  `confirm_draft` sent just before the drop is safe to repeat: the daemon records with
  `idempotency_key = draft_id`, so a repeat is `duplicate`, never a second answer.
- **Draft stale (Command resolved elsewhere):** a `draft{status: "stale"}` carries E2's
  reason. The phone refetches the Command view (C1-T01) and renders S06 with the
  `ConflictSummary` winner (who, when, what) or S10 for a version change. Confirm is
  disabled; the draft text stays copyable.
- **Confirmation stays on the client (security m4):** `confirm_draft` is sent only from the
  Confirm button handler. No `assistant_text`, `transcript` or `tool_call` content can
  trigger it. An answered Command shows a neutral "via voice" tag.
- **No transcript on disk (security M5):** assistant text, user transcript and drafts live
  in the reducer state only; nothing is written to AsyncStorage, SecureStore or files.
  The full transcript is retained on the machine (D17, voice-session §9).
- Playback: provider audio per the format in the daemon's `audio` metadata; `interrupted`
  stops playback; `playback_state` reports it. Audio buffers are released at `ended`.
- Leaving the Command screen or backgrounding the app sends `end` (§2 capture rules).

## Implementation steps

1. `packages/aiur-mobile/src/voice/voiceErrors.ts`: load
   `fixtures/contract/voice/end-reasons.json`, export `describeVoiceEnd(code) →
   {copyKey, retry}`; an unlisted code maps to the `unknown` row (cause-neutral).
2. Create `packages/aiur-mobile/fixtures/contract/voice/end-reasons.json` verbatim from
   voice-session §8.1 if MP-N7-C4-T05 has not already created it (one row per code:
   `{code, kinds, retry, copy_key}`).
3. `packages/aiur-mobile/src/voice/converseSession.ts`: the reducer above, events from
   `deviceVoiceClient` (C4-T02), outbound frames as returned effects (so tests read them).
4. `packages/aiur-mobile/src/commands/ConverseSheet.tsx`: listening/thinking/speaking UI,
   draft card in the Command response form, ended state with copy key and optional Retry.
5. Wire the C4-T01 "Converse" option to the sheet; pass `target` and `expected_version`.
6. Docs (same PR): `website/docs-app/guide/mobile.md` § "Answering a Command by voice":
   Converse flow, what each end message means, and the voice-session §10 disclosure link.

## Non-happy paths

All rows of the table above, plus: daemon restart mid-session (client sees
`transport_lost`; the machine closes the transcript as `daemon_restart` and deletes the
provider copy, MP-E6-C6-T02); provider down mid-session (`reconnecting` on the daemon,
then `provider_error` or `provider_unavailable`); cap reached at a turn boundary
(`cost_cap`, no Retry); device revoked (`auth_changed`, wipe); answered elsewhere (draft
`stale` with winner).

## Compatibility and rollout

Behind capability `voice.conversation` (C4-T01). An end code from a newer daemon that is
not in the fixture renders the `unknown` row, never success and never a guessed cause.

## Verification

```text
npm --prefix packages/aiur-mobile test -- test/voice/endReasonsFixture.test.ts test/voice/converseSession.test.ts test/commands/ConverseSheet.test.tsx
```

| Test | Expected | Must fail without |
| --- | --- | --- |
| `endReasonsFixture: fixtureHasEveryContractCode` | the fixture decodes and contains every §6 end reason and §8 code listed in voice-session §8.1 (list copied into the test with a citation) | any fixture row (delete one → fails) |
| `converseSession: each end code renders its own row` (`it.each` over fixture rows) | `ended.copyKey === row.copy_key` and `retry === row.retry`, and `copyKey !== "voice.error.generic"` | the per-code mapping (replace with a generic "error" state → every row fails) |
| `costCapOffersNoRetry` / `providerQuotaOffersNoRetry` | no Retry action | the `retry: none` branch |
| `transportLostOffersRetry` | Retry action present | the `retry: now` branch |
| `unknownCodeIsCauseNeutral` | unlisted code → `unknown` row | the fallback (map to `provider_error` → fails) |
| `networkSwitchRejoinsOnceWithSameSessionId` | one rejoin with the same `client_session_id`; second drop → `ended{transport_lost}` | the rejoin step |
| `confirmResentIsSameDraftId` | a repeated confirm carries the same `draft_id` | draft-id reuse |
| `draftNeverConfirmedByProvider` | `assistant_text`/`transcript`/`tool_call` saying "confirm" emit no `confirm_draft` | the button-only rule |
| `confirmOnlyFromButton` | pressing Confirm emits exactly one `confirm_draft` | the handler |
| `staleDraftShowsWinner` | `draft{stale}` + 409 winner fixture → S06 with winner, Confirm disabled | the stale branch |
| `authChangedWipesSession` | `auth_changed` → S12, reducer transcript empty | the wipe |
| `noTranscriptPersisted` | storage spies record no write containing assistant or user text | the in-memory rule |
| `leavingScreenSendsEnd` | unmount → `end` frame | end-on-leave |
| `ConverseSheet: viaVoiceTagOnAnswer` | answered state shows the "via voice" tag | the tag |

Device rows: V-N5 in [MP-N4 device-validation-plan](../../MP-N4/device-validation-plan.md)
(restart the daemon → `transport_lost` copy and transcript intact; reach the daily cap →
`cost_cap` copy, no Retry; revoke the device → `auth_changed`).

## Completion and handoff

- [ ] Every test fails with its hunk reverted in a worktree (AGENTS.md); command reported in the PR.
- [ ] Docs: `website/docs-app/guide/mobile.md` section (same PR).
- Dependents: MP-N7 (watch Converse decision OQ-N6-3), MP-N6-C5-T02.
