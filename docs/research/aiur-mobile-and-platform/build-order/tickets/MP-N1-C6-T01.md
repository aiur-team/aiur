---
ticket_id: MP-N1-C6-T01
feature_id: MP-N1
chunk_id: MP-N1-C6
bucket: 3-mobile-watch
title: "Push plumbing in the app shell: aps-environment and FCM build config, native device-token getter, hand-off points for MP-N4 and MP-N6"
status: blocked
blocked_by: [DESIGN-N1, DESIGN-N4, MP-N1-C1-T03, MP-N1-C2-T05, MP-N1-C4-T01, OQ-N4-1]
prior_units: []
prior_boundaries: []
prior_features: [MP-N4, MP-N6]
prior_findings: []
size_owner: n/a (new package code)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C6-T01 — Push plumbing (client side of MP-N4, wiring only)

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C6 "Notification plumbing".
- **User value:** the app can receive APNs and FCM pushes at all, so MP-N4's decrypting
  extension/service and MP-N6's tap routing have a place to run.
- **Deliverable:**
  1. iOS: `aps-environment` entitlement (development/production by build profile) and the
     Push Notifications + Background Modes `remote-notification` **off** (no background fetch is
     relied on, plan §8), via `app.config.ts`; the NSE target folder from MP-N1-C1-T03 stays the
     extension that MP-N4-C4 fills. **Time Sensitive capability (Phase D feasibility m7):** the
     app target carries `com.apple.developer.usernotifications.time-sensitive` = `true` (Xcode
     capability "Time Sensitive Notifications"), because DESIGN-N4 D-3 may choose
     `interruption-level: time-sensitive` and the level is set by the NSE after decryption
     (notification contract §5, no level in clear). Without the entitlement iOS would downgrade
     the level silently. Whether an NSE-set level is honoured is device row MP-N4 V-I5.
     The app badge is set by the NSE / FCM service from the decrypted `summary.badge`
     (notification contract §3, Phase D); this ticket only requests the `.badge` authorization
     option alongside `.alert` and `.sound` in the permission call that MP-N4-C4 owns.
  2. Android: Firebase Messaging dependency and a `FirebaseMessagingService` subclass **declaration**
     (`AiurMessagingService`, class body owned by MP-N4-C5-T02) registered in the manifest through
     an Expo config plugin; `google-services.json` read from an operator-supplied path at build
     time (`AIUR_GOOGLE_SERVICES_JSON`), never committed.
  3. A native token getter that MP-N4-C4-T05 / MP-N4-C5-T05 call **inside native code**;
     JavaScript gets only `AiurNative.pushToken(): Promise<{platform: "apns"|"fcm",
     fingerprint: string /* 8 chars */} | {unavailable: reason}>` (Phase D, B4; the token
     itself never crosses the bridge). `expo-notifications` `getDevicePushTokenAsync` must not
     be used, because it returns the token to JS. Reasons `permission_denied |
     not_configured | unknown`.
  4. A single event `AiurNative.onNotificationOpened(cb)` that forwards the **already-decrypted
     destination** (set by MP-N4's NSE/service in `userInfo` / intent extras under the key
     `aiur.destination`, notification contract §3.1 rule 5) to JS; MP-N6-C2-T02
     owns what happens next (routing, cold/warm start).
- **Non-goals:** decryption, presentation, channels and `POST_NOTIFICATIONS` (MP-N4-C4/C5);
  relay registration (MP-N4-C4-T05, MP-N4-C5-T05); tap routing logic (MP-N6-C2-T02).

## Mapping from Phase B candidates

N1-C6-T01 (NSE target) → MP-N1-C1-T03 + MP-N4-C4; N1-C6-T02 (FCM service) → MP-N4-C5 except the
build plumbing here; N1-C6-T03 (tap routing) → MP-N6-C2-T02; N1-C6-T04 (token hand-off) → this
ticket's `pushToken()` + MP-N4-C4-T05/C5-T05.

## Dependencies and blockers

- DESIGN-N4 (no UI here, but the permission timing belongs to that design and DESIGN-N2 first run).
- MP-N1-C1-T03 (targets and entitlements plumbing), MP-N1-C2-T05 (module), MP-N1-C4-T01 (routes).
- OQ-N4-1 (paid Apple and Firebase accounts): device builds with `aps-environment` and a
  Firebase project need them; simulator/emulator builds and unit tests do not.

## Verified starting point (base `45a290e3`)

- No mobile code; MP-N4 chunks assign NSE decrypt to MP-N4-C4-T01..T05 and the Android service to
  MP-N4-C5-T01..T05 (`bucket-3-mobile-watch/MP-N4/chunks.md`).
- Expo (accessed 2026-10-06, page updated 2026-07-28): an NSE "is not formally included" but can
  be added with a config plugin; `expo-notifications` can return the native device token for
  direct APNs/FCM use (<https://docs.expo.dev/guides/using-push-notifications-services/>).
- Android 13+ needs `POST_NOTIFICATIONS` (MP-N1 framework-evidence S30) — requested by MP-N4-C5-T03.
- iOS does not relaunch a force-quit app for background pushes (S41): nothing here depends on a
  background launch.

## Chosen design

- Direct APNs/FCM tokens, never Expo's push service (Cloudflare/Expo infrastructure must not be
  mandatory; MP-N4 relay owns delivery).
- The token is handed to MP-N4's registration code inside native (not JS) when available; JS
  only sees it for the diagnostics screen as a short fingerprint (first 8 hex chars).

## Implementation steps

1. `app.config.ts` entitlements and `plugins/withFirebaseMessaging.ts` (PROPOSED).
2. Native `pushToken` and `onNotificationOpened` in the module. About 120 lines plus config.

## Non-happy paths

Permission denied → `pushToken` returns `permission_denied` and the push affordance resolves to
`needs_permission` (client-capability-model.md §5); missing `google-services.json` → Android build
succeeds with push `not_configured`; token rotation → MP-N4 re-registers (C4-T05/C5-T05).

## Compatibility and rollout

Requires OQ-N4-1 for real devices. No server change.

## Verification

- Jest `plugins/__tests__/withFirebaseMessaging.test.ts`: manifest contains the service with
  `exported=false` and the `com.google.firebase.MESSAGING_EVENT` intent filter; no
  `google-services.json` path → plugin emits the `not_configured` build constant. Mutation: drop
  the intent filter → fails.
- Jest `plugins/__tests__/withPushEntitlements.test.ts`: the generated iOS entitlements contain
  `com.apple.developer.usernotifications.time-sensitive: true` and `aps-environment`. Mutation:
  drop the time-sensitive key → fails.
- Jest `src/api/__tests__/pushToken.test.ts`: JS receives a fingerprint, never the full token
  (mutation: return the full token → fails).
- `npm --prefix packages/aiur-mobile run check:targets` (MP-N1-C1-T03) still passes with the
  entitlement added.

```bash
npm --prefix packages/aiur-mobile test -- plugins src/api/__tests__/pushToken.test.ts
```

Device rows run in MP-N1-C10-T01 after MP-N4-C4/C5: DV-P11, DV-P12, and the push rows linked from DV-P1/DV-P4 to the canonical MP-N4 matrix (V-I1..I5, V-A1..A6; Phase D M4).

## Completion and handoff

- [ ] Tests pass; mutation checks recorded.
- [ ] Docs: mobile build guide lists `AIUR_GOOGLE_SERVICES_JSON` and the Apple push capability
      (build-time variables, not operator runtime env, so not AGENTS.md Auth), and the Time
      Sensitive capability.
- [ ] Dependents: MP-N4-C4-T05, MP-N4-C5-T02/T05, MP-N6-C2-T02.
