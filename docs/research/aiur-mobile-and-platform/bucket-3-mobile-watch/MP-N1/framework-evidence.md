---
feature_id: MP-N1
research_question: MP-Q4
base_main_sha: 45a290e3
date: 2026-10-06
status: evidence for the plan in plan.md
---

# MP-Q4 evidence — mobile framework, WebView boundary, watch targets

This file holds the external evidence behind the MP-N1 and MP-N7 recommendations.
Every source was accessed on **2026-10-06**. Where a page shows a version or an
update date, it is recorded. Claims that only a vendor or community source
supports are marked **[non-authoritative]**. Claims that no source confirmed are
marked **UNVERIFIED** and become Phase C research or device-validation items.

## 1. Sources

| ID | Source (accessed 2026-10-06) | Version or date shown | What it establishes |
|---|---|---|---|
| S1 | Apple App Review Guidelines, https://developer.apple.com/app-store/review/guidelines/ | No revision date on the page | 4.2, 4.2.2, 4.2.3, 2.1(a), 2.5.4, 2.5.6 text (quoted in §3) |
| S2 | `UNNotificationServiceExtension`, https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension | iOS 10.0+, watchOS 6.0+ | An NSE can "decrypt an encrypted data block". It runs only for alert notifications with `mutable-content: 1`. "You can't modify silent notifications." |
| S3 | `didReceive(_:withContentHandler:)`, same doc set | — | "no more than 30 seconds". On timeout the system shows the original content. Alert text can change but not be removed. |
| S4 | "Modifying content in newly delivered notifications", https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications | — | Apple's own example decrypts a secret message in an NSE. The payload needs `mutable-content` and an `alert` with title, subtitle or body. |
| S5 | `kSecAttrAccessibleAfterFirstUnlock`, https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlock | iOS 4.0+, watchOS 2.0+ | Item is unreadable after a restart until the first unlock. It is "recommended for items that need to be accessed by background applications". |
| S6 | WatchConnectivity, `WCSession`, `sendMessage(_:replyHandler:errorHandler:)`, `isReachable`, https://developer.apple.com/documentation/watchconnectivity | iOS 9.0+, watchOS 2.0+ | `sendMessage` from the watch "wakes up the corresponding iOS app in the background"; from the phone it "does not wake up" the watch extension. `transferUserInfo` and `transferFile` queue in the background. Background transfers "are not delivered immediately". |
| S7 | TN3135 "Low-level networking on watchOS", https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos | Revised 2026-07-16 | `URLSessionWebSocketTask` is low-level networking. watchOS allows it only for audio streaming while streaming, VoIP during a CallKit call, or a tvOS service listener. Otherwise connections stay `.waiting` with `ENETDOWN`. The simulator always allows it. |
| S8 | "Creating independent watchOS apps", https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps | — | Dependent vs independent watch apps. "Independent watchOS apps can't rely on the WatchConnectivity framework to transfer data." |
| S9 | `SFSpeechRecognizer`, https://developer.apple.com/documentation/speech/sfspeechrecognizer | Platforms: iOS, iPadOS, Mac Catalyst, macOS, visionOS (no watchOS) | The Speech framework is not available to watch apps. |
| S10 | `AVAudioRecorder`, https://developer.apple.com/documentation/avfaudio/avaudiorecorder | watchOS 4.0+ | A watch app can record audio to a file. |
| S11 | `presentTextInputController(withSuggestions:…)` (watchOS 2.0+); `UNTextInputNotificationAction` (watchOS 3.0+) | — | System text input with suggested phrases and dictation; text-input notification actions on the watch. |
| S12 | `WKApplicationDelegate.didRegisterForRemoteNotifications(withDeviceToken:)` | watchOS 7.0+ | A watch app can hold its own APNs token. |
| S13 | Xcode 14 release notes, https://developer.apple.com/go/?id=xcode-14-sdk-rn | Xcode 14 | WatchKit storyboards are deprecated in watchOS 7+. New watch apps are a single SwiftUI target. |
| S14 | watchOS release notes, https://developer.apple.com/documentation/watchos-release-notes; release 26.6 (23U67), https://developer.apple.com/news/releases/?id=07272026f | watchOS 26.6, 2026-07-27 | Current watchOS line. The watchOS 27 status in October 2026 is **UNVERIFIED**; Phase C pins the SDK. |
| S15 | Apple Support "Notifications on your Apple Watch", https://support.apple.com/en-us/108369 | — | iPhone notifications appear on the watch when the iPhone is locked or asleep and the watch is unlocked on the wrist. |
| S16 | `NSAppTransportSecurity`, `NSAllowsLocalNetworking`, `NSAllowsArbitraryLoadsInWebContent`, https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity | — | ATS requires HTTPS. A web-content exemption needs a justification at App Review. **Correction (Phase D feasibility m4):** the claim "since iOS 17, ATS no longer allows connections to IP addresses by default" is **not** on this page (documentation JSON re-read 2026-10-06). Its source is Apple DTS forum replies, e.g. https://developer.apple.com/forums/thread/747421 (accessed 2026-10-06), **[non-authoritative]**. Device row MP-N2-C10-T05 settles it. It matters only under transport T-B with a raw tailnet IP; under T-A (MagicDNS host name) it is moot. |
| S17 | WWDC21 "Explore WKWebView additions", https://developer.apple.com/videos/play/wwdc2021/10032/ (plus WebKit bug 208667) | iOS 14.3+, iOS 15 delegate | `getUserMedia` works in `WKWebView` from iOS 14.3. `requestMediaCapturePermissionFor` lets the app grant capture per origin. |
| S18 | TestFlight, https://developer.apple.com/testflight/ | — | Up to 100 internal testers. External testers (up to 10,000) need a build approved by App Review for TestFlight. |
| S19 | React Native blog, https://reactnative.dev/blog | 0.87 (2026-08-11), 0.86 (2026-06-11) | 0.82 is the first release that runs entirely on the New Architecture. 0.84 removed the Legacy Architecture components. |
| S20 | Expo SDK reference, https://docs.expo.dev/versions/latest/ | SDK 57.0.0 → React Native 0.86 | Current Expo SDK. |
| S21 | Expo "Using push notifications services", https://docs.expo.dev/guides/using-push-notifications-services/ | Updated 2026-07-28 | An iOS NSE "is not formally included" but can be added with a config plugin. `expo-notifications` can return the native device token for direct APNs or FCM use. |
| S22 | `expo-apple-targets` README, https://github.com/EvanBacon/expo-apple-targets **[non-authoritative, community]** | Needs Expo SDK 53+ and Xcode 16 | Config plugin targets include `watch`, `watch-widget`, `notification-service` and `notification-content`, kept outside the generated `/ios` folder. |
| S23 | `react-native-webview` README, https://github.com/react-native-webview/react-native-webview **[community]** | New Architecture only; iOS 15.1+ | Maintained community WebView, used by Expo. |
| S24 | Capacitor config, https://capacitorjs.com/docs/config; Capacitor iOS, https://capacitorjs.com/docs/ios | Capacitor v8; Xcode 26.0+ | `server.url` "is intended for use with live-reload servers. This is not intended for use in production." |
| S25 | Flutter what's new, https://docs.flutter.dev/release/whats-new; supported platforms, https://docs.flutter.dev/reference/supported-platforms | Flutter 3.47 (2026-08-12) | Neither watchOS nor Wear OS is a supported deployment platform. |
| S26 | Kotlin Multiplatform supported platforms, https://kotlinlang.org/docs/multiplatform/supported-platforms.html | Page updated 2025-09-10 | Compose Multiplatform is Stable on iOS and Android. KMP watchOS targets are Beta. |
| S27 | Google Play "Functionality, content and user experience", https://support.google.com/googleplay/android-developer/answer/9898783 | — | "We do not allow apps that only have limited functionality and content." Webviews are not named in that section. |
| S28 | Google Play internal testing, https://support.google.com/googleplay/android-developer/answer/9845334 | — | Internal testing is for up to 100 testers and "might not be subject to standard Play policy or security reviews". |
| S29 | FCM message priority, https://firebase.google.com/docs/cloud-messaging/android/message-priority | — | High priority can wake a dozing device. `onMessageReceived` gets "several seconds". High-priority messages that do not produce a visible notification are deprioritized (7-day window). |
| S30 | Android notification permission, https://developer.android.com/develop/ui/views/notifications/notification-permission | — | Android 13+ needs `POST_NOTIFICATIONS`, which is off by default on new installs. |
| S31 | Network security configuration, https://developer.android.com/privacy-and-security/security-config | Updated 2026-08-28 | Cleartext is off by default for target API 28+. Opt-in is per domain. |
| S32 | Wear OS Data Layer, https://developer.android.com/training/wearables/data/data-layer | Updated 2026-09-28 | Needs Google Play services. It **does not work when the watch is paired with an iPhone**. Do not use it as the primary network path. |
| S33 | Wear OS notification bridging, https://developer.android.com/training/wearables/notifications/bridger | — | Phone notifications bridge to the watch by default. `setBridgeTag`, `BridgingConfig`, `setDismissalId` and `setLocalOnly` control this. |
| S34 | Wear OS standalone apps, https://developer.android.com/training/wearables/apps/standalone-apps | — | `com.google.android.wearable.standalone` true or false. Non-standalone apps are not offered on untethered watches. New apps target API 34+. |
| S35 | Wear OS network access, https://developer.android.com/training/wearables/data/network-access | Updated 2026-09-22 | With a phone connected, traffic is "generally proxied through the phone"; otherwise Wi-Fi or LTE. Whether the phone's VPN covers proxied traffic is not documented: **UNVERIFIED**. |
| S36 | Wear OS voice input, https://developer.android.com/training/wearables/user-input/voice | Updated 2024-11-12 | `RecognizerIntent.ACTION_RECOGNIZE_SPEECH` for free-form speech; `MediaRecorder` for recording. |
| S37 | Wear Compose releases, https://developer.android.com/jetpack/androidx/releases/wear-compose | 1.7.0 stable, 2026-09-23 | Compose for Wear OS. Material 3 for Wear supersedes `compose-material`. |
| S38 | Pixel Watch compatibility, https://support.google.com/googlepixelwatch/answer/12652073 | — | Pixel Watch requires an Android phone; iPhones are not supported. |
| S39 | Pushover knowledge base, https://support.pushover.net/s1-pushover/knowledgebase/top/c5-iphone-ipad-apple-watch **[non-authoritative, vendor]** | — | A shipping E2E-encrypted push app reports that NSE-decrypted text is what iOS forwards to Apple Watch. Device validation (DV-W1) must confirm this. |
| S41 | `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`, https://developer.apple.com/documentation/uikit/uiapplicationdelegate/application(_:didreceiveremotenotification:fetchcompletionhandler:) | iOS 7.0+ | Up to 30 s of background time. "The system does not automatically launch your app if the user has force-quit it." |
| S40 | Tailscale issue #12177, https://github.com/tailscale/tailscale/issues/12177 **[non-authoritative]** | — | Tailscale failing on a Galaxy Watch. No official Tailscale client for watchOS or Wear OS was found. |

## 2. What the repository forces (verified at `45a290e3`)

| Fact | Evidence | Consequence for MP-Q4 |
|---|---|---|
| The dashboard is Phoenix LiveView, served over plain HTTP only | `src/lib/aiur/http_server.ex:64` (`http: [ip: ip, port: port]`), `:147` builds `http://…` URLs; `src/lib/aiur/config/schema/server.ex:12-13` has only `port` and `host` | iOS ATS blocks HTTP and, per non-authoritative DTS replies, raw IP addresses on iOS 17+ (S16, corrected in Phase D; device row MP-N2-C10-T05). An HTTP origin is not a secure context, so `getUserMedia` (dashboard dictation) cannot run in a WebView on HTTP. Transport security is a hard prerequisite (owned by MP-N2/MP-R3; see plan.md §5). |
| LiveView routes are in one `live_session` gated by Basic Auth and a session proof | `router.ex:133-151` (`live_session :dashboard` at `:139`); `financial_data_access.ex:50-90` (Basic Auth, then a session marker) | A WebView can host these pages unchanged once it holds a valid session. The shared Basic Auth pair is not a per-device credential, so pairing (MP-N2) must mint the session. |
| JSON writes need a same-origin `Origin` and `X-Aiur-Request: 1` | `router.ex:50-53`, `:215-224`, `:247-256` | A native client sending JSON writes needs a device-authenticated API path, not the browser CSRF scheme (MP-N2 and MP-E2 own it). |
| The `/voice` socket requires a CSRF token, a session and `dashboard_writable` | `voice_socket.ex:21-37`; `endpoint.ex:26-29` | Native mic capture cannot reuse `/voice` as is. A device-credential voice path is an MP-E5/MP-R5 contract item. |
| The dashboard is already responsive | `layouts.ex:20` (viewport meta), `:23` (apple-touch-icon); `dashboard.css` has 39 `@media` rules: 20 width breakpoints from 320 to 1024 px, 8 `prefers-reduced-motion`, 5 `forced-colors`, 1 `pointer: coarse` | WebView reuse of the per-instance dashboard is realistic for reading. Native screens are needed only where the plan says why (surface-boundary.md). |
| The Command payload already carries notification and response fields | `decision.ex:21-27,120-126` (`urgency`, `blocking`, `context.short_summary`, `options`, `recommendation`) | The native Command screen and the watch render from the MP-E2 contract, not from scraped HTML. |
| Existing TypeScript client packaging precedent | `packages/streamdeck/package.json` (standalone npm package, not a root workspace); `.github/workflows/streamdeck-package.yml` path-filtered CI | A separate `packages/aiur-mobile` with its own path-filtered workflow matches house style. MP-R1 already proposes `packages/aiur-mobile` and `packages/aiur-contracts` (TS types) (`bucket-1-refactor/MP-R1/component-map.md` rows `mobile-app`, `aiur-contracts`). |

## 3. App Store and Play review facts (S1, S27)

Quoted from S1:

- **4.2:** "Your app should include features, content, and UI that elevate it beyond a repackaged website. If your app is not particularly useful, unique, or 'app-like,' it doesn't belong on the App Store."
- **4.2.2:** "Other than catalogs, apps shouldn't primarily be marketing materials, advertisements, web clippings, content aggregators, or a collection of links."
- **4.2.3(i):** "Your app should work on its own without requiring installation of another app to function."
- **2.1(a):** "…include demo account info (and turn on your back-end service!) if your app includes a login. If you are unable to provide a demo account … you may include a built-in demo mode in lieu of a demo account with prior approval by Apple. Ensure the demo mode exhibits your app's full features and functionality."
- **2.5.6:** "Apps that browse the web must use the appropriate WebKit framework and WebKit JavaScript."
- **2.5.4:** background services only "for their intended purposes".

What this means here, as stated by the guidelines and not as a promise of approval:

1. A shell that only loads a private dashboard URL is the 4.2 "repackaged website" case. The native surfaces in surface-boundary.md exist for UX reasons (notifications, mic, meta-dashboard, watch). They also move the app away from that case. **No feature set guarantees approval** (brief §6 N1).
2. **The reviewer cannot reach a private aiur daemon.** For public App Store or external TestFlight review, 2.1(a) requires a demo account or an approved built-in demo mode. A paired machine behind a tailnet is neither. So a public release needs a **demo mode** with synthetic instances (chunk N1-C7). Internal TestFlight (S18) and Play internal testing (S28) avoid the review gate for up to 100 testers. Whether a public listing is wanted at all is an owner question (OQ-N1-1).
3. 4.2.3(i): the app needs an aiur machine. It does not need another *app* installed, so 4.2.3(i) is not obviously triggered, but the demo mode also covers "works on its own" during review. **UNVERIFIED** how App Review treats a companion-to-self-hosted-server app; settle only by a submission.
4. Play's policy (S27) does not name webviews in the limited-functionality section. The same native surfaces apply.
5. An HTTP WebView needs `NSAllowsArbitraryLoadsInWebContent` or per-domain exceptions, each with a review justification (S16). HTTPS removes this risk.

## 4. Phone framework comparison

Criteria come from brief §6 N1. Scores are qualitative; the reasons are cited.

| Criterion | React Native + Expo (CNG) | Capacitor | Flutter | Native ×2 (SwiftUI + Compose) | KMP + Compose Multiplatform |
|---|---|---|---|---|---|
| Current, supported | RN 0.87 (S19); Expo SDK 57 / RN 0.86 (S20) | v8 (S24) | 3.47 (S25) | Platform SDKs | CMP iOS Stable; KMP watchOS Beta (S26) |
| Host the existing LiveView dashboard | `react-native-webview` (S23) | Native, but loading a remote origin through `server.url` is "not intended for production" (S24); needs custom navigation | `webview_flutter` | `WKWebView` / Android `WebView` | Platform WebView via expect/actual |
| Native screens (meta-dashboard, Command, pairing) | Yes, one TS codebase | Web UI, or a native plugin per screen | Yes, one Dart codebase | Yes, written twice | Yes, one Kotlin codebase |
| iOS NSE for E2E push (must be native in every option, S2) | Swift target via config plugin (S21, S22) | Add a Swift target in Xcode | Add a Swift target | Swift target | Swift target, can link a KMP framework |
| Android FCM decrypt service | Kotlin, in an Expo module | Kotlin plugin | Kotlin | Kotlin | Kotlin, shared core |
| Watch apps | Not produced; Apple watch target via config plugin (S22), Wear OS separate Gradle module | Not produced | Not supported (S25) | SwiftUI + Compose for Wear | Not produced for watchOS UI; Kotlin logic shareable with Wear; KMP watchOS logic Beta (S26) |
| Fit with repo languages | TypeScript is already used (`packages/streamdeck`); MP-R1 plans TS contract types | TypeScript | Dart (new) | Swift and Kotlin (new) | Kotlin (new) |
| UI duplication | Low | Low (web), higher for native | Low | High (2×) | Low |
| 4.2 risk | Low to medium (native surfaces) | Highest (web-first) | Low to medium | Lowest | Low to medium |
| Maintenance for one operator | Medium: Expo upgrades yearly-ish; native targets stay small | Low web cost, but native plugins and remote-origin workarounds | Medium; new language | High: two full UIs | Medium to high; new language, iOS interop |

### Rejected and why

- **Capacitor:** it is built around bundled web assets. The remote-origin mode the dashboard needs is documented as not for production (S24). Its strength, reusing the web UI, is already obtained by embedding a WebView in any option. It adds nothing for native surfaces and raises the 4.2 risk.
- **Flutter:** it is capable, but adds Dart to a TS/Elixir repo. It cannot build either watch (S25) and gives no sharing advantage over RN.
- **Native ×2:** the best per-platform fidelity, but the three native surfaces (meta-dashboard, Command response, pairing) would be built twice for one maintainer. Brief §6 asks for "minimal platform-specific duplication".
- **KMP + Compose Multiplatform:** this is the strongest alternative. A Kotlin core could be shared with the Wear OS app. It is rejected for now because watchOS KMP is Beta (S26), the iOS NSE and the watch app would still be Swift calling a Kotlin framework, the repo has no Kotlin, and MP-R1 already plans TS contract types. Revisit if MP-N7 Wear OS sharing turns out to be most of the code.

### Recommended (MP-Q4 resolution)

**React Native (New Architecture) on Expo with Continuous Native Generation**,
hosting the per-instance dashboard in `react-native-webview`. Native-language code
is kept in three small, testable places:

1. **Apple native core** (Swift package): pairing credential store, request signing, payload decryption, contract models. It is used by the iOS app's Expo module, the Notification Service Extension and the watchOS app.
2. **Android native core** (Kotlin module): the same responsibilities, used by the Android app's Expo module, the `FirebaseMessagingService` and the Wear OS app.
3. **Watch apps:** SwiftUI watchOS app and Compose for Wear OS app (MP-N7).

The NSE and the watch apps are native in **every** option (S2, S25, S26). The
recommendation minimises the code that is duplicated beyond that floor. This is
**recommended, pending a throwaway feasibility prototype** (proposed in plan.md
§11, not authorised). The prototype checks the community pieces S22 and S23 before
anything is committed.

## 5. Watch evidence summary (detail in ../MP-N7/plan.md)

- Phone frameworks do not produce watch apps: no option above builds a watchOS or Wear OS UI from shared phone UI code (S22, S25, S26).
- watchOS apps are SwiftUI single-target apps (S13).
- WebSockets are blocked on watchOS for ordinary apps (S7). The watch cannot hold a LiveView or `/voice` socket.
- The Speech framework is absent on watchOS (S9). Recording to a file is available (S10). System dictation is available through text input (S11).
- No Tailscale client exists for either watch (S40). A watch on its own network cannot reach a tailnet-only daemon. **The companion phone is the network path.**
- Wear OS pairs only with Android phones for the Data Layer (S32, S38). So the pairs are iPhone ↔ Apple Watch and Android ↔ Wear OS. Cross pairs are out of scope.
