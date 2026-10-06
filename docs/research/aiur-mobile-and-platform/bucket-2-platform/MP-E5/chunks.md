---
feature_id: MP-E5
base_main_sha: 45a290e3
date: 2026-10-06
parent: plan.md
---

# MP-E5 — Chunks

Every ticket carries `Base-SHA: 45a290e3`, `Prior-boundaries: VOX, WEB` (plus `DEC` for C4),
`Prior-features: ui-07, ui-08`. Tickets marked **[gate]** are blocked on DESIGN-E5.

## MP-E5-C1 — Reusable voice input component (behaviour-preserving)

- **Outcome:** the drawer's voice markup becomes a `voice_input` function component, and the
  539-line `conversation-voice-controller.js` splits into capture, transport and UI modules
  (each < 500 lines). The drawer looks and behaves exactly as today, including both existing
  buttons.
- **Depends on:** none in E5. `Size-owner: BROWSER` (controller), `WEB` (drawer). Coordinate
  with U8 if U8 has already claimed the split.
- **Tickets:**
  - MP-E5-C1-T1 Extract `<.voice_input>` from `conversation_drawer.ex:184-231`; keep every
    `data-voice-*` attribute and copy.
  - MP-E5-C1-T2 Split the controller into `voice-capture.js`, `voice-transport.js`,
    `voice-input.js`; `layouts.ex:40` loads them; hook name unchanged.
- **Tests:** existing `conversation_drawer_test.exs` and `units.browser.spec.mjs` pass
  unchanged; add a render test asserting the component output equals the pre-extraction
  markup for the drawer (snapshot of attributes, not styles).
- **Phase C questions:** RQ-E5-2 (selectors the browser spec relies on).

## MP-E5-C2 — Target-aware dictate channel and render-time capability

- **Outcome:** voice-session contract §3.2 join payload (`mode`, `surface`, `target`,
  `client_session_id`) on a `voice:dictate` topic with `voice:dictation` kept as an alias;
  `cancel` event; `reason_code` on errors; `Voice.capabilities/0` (contract §7) available to
  LiveViews at render.
- **Depends on:** MP-R5 seam if landed (otherwise the in-core module with the same seam);
  identity contract target shapes.
- **Tickets:**
  - MP-E5-C2-T1 Join validation: capability, target exists and is writable (worker via the
    same check as `composer_writable`; Command via `DecisionStore` read; Executor via MP-E3).
  - MP-E5-C2-T2 `cancel` handler: `Realtime.stop/1`, release lease, push `stopped{cancelled:
    true}`; no transcript commit.
  - MP-E5-C2-T3 `reason_code` mapping for every existing message (`voice_channel.ex:54-56,93,
    254-266`), message text unchanged.
  - MP-E5-C2-T4 `Voice.capabilities/0` with statuses `available | unconfigured |
    not_installed | degraded`; assign in `DashboardLive` mount.
- **Tests:** channel tests for each refusal code; alias topic still joins; cancel never emits
  a final transcript (fake transcriber records that `commit` was not called).
- **Non-happy:** stale auth generation still stops the channel (`voice_channel.ex:184-191`).

## MP-E5-C3 — D16 mode choice **[gate]**

- **Outcome:** every voice-enabled surface presents the explicit Dictate / Converse choice in
  the form DESIGN-E5 approves (E5-OQ1). Converse is shown only when `voice.converse` is
  available (MP-E6) or as decided in E5-OQ2.
- **Depends on:** C1, C2, DESIGN-E5.
- **Tickets:**
  - MP-E5-C3-T1 Choice control in `<.voice_input>` (two buttons or chooser per design).
  - MP-E5-C3-T2 Converse hand-off: the Converse button opens the MP-E6 conversation panel for
    the same target (no-op link until E6-C7 ships).
  - MP-E5-C3-T3 Existing auto-submit loop per E5-OQ2 (keep under its own label, or remove).
- **Tests:** browser test: no `getUserMedia` before a click; each button starts only its mode;
  Converse absent when the capability is not `available`.

## MP-E5-C4 — Dictated Command responses **[gate]**

- **Outcome:** the Command answer form (`decision_action.ex:97-106`) and the revision form
  (`decision_revision_action.ex:120`) carry `<.voice_input>` bound to the custom-response
  field; dictated text is reviewed and submitted with the existing `answer-decision` event.
- **Depends on:** C1–C3, MP-E2 contract (answer payload unchanged or as reconciled),
  DESIGN-E2 §4 presentation, DESIGN-E5.
- **Tickets:**
  - MP-E5-C4-T1 Mic on the custom-response field; per E5-OQ3, starting dictation selects
    "Custom response" and appends to existing text.
  - MP-E5-C4-T2 Version-conflict path: dictated text survives a stale `expected_version`
    rejection; idempotency key generated once per form, not per dictation.
  - MP-E5-C4-T3 Field length: stop capture with a notice when the field reaches 4,000
    characters (`decision_action.ex:102`).
- **Tests:** LiveView: dictated text → `answer-decision` payload has `choice=custom` and the
  text; stale version leaves the text in the field; double Send records once.

## MP-E5-C5 — Executor composer and agent log modal **[gate]**

- **Outcome:** `<.voice_input>` on the agent log modal composer (`agent_log_modal.ex:43`) and
  on the MP-E3 Executor composer.
- **Depends on:** C1–C3; MP-E3 composer (for T2); MP-E7 send.
- **Tickets:**
  - MP-E5-C5-T1 Agent log modal voice (same target rules as the drawer).
  - MP-E5-C5-T2 Executor composer voice; target `{kind: executor}`.
- **Tests:** each surface's Send handler receives the dictated text unchanged; Executor target
  validation refuses when no Executor is live.

## MP-E5-C6 — States, cancel, errors and delivery feedback **[gate]**

- **Outcome:** the DESIGN-E5 state set (idle, requesting permission, listening, finishing,
  ready to review, cancelled, error, sending, sent/delivered/failed) with approved copy; an
  explicit Cancel control; post-Send delivery state taken from the MP-E7 / MP-E2 status, not
  invented by the voice layer.
- **Depends on:** C2, C3; MP-E7 delivery status events; MP-E2 delivery status.
- **Tickets:**
  - MP-E5-C6-T1 State machine in `voice-input.js` with one status line per state.
  - MP-E5-C6-T2 Cancel button and `Escape` key restore pre-recording text.
  - MP-E5-C6-T3 Delivery indicator subscribed to the send result (`message_id`).
- **Tests:** browser test steps through every state with a fake channel; mutation check:
  replace the `unavailable` branch with the `available` copy and confirm the test fails
  (AGENTS.md unknown-path rule).

## MP-E5-C7 — Docs and end-to-end verification

- **Outcome:** docs updated in the same PRs as C3–C6 (AGENTS.md "Docs ship with the change");
  a manual verification script using the AGENTS.md wrapper-tmux recipe plus a real browser on
  the dashboard.
- **Tickets:**
  - MP-E5-C7-T1 `website/docs-app/apis/elevenlabs.md`: surfaces table and the contract §10
    privacy table.
  - MP-E5-C7-T2 Dashboard guide page section for voice input (existing guide page; no new page).
  - MP-E5-C7-T3 Manual test checklist: each surface × {dictate, cancel, no key, permission
    denied, stale Command}.

## Dependency summary

```text
C1 ──► C2 ──► C3 ──┬─► C4 (needs MP-E2)
                   ├─► C5 (T2 needs MP-E3, MP-E7)
                   └─► C6 (needs MP-E7 status) ──► C7
DESIGN-E5 gates C3–C6.
```

## Phase C changes (2026-10-06)

Ticket docs: [tickets/README.md](tickets/README.md) (19 tickets, 8 ready, 11 blocked).

- **New chunk MP-E5-C8 — device-authenticated voice path (RC-16).** C8-T01: `POST
  /api/v1/device/voice-ticket` (60 s `Phoenix.Token`, device-auth plug, writable gate) and
  socket `/voice/device`; C8-T02: re-check the device every 15 s and end sessions on
  revocation. Consumed by MP-N6/N7. Contract: voice-session §3.5.
- **C1 gains T03** (standalone `VoiceInput` hook). RQ-E5-3 finding: the controller is
  constructed by the drawer hook (`conversation-drawer-hook.js:16-17`), so other surfaces need
  their own hook. RQ-E5-1 resolved with a `dom.onBeforeElUpdated` guard while recording.
  RQ-E5-2 selectors listed in C1-T01.
- **C1-T02 keeps the file name** `conversation-voice-controller.js` for the UI module and
  splits out `voice-capture.js` and `voice-transport.js` (tests and globals depend on the
  old name).
- **C2 tickets regrouped:** T01 = topic + v1 payload + target validation + `reason_code`
  (old T1+T3); T02 = cancel; T03 = capabilities, now the MP-R1 IDs `voice.stt`/`voice.tts`
  instead of a separate `Voice.capabilities/0` map.
- **C4:** T01 answer form (with the field-wait and the 4,000-character stop: a script-set
  value bypasses `maxlength`); T02 revision form with a `command_revision` target rule
  (revisions target answered Commands, `decision_revision_action.ex:43`). The old C4-T2
  (idempotency) needs no code: `ensure_action_key/2` already keys per decision per LiveView.
- **C7** is one verification + docs-audit ticket; per-surface docs ship inside each ticket.
