---
ticket_id: MP-N1-C4-T03
feature_id: MP-N1
chunk_id: MP-N1-C4
bucket: 3-mobile-watch
title: WebView origin confinement (external links to the system browser) and the allow-listed WebView-to-native message bridge
status: blocked
blocked_by: [DESIGN-N1, RQ-TRANSPORT, MP-N2-C10-T01, MP-N1-C4-T02]
prior_units: []
prior_boundaries: ["WEB #34"]
prior_features: []
prior_findings: []
size_owner: n/a (new package)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C4-T03 — Origin confinement and bridge allow-list

Candidate tickets merged: N1-C4-T3 (origin confinement, AC7) and N1-C4-T4 (bridge allow-list);
both are the WebView's policy handlers in one component.

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C4.
- **User value:** a link in an agent's output (GitHub PR, docs, anything) can never take over
  the authenticated dashboard view, and the dashboard can ask the native app for only three
  well-defined things.
- **Deliverable:** in `InstanceScreen`:
  - `onShouldStartLoadWithRequest`: allow only top-frame and sub-frame navigations whose
    origin (scheme + host + port) equals the instance origin; everything else is cancelled and,
    for `http(s)` URLs on a user tap, opened with `expo-web-browser`
    (`SFSafariViewController` / Custom Tabs). Non-http schemes (`tel:`, `mailto:`, `intent:`,
    `javascript:`) are dropped.
  - `onOpenWindow` (`target="_blank"`) → same external rule.
  - `onMessage` bridge: accept only when `nativeEvent.url` has the instance origin, the data is a
    JSON string ≤ 4 KiB, and `type` ∈ {`open-native-command`, `session-expired`,
    `request-mic-permission`} with the exact payload shapes below. Everything else is dropped
    and counted in a debug counter (no payload logged).

```ts
type BridgeMessage =
  | { v: 1; type: "open-native-command"; decision_id: string }      // → Command route for this instance
  | { v: 1; type: "session-expired" }                                 // → MP-N1-C4-T02 rebootstrap
  | { v: 1; type: "request-mic-permission" };                         // → MP-N1-C4-T05 OS prompt
```
- **Non-goals:** emitting the messages from the dashboard (MP-N1-C4-T04).

## Dependencies and blockers

- DESIGN-N1 (surface 9 external-link behaviour; D-N1-1 row 4), RQ-TRANSPORT /
  MP-N2-C10-T01 (RC-15: loads a dashboard), MP-N1-C4-T02.

## Verified starting point (base 45a290e3)

- The dashboard renders external links with `target="_blank"` in 6 places under
  `src/lib/aiur_web` (`git grep -n 'target="_blank"' 45a290e3 -- src/lib/aiur_web`).
- surface-boundary.md §2 rules 2 (bridge, three messages) and 3 (navigation containment; 2.5.6
  posture).
- External (accessed 2026-10-06): `react-native-webview` `onShouldStartLoadWithRequest`
  ("Not called on first load on Android"), `onMessage` (no origin restriction of its own; event
  carries `url`), `originWhitelist` default `http://*`/`https://*`
  (<https://github.com/react-native-webview/react-native-webview/blob/master/docs/Reference.md>);
  Expo `expo-web-browser` `openBrowserAsync` (<https://docs.expo.dev/versions/latest/sdk/webbrowser/>);
  App Review 2.5.6 "Apps that browse the web must use the appropriate WebKit framework"
  (<https://developer.apple.com/app-store/review/guidelines/>, S1).

## Chosen design

- `originWhitelist={[instanceOrigin]}` **and** `onShouldStartLoadWithRequest` (belt and braces:
  the whitelist alone opens non-matching URLs via the OS on some platforms, which is the
  wanted external behaviour only after our checks).
- First-load gap on Android is harmless: the first load is our own constructed URL.
- `decision_id` validated as the same shape the dashboard route accepts
  (`/commands/:decision_id`, `router.ex:143`): non-empty, ≤ 128 chars, `[A-Za-z0-9_-]`.
  **UNVERIFIED** exact decision-id alphabet; the implementer reads `Aiur.Decision` id generation
  (`src/lib/aiur/decision.ex`) and tightens the regex.
- Rationale for a JSON envelope with `v`: the dashboard and app ship independently.

## Implementation steps

1. `src/shell/webviewPolicy.ts`: `isSameOrigin(url, origin)`, `classifyNavigation(req)` →
   `allow | external | drop`.
2. `src/shell/bridge.ts`: `parseBridgeMessage(event, origin)` → `BridgeMessage | null`.
3. Wire both into `InstanceScreen`.

## Non-happy paths

- Redirect from the instance to another origin (e.g. a misconfigured proxy): dropped; screen
  shows the error state with cause `cross_origin_redirect`.
- Malicious page content (an agent writes HTML into a transcript the dashboard renders):
  cannot navigate the WebView elsewhere and cannot call native beyond the three messages;
  `open-native-command` only opens a screen that re-fetches by `decision_id` with the device's
  own credential (no action without the user).
- Message flood: max 10 messages/second per WebView; extra dropped.

## Compatibility and rollout

- Client-only. Old dashboards send no messages; everything works without the bridge.

## Verification

- `npm --prefix packages/aiur-mobile test -- test/shell/webviewPolicy.test.ts test/shell/bridge.test.ts`:
  - `github link opens externally` (AC7) — `https://github.com/o/r/pull/1` → `external`.
    Mutation: allow all https → fails.
  - `same host different port is cross-origin` — `https://h:4001` vs origin `https://h:4000` →
    not allowed. Mutation: compare hostname only → fails.
  - `javascript: and intent: schemes dropped`.
  - `bridge rejects message from another origin`, `rejects unknown type`, `rejects > 4 KiB`,
    `rejects bad decision_id`. Mutation: skip the origin check → first case fails.
- **Device:** iPhone A (iOS 17.x) and Android phone A (Android 13+): open an agent chat containing
  a GitHub PR link, tap → system browser sheet; Back returns to the dashboard still signed in.
  Part of **DV-P6**.

## Completion and handoff

- [ ] AC7 test green; device check recorded.
- **Docs:** `guide/mobile.md`: "Links to GitHub open in your browser".
- **Dependents:** MP-N1-C4-T04 (emitter), MP-N1-C4-T05 (mic message).
