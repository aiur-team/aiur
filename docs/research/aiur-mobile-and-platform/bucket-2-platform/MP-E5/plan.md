---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-E5
bucket: 2-platform
base_main_sha: 45a290e3
date: 2026-10-06
blocked_by: DESIGN-E5 (owner), MP-R5 (voice package). MP-E2 (Command answer contract), MP-E3 (Executor composer) and MP-E7 (listener-mode send) block only the chunks that use them (C4 Command response on E2; Executor composer placement on E3; send-through on E7) — Phase D, X-53
owns_contracts: contracts/voice-session.md (§2–§5, §7–§8 jointly with MP-E6)
consumes_contracts: command request (MP-E2), listener mode (MP-E7), identity, capabilities (MP-R1)
---

# MP-E5 — First-party dashboard voice input — Plan

## Goal capsule

- **Objective:** put voice input on every dashboard surface where the operator types to an
  agent: worker conversation, Executor conversation and Command responses. Each activation
  offers an explicit **Dictate** or **Converse** choice (D16).
- **Not:** a new conversation system (MP-E6), a new send path (MP-E7 owns delivery), phone or
  watch UI (MP-N6/N7), provider extraction (MP-R5).
- **Readiness:** the backend and refactor chunks are specified. Every user-visible ticket
  waits on DESIGN-E5.

## 1. Repository findings (extends baseline §E5)

Verified at `45a290e3`. The baseline was right on substance. Two corrections: the browser spec
is `src/browser/tests/units.browser.spec.mjs` (not `src/test/browser/...`), and the existing
UI already shows **two side-by-side buttons** (dictate, interactive voice chat). That is close
to D16 but not identical, and the second button is the auto-submit loop.

| Area | Evidence |
| --- | --- |
| Composer markup | `components/operator_control_center/conversation_drawer.ex:166-236`: form `data-voice-composer` (`:171`), textarea `data-voice-input` (`:174-182`), button `aria-label="Dictate message"` `data-voice-mic` (`:185-198`), button `aria-label="Start interactive voice chat"` `data-voice-conversation` (`:199-212`), device `<select data-voice-device aria-label="Browser microphone">` (`:213-218`), waveform canvas (`:220-227`), status `role="status" aria-live="polite"` with "Press the microphone to dictate. Review the text, then press Send." (`:228-230`), Send `data-voice-send` (`:234`) |
| Only one surface has voice | `agent_log_modal.ex:43` has the same `send-operator-message` form without `data-voice-composer`. `decision_action.ex:97-106` custom response textarea (`answer[custom_response]`, maxlength 4000) has no mic. No Executor composer exists (baseline E3). |
| JS controller | `src/priv/static/conversation-voice-controller.js` (539 lines, U8 owner `BROWSER`, split), loaded by `components/layouts.ex:40`. Binds by `data-voice-*` selectors inside the hook element (`:27-55`). `toggle(mode)` (`:127-132`), `start(mode)` (`:134-…`), `stop()` (`:260-272`, 5 s final-transcript timeout), `handleSamples` (`:274-288`, downsample to 16 kHz PCM16), `applyTranscript` (`:345-352`, partial/final merge into the textarea, status "Dictation ready. Review the text, then press Send."), `explainFailure` (`:446-454`, permission/no-device copy) |
| Review before send | Dictation never submits; `channel.on("stopped")` closes the channel and leaves the text (`:225-235`). **This is existing dictate-review-Send behaviour and E5 preserves it.** |
| Auto-submit loop | Conversation mode calls `submitConversationTurn` → `form.requestSubmit` (`:354-366`), then watches `.conversation-message-agent[data-message-complete='true']` and pushes `speak` (`:379-396`) |
| Channel | `AiurWeb.VoiceChannel` (`voice_channel.ex`): joins `voice:dictation`/`voice:conversation` only when the dashboard is writable and auth generation matches (`:34-58`); missing key → "ElevenLabs speech-to-text is not configured…" (`:253-254`); 5-minute cap (`:89-95`); stops on auth change (`:184-191`). The channel is target-blind. |
| Socket | `AiurWeb.VoiceSocket` (`voice_socket.ex:17-35`), `endpoint.ex:26-27` |
| Limiter | `VoiceSessionLimiter` 2 per authority, 8 global (`voice_session_limiter.ex:12-13`) |
| Send path | `send-operator-message` (`dashboard_live.ex:640-661`) → `Aiur.AgentChat.send/3` (`agent_chat.ex:12-49`; default `delivery_policy: :interrupt`, `message_id` idempotency #2717) |
| Command answer path | `answer-decision` (`decision_events.ex:11,30`), `decision_commands.ex:143-155` builds `custom_response`, → `DecisionStore.answer/5` (`decision_store.ex:188-190`) |
| Deck precedent | Dictated Command answer: `streamdeck_channel.ex:152-167,589-601` (exactly one of `option_id` / `custom_response`) |
| Tests | `src/test/aiur_web/voice_channel_test.exs`, `src/test/aiur_web/operator_control_center/conversation_drawer_test.exs`, `src/browser/tests/units.browser.spec.mjs` |
| Docs | `website/docs-app/apis/elevenlabs.md` (privacy table `:48-55`) |
| Parked prior spec | `docs/voice-mode/spec.md` (Draft): states Idle/Listening/Transcribing/Thinking/Using tools/Speaking/Cancelled/Error (§4.3), error handling list (§21), "do not store raw mic audio by default" (§19). Its principle "voice is a transport, not a separate agent" (§3) holds for E5 dictation; E6 is deliberately different (brief E6). |

## 2. Proposed boundaries

| Component | Public interface | Required deps | Optional deps |
| --- | --- | --- | --- |
| `voice_input` function component (proposed, `AiurWeb`) | `<.voice_input for={textarea_id} send={button_id} surface={…} target={…} capabilities={…} />` renders the D16 choice, device picker, waveform, status, cancel | voice capability map (contract §7) | MP-E6 converse launcher |
| Browser voice client (proposed split of the 539-line controller) | `capture.js` (getUserMedia, worklet, PCM), `transport.js` (socket/channel, events), `voice-input.js` (state machine, DOM) | Phoenix socket | — |
| `AiurWeb.VoiceChannel` dictate topic | contract §3 join payload, `cancel` event, `reason_code` | voice package STT behaviour (MP-R5) | — |
| Capability provider | registered capability callback emitting `voice.stt` / `voice.tts` entries in the MP-R1 report shape (`state` ∈ `available|degraded|unavailable|unknown` plus a separate `reason`; contract §7; MP-E5-C2-T03) | MP-R5 package config | — |

Prior mapping — `Prior-units:` U8 (BROWSER split of the controller; WEB split of
`dashboard_live.ex`, 2,903 lines). `Prior-boundaries:` VOX #36, WEB #34, SD #35, DEC #27.
`Prior-features:` `ui-07` (dashboard voice, keep), `ui-08` (realtime STT shared by both voice
surfaces), `integrations-51`, `config-33`. `Size-owner:` BROWSER for the JS, WEB for
`dashboard_live.ex`.

## 3. Alternatives and recommendation

| Decision | Options | Recommendation |
| --- | --- | --- |
| Where voice attaches | (a) copy markup per surface; (b) one reusable component attached to any composer | **(b).** Three surfaces now, phone WebView later. Copying already happened once (`agent_log_modal.ex` lacks voice). |
| Who knows the target | (a) channel stays target-blind; the form owns the target; (b) join carries the target | **(b) for validation and logging, (a) for delivery.** Join validates the target and capability so errors appear before recording. Delivery stays the surface's own Send (V7). |
| Review before send | (a) preserve existing review-then-Send; (b) auto-send on stop | **(a).** Existing behaviour; brief R5 "preserve existing behavior"; V5. Not reopened as an owner question; DESIGN-E5 only confirms it. |
| D16 presentation | (a) keep two adjacent buttons; (b) one mic button that opens a Dictate/Converse chooser | Owner decision (E5-OQ1). Engineering accepts both; (b) matches the phone/watch "explicit mic button" shape of brief N6. |
| Converse before MP-E6 ships | (a) Converse button hidden until E6; (b) Converse = existing auto-submit loop until E6 | Owner decision (E5-OQ2). Recommend **(a)** plus keeping the existing loop where it is today under its own label until E6 replaces it. |
| Command dictation | (a) dictation fills the custom response field; (b) speech also picks an option ("option two") | **(a).** (b) is intent parsing and belongs to E6's `propose_command_answer`. |
| No-key presentation | hidden vs disabled with reason | Owner decision (E5-OQ4). The contract requires "absent or clearly unavailable". |

## 4. Contracts

- **Owns (jointly with MP-E6):** [contracts/voice-session.md](../../contracts/voice-session.md)
  §2 capture, §3 transport, §5.2 dictate delivery, §7 capability, §8 errors.
- **Consumes — MP-E2 command request:** assumes `answer` accepts `custom_response` (≤ 4,000
  characters, as `decision_action.ex:102` today), `expected_version`, `idempotency_key`; a stale
  version returns a typed conflict; DESIGN-E2 §4 owns Command presentation and E5 only adds the
  mic placement.
- **Consumes — MP-E7 listener mode:** assumes one send function for worker and Executor targets
  `send(conversation_ref, text, client_request_id, opts) → delivery_id` plus receipts
  (voice-session §11). E5 never picks the listener mode.
- **Consumes — MP-E3:** an Executor composer exists in the dashboard. E5 attaches to it.
- **Consumes — MP-R5:** the STT behaviour and capability map. If R5 has not landed, E5-C2 works
  against the in-core `Aiur.ElevenLabs.Realtime` with the same seam.
- **Consumes — identity:** target shapes in voice-session §5.1.

## 5. Non-happy paths

| Case | Behaviour |
| --- | --- |
| No key / package absent | Capability `unavailable` with reason `not_configured` / `not_installed` at render (the channel error code stays `unconfigured`, contract §7); mode buttons hidden or disabled with the reason (E5-OQ4); typing and Send unaffected (V6). |
| Read-only dashboard | No voice controls (composer is already hidden, `conversation_drawer.ex:167,237-240`). |
| Mic permission denied / no device / insecure origin | Existing copy (`:18-22`, `:446-454`); text already in the field is kept. |
| Provider auth or quota error | `provider_auth` / `provider_quota` codes; partial text kept for editing. |
| Transport lost mid-recording | Capture stops; finals received so far stay; status says what was kept. |
| Explicit cancel (new) | Stops capture and restores the field to its pre-recording text (the controller already tracks `baseText`, `:345-352`). |
| Command resolved or revised while dictating | Send fails the version check → DESIGN-E2 conflict state; dictated text stays visible to copy. |
| Command already answered on the phone/deck | Same as above; idempotency key prevents a double record. |
| Agent ended while dictating | Send fails with the E7 "target gone" status; text kept. |
| Two tabs or devices recording | Limiter: 2 per dashboard authority, 8 global; third gets `capacity`. Each tab delivers independently with its own `message_id`. |
| Executor target missing (E3 not live, or no Executor) | Executor composer absent → no voice there; nothing to fall back to. |
| Restart of the daemon | Channel drops (`transport_lost`); text in the browser field survives a LiveView reconnect only if the draft is kept (`drafts[@composer_key]`, `conversation_drawer.ex:182`). |
| Privacy | Audio only in memory; text logged on send as today (`agent_chat.ex:32` logs a preview). No change to that log in E5; flagged to MP-E7. |

## 6. Acceptance criteria

1. The worker drawer, agent log modal, Executor composer and Command custom-response field each
   render the same `voice_input` component when `voice.stt` is available.
2. Every activation shows the D16 choice; neither mode starts without a click/tap on its button.
   Loading `/commands/:id` or `/chat/...` never requests microphone permission (browser test
   asserts no `getUserMedia` call before a click).
3. Dictate: partial text streams into the field; on stop the field holds the final text and
   nothing is submitted until Send. Pressing Send uses the surface's existing handler
   (`send-operator-message` or `answer-decision`) — asserted by LiveView test.
4. Cancel during recording restores the field's pre-recording text and closes the channel.
5. With no key, the page renders the documented unavailable state and typed Send still works
   (LiveView test with `elevenlabs.api_key` unset).
6. Joining `voice:dictate` with a non-existent or non-writable target returns
   `target_not_found` / `target_not_writable` before any audio is accepted (channel test).
7. On a Command whose version moved, dictated text survives the conflict and the answer is not
   recorded twice (test with stale `expected_version` and repeated `idempotency_key`).
8. No audio bytes are written to disk: channel test asserts the fake transcriber is the only
   receiver; a grep-based check finds no file write in the voice path.
9. `website/docs-app/apis/elevenlabs.md` and the dashboard guide describe the new surfaces and the
   §10 privacy table.

## 7. UX gate

[DESIGN-E5](../../owner-design-tasks/DESIGN-E5.md). All user-visible chunks (C3–C6) are blocked
until it is approved. C1 and C2 are behaviour-preserving and may proceed.

## 8. Decomposition

See [chunks.md](chunks.md): C1 component and controller split, C2 target-aware channel and
capability, C3 D16 mode choice, C4 Command responses, C5 Executor and log-modal surfaces, C6
states/cancel/errors/delivery feedback, C7 docs and end-to-end verification.

## 9. Open questions

**Owner (Kevin)** — in DESIGN-E5: E5-OQ1 D16 presentation; E5-OQ2 the existing auto-submit
voice loop; E5-OQ3 Command dictation selects "Custom response" automatically and appends or
replaces; E5-OQ4 no-key presentation; E5-OQ5 keyboard shortcut or hold-to-talk on the dashboard.

**Research (Phase C):**
- RQ-E5-1: does LiveView's `phx-update` on the drawer re-render the textarea while the voice
  hook writes partials (the current code dispatches `input` events, `:350`)? Confirm the
  component keeps that behaviour in the modal and Command views.
- RQ-E5-2: which `data-*` selectors the browser spec relies on, so the split keeps them.
- RQ-E5-3: whether the Command detail page (`DashboardLive :decision`) can host the voice hook
  without the drawer's hook element.

## 10. Plan refresh

- After **MP-R5**: `Aiur.ElevenLabs.*`, `AiurWeb.Voice*` move to the voice package (VOX #36).
  Update C2 paths; the channel's injected `voice_stt_start_fun` becomes the package behaviour.
- After **MP-R1/U8 WEB split**: `dashboard_live.ex` handlers move; C4/C5 cite the new module.
- After **MP-E7**: `AgentChat.send/3` call sites are replaced by the listener send; E5 only
  changes if the Send button's handler name changes.
- After **MP-E3**: the Executor composer's module path is known; C5 binds to it.

## 11. Phase C resolutions (2026-10-06)

- RQ-E5-1 resolved (MP-E5-C1-T03): server echo of the textarea can overwrite partials; a
  `dom.onBeforeElUpdated` guard keeps the local value while `data-voice-recording="true"`.
- RQ-E5-2 resolved (MP-E5-C1-T01): selector list recorded; all preserved.
- RQ-E5-3 resolved (MP-E5-C1-T03): a standalone `VoiceInput` hook is required; the drawer
  hook is the only place the controller is built today.
- RC-14 applied: `Aiur.Voice` facade and `{:voice_transcript | :voice_error | :voice_closed}`;
  RC-16 applied: new chunk C8. §2's `Voice.capabilities/0` is replaced by MP-R1 capability
  IDs `voice.stt` / `voice.tts` (voice-session §7).
- E5 depends on MP-R5-C1 as a hard predecessor (no in-core fallback seam): wave 4 follows
  wave 1.
- RC-29 (Phase D): chunk C8 (device voice path) ships in **wave 5**, after MP-N2-C6, because it
  needs N2 device tokens. C1-C7 stay in wave 4. RC-30: MP-E6-C7-T01 no longer waits for C8.
