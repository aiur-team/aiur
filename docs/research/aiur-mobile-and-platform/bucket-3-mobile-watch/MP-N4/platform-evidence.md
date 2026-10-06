---
feature_id: MP-N4
resolves: MP-Q2 (push relay)
base_main_sha: 45a290e3
date: 2026-10-06
---

# MP-N4 platform evidence and MP-Q2 resolution

Every external claim used by the MP-N4/N5/N6 plans and by
[contracts/notification-destination-and-payload.md](../../contracts/notification-destination-and-payload.md).
All sources were accessed on **2026-10-06**. Apple pages were read through their
documentation JSON (`developer.apple.com/tutorials/data/documentation/<path>.json`),
which serves the same text as the HTML page; Apple pages carry no "last updated" date, so
the version is the platform availability in the page metadata where stated. Google pages
state their own "last updated" date.

Claims marked **UNVERIFIED** were not found in an authoritative source and are physical
device validation items in [device-validation-plan.md](device-validation-plan.md).

## A. APNs (iOS)

| ID | Claim | Source |
| --- | --- | --- |
| E-A1 | Payload cap 4,096 bytes (VoIP 5,120). "APNs refuses a notification if the total size of its payload exceeds" these. | developer.apple.com/documentation/usernotifications/generating-a-remote-notification |
| E-A2 | `apns-priority`: "10 to send the notification immediately", "5 … based on power considerations", "1 … prevent awakening the device"; default 10. `apns-expiration`: nonzero = store and retry until that date, `0` = one attempt, no storage; "best efforts … without any guarantee". `apns-collapse-id` "must not exceed 64 bytes" and merges notifications. `apns-push-type` "Required for watchOS 6 and later; recommended" elsewhere. "APNs may reorder notifications." | developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns |
| E-A3 | A Notification Service Extension (NSE) runs only when the payload has `mutable-content: 1` **and** an `alert` with title, subtitle or body; it is not run for silent, sound-only or badge-only pushes, or when alerts are disabled. "only about 30 seconds"; on timeout `serviceExtensionTimeWillExpire()`; "If you fail to call the completion handler … the system displays the original contents of the notification." First listed use: "Decrypt data sent in an encrypted format." Availability: iOS 10.0+, **watchOS 6.0+**. | …/usernotifications/modifying-content-in-newly-delivered-notifications; …/usernotifications/unnotificationserviceextension (page metadata) |
| E-A4 | Offline storage: "APNs stores only one notification per bundle ID"; "In most cases, the latest … this behavior isn't always guaranteed." Default storage TTL 30 days or the expiry, whichever comes first. Priority 5 and 1 "might get grouped and delivered in bursts". "Your app may need to synchronize with your application server about the information missed due to discarded, expired, or overwritten notification." | …/sending-notification-requests-to-apns; …/viewing-the-status-of-push-notifications-using-metrics-and-apns |
| E-A5 | Background (`content-available`) pushes are "low priority … the system doesn't guarantee their delivery … don't try to send more than two or three per hour"; must use `apns-push-type: background`, priority 5; a held background push is discarded "If something force quits or kills the app"; 30 s of run time. | …/usernotifications/pushing-background-updates-to-your-app |
| E-A6 | Token auth uses a `.p8` signing key from the developer's Apple account, scoped to a **Team** (team-scoped or topic-specific keys); "this key must remain private"; JWT refreshed every 20–60 min. "You can't map a connection to APNs to multiple teams." → whoever sends to a given app's bundle ID must hold that app publisher's key. | …/usernotifications/establishing-a-token-based-connection-to-apns |
| E-A7 | `com.apple.developer.usernotifications.filtering` lets the NSE suppress display by returning empty content; it must be **applied for** and requires `apns-push-type: alert`. | …/bundleresources/entitlements/com.apple.developer.usernotifications.filtering |
| E-A8 | Actionable notifications: categories registered at launch; selecting an action "launches your app in the background"; `UNTextInputNotificationAction` lets the user "enter or dictate" text; `.authenticationRequired` forces unlock first; users can act while locked, so files with complete protection are unavailable. On Apple Watch Series 9 / Ultra 2, Double Tap invokes the first non-destructive action. | …/declaring-your-actionable-notification-types; …/untextinputnotificationaction; …/unnotificationactionoptions/authenticationrequired |
| E-A9 | `interruption-level` values `passive`, `active`, `time-sensitive`, `critical`; time-sensitive "can break through system controls such as Notification Summary and Focus"; the user can turn it off. `thread-id` groups; `target-content-id` selects the scene. | …/generating-a-remote-notification; …/unnotificationinterruptionlevel/timesensitive |
| E-A10 | Apple: "Don't include … sensitive data … in a notification's payload. If you must … encrypt it … You can use a notification service app extension to decrypt the data on the user's device." | …/generating-a-remote-notification |

## B. watchOS and keys on Apple devices

| ID | Claim | Source |
| --- | --- | --- |
| E-B1 | Forwarding: a remote push to iPhone "can appear on either Apple Watch or iPhone"; rules in order: iPhone unlocked and screen on → phone; else watch on wrist and unlocked → watch; else iPhone. Background pushes are never forwarded. With several watches, direct pushes "only appear at the specified watch". | developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding |
| E-B2 | watchOS 6+: a watch app can register and receive remote pushes directly with its own device token; for a dependent watch app "send … just to iPhone, or … to both … the system ensures that the user only receives one notification". | …/watchos-apps/enabling-and-receiving-notifications |
| E-B3 | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: not accessible after restart until first unlock, then accessible until next restart; "recommended for items that need to be accessed by background applications"; not migrated to another device. Default accessibility is unlocked-only. | …/security/ksecattraccessibleafterfirstunlockthisdeviceonly; …/security/restricting-keychain-item-accessibility |
| E-B4 | Keychain access groups / app groups share items between apps (and their extensions) "delivered by a single development team". | …/security/sharing-access-to-keychain-items-among-a-collection-of-apps |
| E-B5 | Watch Connectivity is opportunistic: "you can't rely on WatchConnectivity as your only means"; watch networking proxies through iPhone, else known Wi-Fi, else cellular. | …/watchos-apps/keeping-your-watchos-app-s-content-up-to-date; …/watchconnectivity |
| E-B6 | **UNVERIFIED:** whether an iPhone-forwarded notification on the watch shows the iPhone NSE's decrypted content or the original fallback. Apple's forwarding page does not say. Device test V-W1. | — |

## C. Cryptography libraries

| ID | Claim | Source |
| --- | --- | --- |
| E-C1 | CryptoKit `HPKE`: iOS/iPadOS 17.0+, watchOS 10.0+, macOS 14.0+. | developer.apple.com/documentation/cryptokit/hpke (page metadata) |
| E-C2 | Tink hybrid encryption implements RFC 9180 HPKE, templates include `DHKEM_X25519_HKDF_SHA256_HKDF_SHA256_CHACHA20_POLY1305` (page updated 2025-03-03). | developers.google.com/tink/hybrid |
| E-C3 | HPKE is RFC 9180 (IETF, 2022); test vectors in Appendix A. | rfc-editor.org/rfc/rfc9180 |
| E-C4 | **UNVERIFIED for the pinned OTP:** Erlang `:crypto` X25519 ECDH and `chacha20_poly1305` AEAD. Verified in ticket MP-N4-C1-T01 against the repo's pinned Erlang/OTP before any code depends on it. | — |

## F. FCM and Android

| ID | Claim | Source |
| --- | --- | --- |
| E-F1 | "Maximum payload for both message types is 4096 bytes." Notification messages are displayed by the system tray when the app is backgrounded and `onMessageReceived` is not called; data messages are handled by the app. (updated 2026-10-06) | firebase.google.com/docs/cloud-messaging/customize-messages/set-message-type; …/android/receive-messages |
| E-F2 | FCM stores at most four collapsible messages per device (one per collapse key). Non-collapsible: "limit of 100 messages … If the limit is reached, all stored messages are discarded." (updated 2026-10-06) | firebase.google.com/docs/cloud-messaging/customize-messages/collapsible-message-types |
| E-F3 | Default lifespan four weeks; `ttl` 0–2,419,200 s (28 days); `ttl: 0` = discard if not deliverable now. (updated 2026-10-06) | firebase.google.com/docs/cloud-messaging/customize-messages/setting-message-lifespan |
| E-F4 | Normal priority may be delayed in Doze; high priority may wake the device "and run some limited processing (including very limited network access)". High priority "should result in user interaction"; FCM looks at 7 days of behavior and may deprioritize or have Google Play services display notifications on the app's behalf. Data messages to Apple devices via FCM must use priority 5. (updated 2026-10-06) | firebase.google.com/docs/cloud-messaging/android-message-priority; …/customize-messages/setting-message-priority |
| E-F5 | `onMessageReceived` has "a short execution window"; handle within ~10 s; use WorkManager for longer work, including fetching content. (updated 2026-10-06) | firebase.google.com/docs/cloud-messaging/android/receive-messages |
| E-F6 | "FCM doesn't provide a built-in solution for end-to-end encryption"; encrypt on the server, decrypt in the app; notification payloads cannot be decrypted before display; "Never store your encryption keys directly in your APK". (updated 2026-10-06) | firebase.google.com/docs/cloud-messaging/encryption |
| E-F7 | A force-stopped app receives no messages until the user reopens it; FCM may not deliver if > 100 pending or the device has not connected for over a month. (search summary of the FCM receive and troubleshooting pages; re-read in MP-N4-C5-T01) | firebase.google.com/docs/cloud-messaging/android/receive-messages; …/troubleshooting |
| E-F8 | Android 13+ (API 33) `POST_NOTIFICATIONS` runtime permission; notifications are off by default for new installs. (updated 2026-10-01) | developer.android.com/develop/ui/views/notifications/notification-permission |
| E-F9 | Credential-encrypted storage is available only after the first unlock and stays available until restart; device-encrypted storage is available in Direct Boot. Keystore `setUnlockedDeviceRequired` restricts a key to unlocked use. **UNVERIFIED:** FCM delivery before first unlock (Direct Boot). (updated 2026-10-01) | developer.android.com/privacy-and-security/direct-boot; developer.android.com/reference/android/security/keystore/KeyGenParameterSpec.Builder |
| E-W1 | Wear OS: phone notifications bridge to the watch by default; `BridgingManager`, bridge tags and dismissal ids control it; ongoing/local-only notifications do not bridge. **UNVERIFIED:** inline `RemoteInput` reply on a bridged notification. (updated 2026-09-22) | developer.android.com/training/wearables/notifications/bridger |

## R. Relays and standards

| ID | Claim | Source |
| --- | --- | --- |
| E-R1 | RFC 8291 (Web Push encryption): "The timing and length of communication cannot be hidden from the push service … the push service will see which application server is talking to which user agent." | rfc-editor.org/rfc/rfc8291 |
| E-R2 | Matrix Push Gateway API (spec v1.19): with `format: event_id_only` only `event_id`, `room_id`, `counts`, `devices` are required; the gateway is a separate intermediary between homeserver and APNs/FCM. | spec.matrix.org/latest/push-gateway-api/ |
| E-R3 | UnifiedPush: decentralized push, distributors on Android and Linux; no iOS. | unifiedpush.org |
| E-R4 | ntfy self-hosted iOS delivery needs `upstream-base-url: https://ntfy.sh`; upstream receives "only the message ID … and the SHA256 checksum of the topic URL"; reason: iOS needs a central APNs sender. | docs.ntfy.sh/config/ |

## MP-Q2 resolution: which relay

**Hard constraint (E-A6, E-F6):** a store-distributed app can only receive pushes sent with
*its publisher's* APNs key and Firebase project. A user's home machine cannot hold that key.
So every design needs one sender that holds the publisher credentials: a **relay service**.
"Self-hosted relay" therefore means "self-built app with your own bundle ID and keys". That
is supported but is not the default for store users. ntfy reached the same conclusion
(E-R4).

| Candidate | Can carry aiur encrypted push today? | What it sees | Verdict |
| --- | --- | --- | --- |
| **Purpose-built minimal relay service** (this plan, MP-N4-C2) | Not yet built; small (register handle, send, delete) | §1 of the contract: IP, handle, sizes, timing, push token | **Recommended.** Deployable as a container anywhere; a Cloudflare Worker adapter is optional. |
| **`hooks.aiur.dev` tunnel** | **No.** It is an inbound `cloudflared` tunnel path-scoped to `/api/v1/github/webhook` with a catch-all 404 (`website/docs-app/apis/github.md:744,751,760`; host config in baseline R4). The direction is wrong: push needs the daemon to call out, not the internet to call in. Widening the path would expose the dashboard (`github.md:760`). | n/a | Not reused. The relay *service* may run on Cloudflare Workers as one optional deployment, which shares nothing with the tunnel. |
| **Khala** (`/home/everdred/github/everdred/khala` @ `d898e6b8`) | **No.** Khala is research-stage: README says "This repository currently contains research, not an implemented service." Matrix/Synapse is a *candidate* ("Matrix is a candidate, not yet a user-approved stack selection", `docs/product/decisions.md:7`; Synapse only in `experiments/backend/compose.yaml:18-19`). `@khala/messaging` has exports but no `src/` directory. No push gateway, pusher, APNs or FCM code exists. | If adopted later: a Matrix homeserver sees room ids, senders, timing and sizes (`docs/research/07-state-and-transport.md:78`); a Sygnal-style gateway sees event/room ids and device push keys (E-R2). | Not reused. It would make Khala's hosted homeserver a hidden mandatory dependency of aiur notifications and still needs a publisher-keyed push gateway. Revisit only if Khala ships a push gateway with the same opaque-payload property; the contract's `RelayEnvelope` would then be one more relay provider. |
| **Matrix push-gateway pattern** (Sygnal, `event_id_only`) | Pattern, not a service | gateway sees ids and push keys | Adopted as prior art: the relay forwards opaque references, never content. aiur goes further: content is sealed, not omitted. |
| **UnifiedPush / ntfy** | Android only (E-R3); iOS falls back to a central APNs relay (E-R4) | distributor sees topic, sizes, timing | Deferred optional provider for de-Googled Android (open question RQ-N4-6). Does not remove the iOS relay. |
| **Daemon sends to APNs/FCM directly** | Only for a self-built app whose keys the operator holds | Apple/Google only | Allowed later as `push.provider: direct` for self-builders; not v1. |

**What the relay and providers can see** is the table in contract §1. In short: Apple and
Google see that *this app* got *a notification* of *this size* at *this time* with *this
priority*, plus the uniform fallback text. The relay additionally sees the daemon's IP and
can link handles that share one push token. Nobody but the paired device reads the
summary, the destination, or any repo, ticket, agent or Command identifier.

**Cloudflare is optional** because the relay service is a plain HTTPS app with two
provider adapters; Cloudflare Workers is one deployment target among container hosts.
**The machine is never publicly reachable**: the daemon only makes outbound HTTPS
requests to the relay, and the phone fetches richer context over its private path
(MP-N2), exactly as the dashboard is reached today.
