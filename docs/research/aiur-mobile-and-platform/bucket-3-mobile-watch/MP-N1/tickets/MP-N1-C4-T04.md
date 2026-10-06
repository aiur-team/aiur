---
ticket_id: MP-N1-C4-T04
feature_id: MP-N1
chunk_id: MP-N1-C4
bucket: 3-mobile-watch
title: Dashboard-side native bridge emitter (feature-detected; no behaviour change in a browser)
status: blocked
blocked_by: [DESIGN-N1, DESIGN-N6, MP-N1-C4-T03]
prior_units: [U6]
prior_boundaries: ["WEB #34 (web-shell / dashboard-ui)"]
prior_features: [MP-E5]
prior_findings: []
size_owner: "U8 ledger owner of src/lib/aiur_web/components/layouts.ex (U6 scope src/lib/aiur_web/)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C4-T04 — Dashboard emits bridge messages when hosted by the app

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C4. Owned code area: dashboard-ui (daemon).
- **User value:** inside the phone app, tapping a Command in the dashboard opens the native
  Command screen (options + explicit mic, MP-N6); a dead session is recovered silently; and the
  OS mic prompt is shown before in-page dictation starts. In a normal browser nothing changes.
- **Deliverable:** a small inline script in the root layout plus one line in the voice
  controller:
  1. `window.AiurNativeBridge.post(msg)` defined **only** when `window.ReactNativeWebView` has a
     `postMessage` function; otherwise `window.AiurNativeBridge` is `undefined`.
  2. `open-native-command {decision_id}`: a delegated click listener for `a[href^="/commands/"]`
     that, when the bridge exists **and** the app announced support
     (`window.AiurNativeShell?.v === 1 && window.AiurNativeShell.commands === true`, injected by the
     app with `injectedJavaScriptBeforeContentLoaded`), prevents default and posts the message.
  3. `session-expired`: a LiveView hook `NativeSession` on a hidden element carrying
     `data-financial-state` (`authorized`/`locked`, from the `financial_data_capability` assign set
     by `FinancialDataAccess.on_mount`); when mounted or updated with `locked`, it posts once.
  4. `request-mic-permission`: in `conversation-voice-controller.js` immediately before
     `getUserMedia`, post the message if the bridge exists (fire-and-forget; capture proceeds as today).
- **Non-goals:** any visual change; moving surfaces to native (surface-boundary §3).

## Dependencies and blockers

- DESIGN-N1 (sign-off line: it touches the dashboard, chunks.md N1-C4-T05) and **DESIGN-N6**
  (whether a dashboard Command tap in the app goes native is a Command-response UX decision).
- MP-N1-C4-T03 (message schema and native acceptance).
- Not blocked on RQ-TRANSPORT: the emitter is inert in browsers and testable without TLS.
- Plan refresh: U6 / MP-R1-C6 (web-shell / dashboard-ui split) may move `layouts.ex`; re-cite
  paths at implementation.

## Verified starting point (base 45a290e3)

- Root layout script builds `Hooks` and creates the LiveSocket inline:
  `src/lib/aiur_web/components/layouts.ex:244-287` (`new window.LiveView.LiveSocket("/live", …)`
  at `:272`); `app/1` wraps content in `<main class="app-shell">` (`layouts.ex:299-306`).
- `on_mount` assigns `:financial_data_capability` with `state: :authorized` or the locked map
  (`src/lib/aiur_web/financial_data_access.ex:98-111`, `locked_capability/0` at `:143-152`).
- Voice capture: `src/priv/static/conversation-voice-controller.js:18-21` (secure-context and API
  checks) and `:155` (`navigator.mediaDevices.getUserMedia({ audio })`).
- Command routes: `/commands/:decision_id` (`src/lib/aiur_web/router.ex:143`).
- Browser test harness: `src/browser/package.json` scripts run Playwright specs through
  `scripts/run-browser-tests.mjs` against a fixture server (`fixture:server`), e.g.
  `test:command-history` → `tests/command-history.browser.spec.mjs`.

## Chosen design

- Feature detection only; no user-agent sniffing. The app sets `window.AiurNativeShell = {v: 1,
  commands: <bool>}` so the dashboard never intercepts Command links in an app build that lacks
  the native Command screen (MP-N6 not shipped yet → `commands: false`).
- `NativeSession` hook is registered unconditionally but posts nothing without the bridge.
- Messages are `JSON.stringify` of the MP-N1-C4-T03 shapes with `v: 1`.

## Implementation steps

1. `layouts.ex` root script: define `AiurNativeBridge` (≤ 25 lines JS), the delegated click
   listener, and `Hooks.NativeSession`.
2. `layouts.ex` `app/1`: add `<div id="aiur-native-session" phx-hook="NativeSession" hidden
   data-financial-state={…}>` — the state comes from `@financial_data_capability.state` when the
   assign exists (`Map.get(assigns, :financial_data_capability, %{})`), else `authorized` is
   **not** assumed: emit `unknown` and the hook ignores `unknown`.
3. `conversation-voice-controller.js`: one guarded `window.AiurNativeBridge?.post({v: 1, type:
   "request-mic-permission"})` before `getUserMedia`.
4. New Playwright spec `src/browser/tests/native-bridge.browser.spec.mjs` and script entry
   `test:native-bridge` (added to the aggregate `test` script).

## Non-happy paths

- No bridge (all browsers): zero behaviour change — asserted by test.
- Bridge but `commands: false`: links navigate normally inside the WebView.
- Locked state flapping: the hook posts at most once per page load.
- Security: the dashboard posts only its own state; it never receives data from native (no
  `window.ReactNativeWebView` message listener is added). A hostile page in the same origin is
  already the instance itself.

## Compatibility and rollout

- Backward compatible: old apps ignore messages; old dashboards send none.
- No config key; no flag. Rollback: revert the commit.

## Verification

- `env -C src/browser npm run test:native-bridge` (needs `mise exec -- mix compile` via the
  `fixture:preflight` step; never `mix test`):
  - `no bridge: command link navigates and no AiurNativeBridge global` — mutation: define the
    bridge unconditionally → fails.
  - `bridge + commands:true: click posts open-native-command and does not navigate` — stub
    `window.ReactNativeWebView = {postMessage: m => window.__msgs.push(m)}` via `addInitScript`.
    Mutation: remove `preventDefault` → URL changes → fails.
  - `bridge + commands:false: link navigates`.
  - `locked session posts session-expired exactly once` (fixture page rendered without session
    proof). Mutation: post on every update → count assertion fails.
  - `mic button posts request-mic-permission before getUserMedia` (stubbed `getUserMedia`
    records call order, as `units.browser.spec.mjs:332-390` already stubs it).
- ExUnit (only if step 2 adds a function component): `layouts` render test asserting the hidden
  element and `data-financial-state` value; run with
  `mise exec -- mix test test/aiur_web/<new>_test.exs` from `src/` **with `HOME` set to a temp
  dir and `GITHUB_TOKEN`/`GH_TOKEN` unset** (local `mix test` can overwrite
  `~/.aiur/github-budget/agent-token`).

## Completion and handoff

- [ ] Browser specs pass; mutations fail.
- [ ] DESIGN-N1 sign-off line and DESIGN-N6 decision recorded.
- **Docs:** none (no user-visible change in a browser; app docs mention native Command screens in
  MP-N6).
- **Dependents:** MP-N1-C4-T05 (mic), MP-N6 native Command screen enabling `commands: true`.
