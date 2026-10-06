---
ticket_id: MP-N1-C4-T05
feature_id: MP-N1
chunk_id: MP-N1-C4
bucket: 3-mobile-watch
title: WebView microphone permission — grant capture only to the paired instance origin, OS permission flow on both platforms
status: blocked
blocked_by: [DESIGN-N1, DESIGN-E5, RQ-TRANSPORT, MP-N2-C10-T01, MP-N1-C4-T03, MP-N1-C4-T04]
prior_units: []
prior_boundaries: ["VOX #36"]
prior_features: [MP-E5]
prior_findings: [N1-RQ6 (new)]
size_owner: n/a (new package)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C4-T05 — WebView media-capture permission

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C4.
- **User value:** the dashboard's existing dictation and conversation mic works inside the app
  on an HTTPS instance, with one OS prompt, and no other web origin can ever use the mic.
- **Deliverable:**
  - iOS: `NSMicrophoneUsageDescription` (copy from DESIGN-E5/N1) in `app.config.ts`
    `ios.infoPlist`; `mediaCapturePermissionGrantType="grantIfSameHostElseDeny"` on the WebView.
  - Android: `RECORD_AUDIO` and `MODIFY_AUDIO_SETTINGS` in the manifest (Expo `android.permissions`);
    runtime request on `request-mic-permission` (bridge) via `expo-audio`/`PermissionsAndroid`;
    WebView `PermissionRequest` granted for `RESOURCE_AUDIO_CAPTURE` **only** when
    `request.origin` equals the instance origin (N1-RQ6 below).
  - Mic affordance state in the native header / diagnostics from the capability model
    (`needs_permission` when denied; `unavailable/insecure_context` under HTTP-degraded).
- **Non-goals:** native mic capture (MP-N6, using the RC-16 device-authenticated voice path from
  MP-E5); choosing Dictate vs Converse (D16; the dashboard already offers both, DESIGN-E5).

## Dependencies and blockers

- DESIGN-N1, **DESIGN-E5** (mic copy and controls), **RQ-TRANSPORT / MP-N2-C10-T01** (secure
  context requires HTTPS; RC-15).
- MP-N1-C4-T03 (bridge), MP-N1-C4-T04 (dashboard posts `request-mic-permission`).

## Verified starting point (base 45a290e3)

- Dashboard voice controller disables the mic when `!window.isSecureContext` with "Microphone
  access requires HTTPS or localhost…" (`src/priv/static/conversation-voice-controller.js:18-19`)
  and calls `getUserMedia({ audio })` on user action (`:155`). So the HTTP-degraded mode already
  degrades truthfully inside the page.
- `/voice` socket requires a CSRF token, session and `dashboard_writable`
  (`src/lib/aiur_web/voice_socket.ex:21-37`); the WebView session from MP-N1-C4-T02 satisfies the
  session part; writability is the operator's setting.
- External (accessed 2026-10-06):
  - `getUserMedia` works in `WKWebView` from iOS 14.3; `requestMediaCapturePermissionFor` lets the
    app decide per origin (iOS 15) (WWDC21 10032, <https://developer.apple.com/videos/play/wwdc2021/10032/>, S17).
  - `react-native-webview` `mediaCapturePermissionGrantType` (iOS 15+; values include
    `grantIfSameHostElseDeny`) (<https://github.com/react-native-webview/react-native-webview/blob/master/docs/Reference.md>).
    Note "same **host**": two instances on one host differ only by port; navigation confinement
    (MP-N1-C4-T03) already restricts loads to one origin, so host granularity is sufficient.
  - Android `WebChromeClient.onPermissionRequest(PermissionRequest)` with `getOrigin()` and
    `getResources()` (<https://developer.android.com/reference/android/webkit/PermissionRequest>).
- **N1-RQ6 (new, UNVERIFIED):** how the pinned `react-native-webview` Android client handles
  `onPermissionRequest` (whether it checks origin, whether it requests `RECORD_AUDIO` itself). The
  implementer reads `RNCWebChromeClient` in the pinned version and records the lines. If it grants
  without an origin check, apply a `patch-package` patch adding the origin comparison, recorded
  in `UPGRADING.md` so it is re-checked on every upgrade.

## Chosen design

- No auto-record: the WebView never starts capture by itself; capture begins only from the
  dashboard's own button handler (brief N6). The app adds nothing that calls `getUserMedia`.
- Permission order: dashboard posts `request-mic-permission` → native requests the OS permission
  if undetermined (Android runtime; iOS prompts on first WebKit capture) → page's `getUserMedia`
  proceeds. If the OS permission is denied, native posts nothing back; the page's
  `getUserMedia` rejects and the dashboard shows its existing error, while the native header
  shows `needs_permission` with a Settings link (DESIGN-N1 §4).

## Implementation steps

1. `app.config.ts`: iOS usage string; Android permissions.
2. `InstanceScreen`: `mediaCapturePermissionGrantType="grantIfSameHostElseDeny"`;
   `allowsInlineMediaPlayback` and `mediaPlaybackRequiresUserAction={false}` only if DESIGN-E5's
   Converse playback needs them (the controller resumes an `AudioContext` on the click, `:146-151`).
3. Bridge handler for `request-mic-permission` → `ensureMicPermission()` (native module method,
   returns `granted | denied | blocked`).
4. N1-RQ6 investigation and optional patch.

## Non-happy paths

- Permission permanently denied → `needs_permission` + Settings deep link
  (`Linking.openSettings()`).
- HTTP-degraded → page already disables; header shows `unavailable` (`insecure_context`).
- Dashboard read-only (`dashboard_writable` false) → `/voice` join refused; dashboard's existing
  message; header shows the `voice.stt` capability state.
- Other origin requesting capture (should be impossible after confinement) → denied.

## Compatibility and rollout

- Adds a privacy usage string and permissions: App Store privacy label and Play data-safety
  updates are MP-N1-C8-T02 (audio is streamed to the daemon's provider, never retained, D17).

## Verification

- Jest: `InstanceScreen sets grantIfSameHostElseDeny` and `request-mic-permission calls
  ensureMicPermission once per page load`. Mutation: set `grant` → first test fails.
- Android instrumented (if the patch is needed): `PermissionOriginTest` feeding a fake
  `PermissionRequest` with another origin → `deny()` called. Mutation: remove the check → fails.
  Command: `./gradlew :app:connectedDebugAndroidTest --tests '*PermissionOriginTest*'` in the
  generated `android/`.
- **Device (DV-P7, required):** iPhone A (iOS 17.x), iPhone on iOS 26.x, Android phone A
  (Android 13+). On an HTTPS instance: open a worker chat, press Dictate → one OS prompt → allow →
  transcript returns. Second session: no prompt. On an HTTP-degraded instance: the mic shows
  unavailable with the HTTPS reason. Deny then retry → `needs_permission` with Settings link
  (DV-P12). Record device, OS build, app SHA.

## Completion and handoff

- [ ] DV-P7 and the mic part of DV-P12 recorded on both platforms.
- [ ] N1-RQ6 answered with source lines.
- **Docs:** `guide/mobile.md` "Dictation in the app needs HTTPS".
- **Dependents:** MP-N1-C8-T02 (privacy disclosures), MP-N6 (native mic shares the permission state).
