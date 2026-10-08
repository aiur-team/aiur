---
ticket_id: MP-E5-C1-T03
feature_id: MP-E5
chunk_id: MP-E5-C1
bucket: 2-platform
title: Standalone VoiceInput LiveView hook so voice can live outside the conversation drawer
status: ready
blocked_by: ["DESIGN-E5 (waived for this ticket: no surface renders the hook yet)", MP-E5-C1-T01, MP-E5-C1-T02]
prior_units: [U8]
prior_boundaries: [VOX, WEB]
prior_features: [ui-07]
prior_findings: []
size_owner: BROWSER (layouts.ex is 336 lines; new hook file is small)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C1-T03 — Standalone `VoiceInput` hook (resolves RQ-E5-3)

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C1.
- **User value:** none visible yet. It is the enabler for voice on the Command answer form,
  the revision form, the agent log modal and the Executor composer (C4, C5).
- **Deliverable:** `src/priv/static/voice-input-hook.js` (PROPOSED) exporting
  `window.AiurVoiceInputHook`, registered as `Hooks.VoiceInput` in `layouts.ex`, plus a
  `hook` attribute on `<.voice_input>` that lets a caller wrap the composer in an element
  carrying `phx-hook="VoiceInput"`.
- **Non-goals:** attaching it to any surface (C4, C5 do that); changing the drawer, which
  keeps its own `ConversationDrawer` hook.

## Dependencies and blockers

- **Predecessors:** MP-E5-C1-T01 (component), MP-E5-C1-T02 (split modules).
- **May run concurrently with:** MP-E5-C2-*.

## Verified starting point (base `45a290e3`)

**RQ-E5-3 finding.** The voice controller is not a hook of its own. It is constructed inside
the drawer hook: `conversation-drawer-hook.js:16-17` (`new
window.AiurConversationVoiceController(this); this.voice.mount()`), rebound in `updated()`
(`:33`) and destroyed in `destroyed()` (`:42`). The controller binds only to elements inside
`this.hook.el` (`conversation-voice-controller.js:27-55`). So the Command detail page
(`live("/commands/:decision_id", DashboardLive, :decision)`, `router.ex:143`) cannot host voice
today: it has no drawer hook. A standalone hook that does the same three calls answers the
question with no change to the controller.

| Item | Evidence |
| --- | --- |
| Hook registry | inline script in `src/lib/aiur_web/components/layouts.ex:54-270`; pattern `if (window.AiurConversationDrawerHook) { Hooks.ConversationDrawer = ... }` (`:249-251`) |
| LiveSocket | `layouts.ex:272-273` |
| Controller reply scan | `replyElements()` looks for `.conversation-message-agent[data-message-complete='true']` inside the hook element (`:375-377`); outside the drawer it finds none, which is correct (no legacy conversation mode there, C1-T01 `legacy_conversation: false`) |
| LiveView patching and the voice textarea (RQ-E5-1) | the drawer textarea has `phx-change="composer-change"` (`conversation_drawer.ex:169`) and server-echoed value `{@drafts[@composer_key]}` (`:182`); the controller writes partials and dispatches a bubbling `input` event (`conversation-voice-controller.js:349-350`), and locks the field read-only while recording (`:94-98`). The Command answer textarea is also server-echoed (`decision_action.ex:99-105`, `phx-change="decision-action-change"` `:58`). Same pattern; see "Non-happy paths" for the patch race and its guard. |

## Chosen design

```js
// voice-input-hook.js (PROPOSED)
window.AiurVoiceInputHook = {
  mounted()   { this.voice = new window.AiurConversationVoiceController(this); this.voice.mount(); },
  updated()   { this.voice.bindElements(); },
  destroyed() { this.voice.destroy(); },
};
```

- Registered in `layouts.ex` beside `:249-251`: `if (window.AiurVoiceInputHook) {
  Hooks.VoiceInput = window.AiurVoiceInputHook; }`. Loaded with `<script defer
  src="/voice-input-hook.js">` after the controller; added to `static_assets.ex:13-27`.
- The hook element must contain the form's textarea (`data-voice-input`), the Send button
  (`data-voice-send`) and the `<.voice_input>` subtree, because the controller queries inside
  `hook.el`. Callers therefore put `phx-hook="VoiceInput"` and a stable `id` on the **form**.
- **Patch race (RQ-E5-1).** Partials can arrive faster than the `phx-change` round trip, so
  the server may re-render an older value into the textarea. The hook element gets
  `phx-update` unchanged, but the textarea receives `data-voice-input` **and** the hook marks
  it with `data-voice-recording="true"` while recording; a LiveView `onBeforeElUpdated`
  callback in `layouts.ex` (`dom: {onBeforeElUpdated(from, to) {...}}` option of `LiveSocket`)
  copies `from.value` to `to.value` when `from.dataset.voiceRecording === "true"`. This keeps
  the local value authoritative only during capture; after stop the server value (which by
  then holds the final text via the last `input` event) wins as today. `dom.onBeforeElUpdated`
  is a documented `LiveSocket` option (phoenix_live_view `1.1.33` per `src/mix.lock`;
  <https://hexdocs.pm/phoenix_live_view/js-interop.html>, accessed 2026-10-06); `layouts.ex:272-284`
  passes no `dom` option today, so there is nothing to merge with.

## Implementation steps

1. Add `voice-input-hook.js`; add to static allowlist, layout `<script>` list and
   `fixture_server.exs`.
2. Register `Hooks.VoiceInput` in `layouts.ex`.
3. In the controller, set/clear `this.input.dataset.voiceRecording` in `start` (after
   `this.recording = true`, `:166`) and in `disposeCapture` (`:506-515`).
4. Add the `dom.onBeforeElUpdated` guard to the `LiveSocket` options (`layouts.ex:272`).
5. Add a browser fixture page that renders a plain form with `phx-hook="VoiceInput"` (no
   drawer) for the tests below.

## Non-happy paths

- Hook element without a textarea: `bindElements` leaves `this.input` undefined and the mic
  stays inert (existing guard `start()` returns early when `!this.mic`, `:135`). The test below
  asserts no `getUserMedia` call happens.
- LiveView reconnect during recording: the element is re-mounted; `destroyed()` disposes
  capture and closes the channel (existing `destroy()`, `:525-535`).
- Two hooks on one page (drawer and a Command form): each owns its controller and channel;
  the limiter allows two per dashboard authority (`voice_session_limiter.ex:12`).

## Compatibility and rollout

No server change, no flag. The `onBeforeElUpdated` guard is inert unless
`data-voice-recording="true"` is set, which only the voice controller does. Rollback: revert.

## Verification

| Test (browser, `units.browser.spec.mjs`, PROPOSED names) | Expected |
| --- | --- |
| "VoiceInput hook dictates into a standalone form and waits for Send" | fake socket/worklet as in `:382-492`; partial then final text lands in the form textarea; no submit event fired |
| "VoiceInput hook never requests the microphone before a click" | `navigator.mediaDevices.getUserMedia` spy count is 0 after mount and after a LiveView patch |
| "a server patch during recording does not overwrite dictated partials" | push a patch that re-renders the textarea with the older value while `data-voice-recording="true"`; textarea keeps the newer value |
| "after stop, server value wins again" | with the flag cleared, a patch replaces the value |

```bash
env -C src/browser npm run test:units
env -C src mise exec -- mix test test/aiur/extensions_test.exs
make -C src fmt-check lint
```

**Mutation check.** Remove the `onBeforeElUpdated` hunk: the "server patch during recording"
test must fail. Remove the `Hooks.VoiceInput` registration: the standalone dictation test must
fail.

## Completion and handoff

- [ ] Hook file, registration and patch guard landed; four browser tests green.
- [ ] RQ-E5-1 and RQ-E5-3 marked resolved in `../plan.md` §9 (done in Phase C).
- [ ] Docs: none (no surface uses it yet).
- **Dependents:** MP-E5-C4-T01, MP-E5-C4-T02, MP-E5-C5-T01, MP-E5-C5-T02.
