---
ticket_id: MP-E5-C1-T02
feature_id: MP-E5
chunk_id: MP-E5-C1
bucket: 2-platform
title: Split conversation-voice-controller.js into capture, transport and controller modules
status: ready
blocked_by: ["DESIGN-E5 (waived for this ticket: behaviour-preserving split, DESIGN-E5 header)", MP-R5-C1-T02]
prior_units: [U8]
prior_boundaries: [VOX, WEB]
prior_features: [ui-07, ui-08]
prior_findings: []
size_owner: BROWSER (conversation-voice-controller.js, 539 lines, over the 500-line U8 ceiling)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C1-T02 — Split the browser voice controller

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C1 (behaviour-preserving).
- **User value:** none visible. It brings a 539-line file under the U8 500-line ceiling and
  gives MP-E6-C7 (converse panel) and later WebView clients a capture module and a
  transport module they can reuse without the dictation UI logic.
- **Deliverable:** three classic (non-module) scripts in `src/priv/static/`:
  - `voice-capture.js` (PROPOSED) — `window.AiurVoiceCapture`: microphone open,
    AudioWorklet wiring, downsample to 16 kHz, PCM16 little-endian + base64 encode, waveform
    column buffer, device enumeration and the `localStorage` device preference.
  - `voice-transport.js` (PROPOSED) — `window.AiurVoiceTransport`: socket construction
    (`window.AiurVoiceSocket || window.Phoenix.Socket`), CSRF param, topic join,
    `on(event, handler)` fan-out, `push`, `leave`/`disconnect`.
  - `conversation-voice-controller.js` (existing file name kept) — the
    `ConversationVoiceController` class (state flags, `syncElements`, `toggle`, `start`,
    `stop`, `applyTranscript`, conversation-mode reply/playback, `explainFailure`), now
    delegating capture and transport.
- **Non-goals:** no behaviour, copy, event or topic change; no new mode; no Cancel (C6).

## Dependencies and blockers

- **Predecessors:** MP-R5-C1-T02 (scheduling only). No dependency on C1-T01 (different files).
- **Coordinate with U8:** if U8 has already claimed the BROWSER split of this file, this
  ticket becomes "adopt U8's split and verify the exports listed here".
- **May run concurrently with:** MP-E5-C1-T01, MP-E5-C2-*.

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| File and size | `src/priv/static/conversation-voice-controller.js`, 539 lines, IIFE exporting `window.AiurConversationVoiceController` (`:1-2,538-539`) |
| Capture code | `openCapture` (`:195-211`, loads `/voice-capture-worklet.js`, node name `aiur-voice-capture`), `handleSamples` (`:274-288`), `downsample` (`:290-303`), `pushWaveform`/`resetWaveform`/`drawWaveform` (`:305-343`), `refreshDevices` (`:104-125`), `rememberDevice` (`:57-61`), `disposeCapture` (`:506-515`) |
| Transport code | `openChannel` (`:213-258`): `new VoiceSocket("/voice", {params: {_csrf_token}})`, topic `voice:conversation` or `voice:dictation`, handlers `transcript`, `error`, `stopped`, `audio`, `audio_done`, `audio_error`, `onError`, `onClose`; `closeChannel` (`:517-523`) |
| Loaders | `src/lib/aiur_web/components/layouts.ex:40-41` (`<script defer>` for the controller, then the drawer hook); static allowlist `src/lib/aiur_web/static_assets.ex:13-27` (`conversation-voice-controller.js`, `voice-capture-worklet.js`); browser fixture `src/test/browser/fixture_server.exs:31` |
| Tests that load it | `src/test/aiur/extensions_test.exs:1062,1108-1109,1542,1559-1561` (served, contains `AiurConversationVoiceController`); `src/browser/tests/units.browser.spec.mjs:326-690` |
| Hook | `src/priv/static/conversation-drawer-hook.js:16-17,33,42` constructs and drives the controller |

## Chosen design

- Keep the existing file name for the controller so `extensions_test.exs` and every cached
  page keep working, and so the global `AiurConversationVoiceController` stays where tests
  look for it.
- Capture and transport are plain objects with no DOM knowledge beyond a canvas handle, so
  MP-E6-C7 and a later device WebView can reuse them.
- Interfaces (all PROPOSED):

```js
// voice-capture.js
window.AiurVoiceCapture = {
  async open({ deviceId, onPcmBase64, onLevels, echoCancellation = false }) -> Capture,
  async listMicrophones() -> [{ deviceId, label }],
  rememberDevice(deviceId), recalledDevice() -> string,
};
// Capture: { stop() }   // stops tracks, disconnects nodes, closes the AudioContext
// voice-transport.js
window.AiurVoiceTransport = {
  open({ path = "/voice", params, topic, joinPayload = {}, handlers }) -> Promise<Transport>,
};
// Transport: { push(event, payload), close() }
```

- `echoCancellation` defaults to `false`, today's `getUserMedia({audio})` request
  (`:153-155`); MP-E6-C7-T04 passes `true`.
- Load order in `layouts.ex`: `voice-capture.js`, `voice-transport.js`,
  `conversation-voice-controller.js`, `conversation-drawer-hook.js`. All `defer`, so document
  order is execution order.

## Implementation steps

1. Move the capture functions listed above into `voice-capture.js`; the controller keeps the
   `generation` guard (`current(generation)`, `:191-193`) and calls `AiurVoiceCapture.open`.
2. Move `openChannel`'s socket/channel construction into `voice-transport.js`; the controller
   passes its handlers (unchanged bodies) and keeps the "stale channel" checks.
3. Add both files to `@revalidated_static_paths` (`static_assets.ex:13-27`), to
   `layouts.ex` before `:40`, and to `fixture_server.exs` before `:31`.
4. Update `extensions_test.exs` asset loops (`:1542`) to include the two new paths.

## Non-happy paths

Unchanged by construction: insecure origin and missing Web Audio (`:18-22`), permission and
no-device copy (`:446-454`), transport loss (`:249-250`), 5 s final-transcript timeout
(`:268-271`), late microphone after modal close (spec `:354`). If `voice-capture.js` fails to
load, `AiurVoiceCapture` is undefined: the controller calls `disable("Microphone dictation is
unavailable because a dashboard script did not load.")` — this is the only new string, shown
only when an asset is missing. **DESIGN-E5 copy note:** listed in DESIGN-E5 §5 for approval;
until approved the controller reuses the existing "This browser does not support microphone
dictation with the Web Audio API." sentence so no unapproved copy ships.

## Compatibility and rollout

Static assets are revalidated (`cache_control_for_etags: "private, max-age=0,
must-revalidate"`, `endpoint.ex:33-39`), so a reload picks up the new files. A page loaded
before deploy keeps its old single script until reload. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| All voice tests in `units.browser.spec.mjs` (`:326`, `:354`, `:382`, `:494`, `:545`, `:622`, `:659`) | pass unchanged |
| new browser test "voice capture module encodes 16 kHz PCM16 little-endian base64" (in `units.browser.spec.mjs`) | feeding `[0, 1, -1]` at 16 kHz yields base64 of `00 00 ff 7f 00 80` |
| new browser test "voice transport joins the requested topic with the CSRF param" | fake `AiurVoiceSocket` records `/voice`, `params._csrf_token`, topic `voice:dictation` |
| `extensions_test.exs` asset-served tests | new paths return 200 |
| `wc -l src/priv/static/{voice-capture,voice-transport,conversation-voice-controller}.js` | each < 500 |

```bash
env -C src/browser npm run test:units
env -C src mise exec -- mix test test/aiur/extensions_test.exs
make -C src fmt-check lint
```

Run Elixir tests in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and
hash-check `~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** The PCM test must fail if the `setInt16(..., true)` little-endian flag
(today `:283`) is flipped to `false` in `voice-capture.js`. The transport test must fail if the
topic argument is ignored (hard-code `voice:dictation` and pass `voice:conversation`).
Existing browser tests are regression guards for the split, not new coverage.

## Completion and handoff

- [ ] Three files, each < 500 lines; globals exported as specified.
- [ ] Existing browser and Elixir asset tests green; two new browser tests green.
- [ ] Docs: none (internal refactor).
- **Dependents:** MP-E5-C1-T03, MP-E5-C2-T02 (cancel uses transport `push("cancel")`),
  MP-E5-C6-*, MP-E6-C7-T01, MP-E6-C7-T04.
