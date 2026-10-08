---
ticket_id: MP-N1-C1-T03
feature_id: MP-N1
chunk_id: MP-N1-C1
bucket: 3-mobile-watch
title: Wire expo-apple-targets with the shared app-group and keychain-group entitlements and prove they survive prebuild --clean (resolves N1-RQ3)
status: blocked
blocked_by: [DESIGN-N1, MP-N1-C1-T01, OQ-N1-1]
prior_units: []
prior_boundaries: []
prior_features: []
prior_findings: [N1-RQ3]
size_owner: n/a (new package)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C1-T03 — Apple targets plumbing and entitlements (N1-RQ3)

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C1.
- **User value:** the iOS Notification Service Extension (MP-N4-C4) and the watchOS app
  (MP-N7-C2) can be added as small target folders without hand-editing a generated Xcode
  project, and they share keys with the app safely.
- **Deliverable:** `expo-apple-targets` (pinned) added as a config plugin; one **placeholder**
  `notification-service` target in `packages/aiur-mobile/targets/notification-service/`
  (PROPOSED) whose Swift code only passes the content through unchanged; the app's
  `ios.entitlements` declare the app group `group.dev.aiur.mobile` and the keychain access
  group `$(AppIdentifierPrefix)dev.aiur.mobile.shared`, mirrored into the target; a script
  that runs `expo prebuild --clean` twice and asserts the entitlements in the generated
  project are identical and present for app and target. This settles N1-RQ3.
- **Non-goals:** any decryption (MP-N4-C4-T02), the watch target (MP-N7-C2-T01 adds
  `targets/watch` with the same mechanism), signing and provisioning profiles (MP-N1-C8-T01).

## Dependencies and blockers

- DESIGN-N1; MP-N1-C1-T01.
- OQ-N1-1 (distribution) only for the bundle-id prefix: the app group and keychain group need
  a registered Apple Developer team to *sign* on device. Building for the simulator with
  `CODE_SIGNING_ALLOWED=NO` does not. The device half of verification therefore waits for the
  paid Apple account (DESIGN-N4 OQ-N4-1, the main mobile blocker).
- Concurrent with MP-N1-C1-T02.

## Verified starting point (base 45a290e3)

- Nothing Apple-target related exists in the repo (baseline N1).
- External (accessed 2026-10-06):
  - `expo-apple-targets` README (<https://github.com/EvanBacon/expo-apple-targets>,
    community, no release number on the page; requires "CocoaPods 1.16.2 (ruby 3.2.0),
    Xcode 16 (macOS 15 Sequoia), and Expo SDK +53"): targets live in `/targets/<name>/`
    with an `expo-target.config.js`; supported types include `watch`, `notification-service`;
    targets "that can utilize App Groups will automatically mirror the
    `ios.entitlements['com.apple.security.application-groups']` array"; "changes made outside
    the target folders don't persist through `expo prebuild --clean`".
  - Expo: an NSE is "not formally included" but can be added with a config plugin
    (<https://docs.expo.dev/guides/using-push-notifications-services/>, updated 2026-07-28, S21).
  - NSE runs only for alert pushes with `mutable-content: 1`
    (<https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension>, S2).
- **UNVERIFIED** (this ticket verifies): whether `keychain-access-groups` is mirrored like app
  groups. If not, the target's `expo-target.config.js` sets
  `entitlements: { "keychain-access-groups": [...] }` explicitly.

## Chosen design

- **Mechanism:** `expo-apple-targets` (community, S22) instead of a hand-written config plugin.
  Rationale: it is the maintained path for NSE and watch targets under CNG; the fallback if it
  breaks on an SDK upgrade is to vendor its target template into a local config plugin, which
  this ticket documents in `UPGRADING.md` (no code now).
- **Shared groups (fixed names, used by MP-N1-C2-T01, MP-N4-C4-T01, MP-N7-C2-T01):**
  - App group: `group.dev.aiur.mobile` (seen-`nid` store, snapshot files).
  - Keychain access group: `<TeamID>.dev.aiur.mobile.shared`.
  - Final identifiers follow DESIGN-N1 D-N1-4; the constants live in one file
    `packages/aiur-mobile/app.identifiers.ts` (PROPOSED) imported by `app.config.ts` and the
    target configs, so a rename is one edit.
- **Placeholder NSE:** `NotificationService.swift` calls `contentHandler(request.content)`
  immediately. It exists so the plumbing is testable now; MP-N4-C4 replaces its body.

## Implementation steps

1. `npm i -E expo-apple-targets@<pinned>`; add to `plugins` in `app.config.ts`.
2. Create `app.identifiers.ts` with bundle id, app group, keychain group suffix.
3. `app.config.ts`: `ios.entitlements` with `com.apple.security.application-groups` and
   `keychain-access-groups`.
4. `targets/notification-service/expo-target.config.js`: `type: "notification-service"`,
   explicit `entitlements` for both groups, deployment target = app's.
5. `targets/notification-service/NotificationService.swift`: pass-through.
6. `scripts/check-prebuild-targets.mjs`: runs `npx expo prebuild --platform ios --clean
   --no-install` twice into the package, then parses
   `ios/<App>/<App>.entitlements` and `ios/<target>/*.entitlements` (plist via the `plist` npm
   package) and exits non-zero unless both files contain both groups, and the two runs are
   byte-identical. Wire as `npm run check:targets` and call it from the `ios` CI job
   (MP-N1-C1-T02).

## Non-happy paths

- **Plugin incompatible with a new Expo SDK:** `check:targets` fails in CI on the upgrade PR;
  the upgrade note template requires running it.
- **Entitlement not mirrored:** explicit target entitlements (step 4) make mirroring
  irrelevant; the check proves presence either way.
- **Security:** the keychain group is shared only by targets in this app's bundle; no
  `kSecAttrAccessGroup` wildcard.

## Compatibility and rollout

- Additive; no daemon change. Rollback: remove the plugin and the target folder.
- On device, the NSE ships in every build from now on; pass-through behaviour equals "no NSE"
  for users (the OS shows the original alert).

## Verification

- `npm --prefix packages/aiur-mobile run check:targets` (macOS) — passes.
  Mutation 1: remove `keychain-access-groups` from the target config → fails if mirroring
  does not cover it (recording the finding settles the UNVERIFIED line). Mutation 2: remove the
  app group from `app.config.ts` → fails.
- CI `ios` job builds app + NSE for the simulator (`xcodebuild … -scheme <App> …
  CODE_SIGNING_ALLOWED=NO build`); the `.appex` exists under
  `Build/Products/Debug-iphonesimulator/<App>.app/PlugIns/`.
- **Device (deferred until the Apple account exists):** iPhone slot "iPhone A" (iOS 17.x,
  the D-N1-3 minimum) and a second iPhone on iOS 26.x: install a signed debug build; from the
  app, write a keychain item in the shared group; from the NSE (debug-only code path behind
  `#if DEBUG`) read it when a test push arrives. Pass: the NSE reads the value. This is the
  plumbing precondition for device-validation.md DV-P1/DV-P3; record device model, OS build and
  app SHA in the ticket.

## Completion and handoff

- [ ] `check:targets` green twice in a row in CI.
- [ ] N1-RQ3 answer recorded in this ticket (mirroring behaviour; any explicit overrides).
- [ ] Device keychain-share check run, or explicitly recorded as "not validated: no Apple
  account" in the readiness report.
- **Docs:** `guide/mobile.md` gains "iOS targets" (how to add a target folder). No config keys.
- **Dependents:** MP-N1-C2-T01 (keychain wrapper uses the group), MP-N4-C4-T01..T02 (NSE body),
  MP-N7-C2-T01 (watch target).
