---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-N7
bucket: 3-mobile-watch
base_main_sha: 45a290e3
date: 2026-10-06
execution: code
research_question: MP-Q4 (watch targets; resolved, pending device validation)
owner_gate: owner-design-tasks/DESIGN-N7.md
companion_files: [chunks.md, ../MP-N1/framework-evidence.md, ../MP-N1/device-validation.md]
---

# MP-N7 — Watch apps (plan)

## 0. Summary

Two native, **phone-dependent** watch apps:

- **Apple Watch:** a SwiftUI watchOS app shipped inside the iOS app (dependent, not independent). It talks to aiur only through the iPhone app over WatchConnectivity.
- **Wear OS:** a Compose for Wear OS app, non-standalone, published with the Android app. It talks to aiur only through the Android phone app over the Wearable Data Layer.

Scope is exactly the brief's: notifications, compact Command context, suggested
options, explicit voice (a Dictate or Converse choice, D16), and a compact
instance/status list. **No pause, resume, spawn or other orchestration control**
(brief §3, §6 N7).

Watch UI shares no code with the phone UI; no framework produces both
(framework-evidence.md §5). Each watch shares its platform's native core with the
phone (MP-N1 §7) and follows the same capability and Command state rules.

Supported pairs: **iPhone ↔ Apple Watch** and **Android phone ↔ Wear OS watch**.
Wear OS with an iPhone is out of scope: the Data Layer does not work with iOS (S32),
and Pixel Watch requires Android (S38).

## 1. Problem frame

The operator wants to notice a blocker and steer it from the wrist, with less
friction than taking out the phone, without a shrunken dashboard (brief §6 N7).
Nothing watch-related exists in the repo (baseline N7: the only `watchos` hit is a
test fixture directory name in `src/test/aiur/init_test.exs`).

## 2. Repository findings (watch-specific, at `45a290e3`)

| # | Finding | Evidence | Consequence |
|---|---|---|---|
| W1 | Every live dashboard path is a WebSocket (`/live`, `/voice`, `/streamdeck`) | `src/lib/aiur_web/endpoint.ex:14-29` | watchOS blocks `URLSessionWebSocketTask` for ordinary apps (S7). The watch cannot use any existing live channel. |
| W2 | Voice is daemon-relayed ElevenLabs STT over `/voice`, 16 kHz mono PCM | baseline R5; `voice_socket.ex:21-37` | Watch audio must reach the daemon through the phone, or the watch uses system dictation (§5). |
| W3 | The Command model carries `context.short_summary`, `options`, `recommendation`, `urgency`, `blocking` | `src/lib/aiur/decision.ex:21-27,120-126` | Enough for a compact watch Command card without the transcript. |
| W4 | The meta-level count wording is "N units awaiting commands"; the inbox is "Commands inbox" | `overview.ex:168-169`; `decision_inbox.ex:42` | The watch list reuses this terminology (DESIGN-N7 confirms short forms). |
| W5 | Build-order progress exists as `RootSummary.progress` | baseline N3; MP-R1 capability `build_orders.progress` | Shown only when that capability is available. |
| W6 | The dashboard is HTTP on a private address | `http_server.ex:64,147` | Even a standalone watch on Wi-Fi could not reach it securely, and no watch Tailscale client exists (S40). The phone is the network path. |

## 3. Proposed boundaries

```text
watch UI (SwiftUI | Compose for Wear)
   │  watch-link messages (versioned, §4)
phone watch broker (native: Swift in the iOS app | Kotlin in the Android app)
   │  AiurClientKit / aiur-client-core (MP-N1 native cores)
aiur daemon(s) over the paired transport (MP-N2)
```

- **Watch broker** (new, inside the phone app's native module, MP-N1 `modules/aiur-native`). It answers watch requests **in native code**, without depending on the React Native JS runtime. When `sendMessage` wakes the iOS app in the background (S6), JS may not be loaded, so the broker must not need it.
- **Watch-link protocol** (owned by MP-N7, internal to the mobile package). It is not a daemon contract.
- **Package location:** `packages/aiur-mobile/targets/watch` (watchOS) and `packages/aiur-mobile/wear` (Wear OS), decided in MP-N1 §3.3.

Prior mapping: **Prior-boundaries:** `SD` #35 is the precedent for a hardware client that
consumes daemon projections and owns presentation only. **Prior-units:** none.

## 4. Watch-link protocol (owned)

Small dictionaries over WatchConnectivity (`sendMessage` with reply,
`updateApplicationContext`, `transferUserInfo`, `transferFile`) or Data Layer
(`MessageClient`, `DataClient`, `ChannelClient`). Every message has
`{v: 1, id, sent_at}`.

| Message | Direction | Transport (Apple / Wear) | Purpose |
|---|---|---|---|
| `snapshot` | phone → watch | `updateApplicationContext` / `DataClient` item `/aiur/snapshot` | Latest compact list (§6) with `as_of`. Overwrites; only the newest matters. Schema and the 16 KiB budget are owned by MP-N7-C1-T01 (RC-38); MP-N1-C3-T04 builds the instance part. |
| `get_command {instance_id, decision_id}` | watch → phone | `sendMessage` with reply / `MessageClient` request | Fetch one Command card. Wakes the iOS app (S6). |
| `answer {instance_id, decision_id, expected_version, idempotency_key, option_id | custom_response}` | watch → phone | `sendMessage`; on failure `transferUserInfo` with **no automatic replay** (see §8) / `MessageClient` | Submit an answer. The phone adds `client.surface: "watch"` and `device_id`. |
| `answer_result {idempotency_key, outcome}` | phone → watch | reply, else `transferUserInfo` / `MessageClient` | `delivered`, `conflict{winner}`, `failed{reason}`, `stale`. |
| `voice_turn {session, seq, audio_file}` | watch → phone | `transferFile` / `ChannelClient` stream | Turn-based Converse and ElevenLabs dictation (§5). |
| `voice_result {session, seq, transcript?, reply_audio?}` | phone → watch | reply / `transferFile` / `ChannelClient` | Transcript for review; spoken reply for Converse. |
| `capability_hint` | phone → watch | within `snapshot` | Pre-resolved affordance states (client-capability-model.md §7). The watch never resolves capabilities itself. |

## 5. Voice on the watch (D16: explicit Dictate / Converse choice, no default)

The watch shows a mic button that opens a two-option choice: **Dictate** or **Converse**.
Nothing records until one is chosen. Opening a notification never starts the mic
(brief N6).

### Dictate

| Path | How | Pros | Cons |
|---|---|---|---|
| D-sys (recommended v1) | System text input with dictation (SwiftUI `TextField` / `presentTextInputController`, S11; Wear `RecognizerIntent.ACTION_RECOGNIZE_SPEECH`, S36). The result appears for review, then Send. | Works without the phone's voice path. Lowest latency. Matches E5's review-before-send rule. | Speech is processed by Apple or Google, not by the operator's ElevenLabs key. This must be disclosed (brief §7); it is an owner decision (OQ-N7-2). |
| D-relay | Record to a file (`AVAudioRecorder`, S10; Wear `MediaRecorder`), send it to the phone (`transferFile` / `ChannelClient`), the phone streams it to the daemon's STT over the device voice path (MP-E5-C8, voice-session §3.5), and the transcript returns for review | Same provider as the dashboard | Seconds of extra latency; depends on MP-E5-C8; not real-time |

Recommendation: offer **D-sys** by default, and D-relay only when the operator
requires that speech never goes to Apple or Google (OQ-N7-2). Both show the text for
review before Send.

### Converse

Live duplex audio from the watch is not feasible for an ordinary watchOS app: a
WebSocket to the daemon is blocked (S7), and the phone relay is not designed for
streaming. So Converse on the watch is **turn-based**:

1. Press to talk; press again to end the turn (the dashboard's half-duplex shape, baseline E6).
2. The audio file goes to the phone (`voice_turn`). The phone forwards it to the MP-E6 conversation component through the device voice path (MP-E5-C8, voice-session §3.5).
3. The reply comes back as text plus optional audio (`voice_result`). The watch plays it and shows the text.
4. Leaving the screen ends the session. The transcript is retained by MP-E6 (D17: no raw audio retained).

If the capability `voice.conversation` is not available, Converse is shown as
unavailable with its reason, never hidden behind a working-looking button.
DESIGN-N7 sets a latency acceptance figure; DV-W6 measures it. If it fails, the
fallback is "Continue on phone" (hand-off). That fallback is an owner decision
(OQ-N7-3), not an implementer's.

## 6. Compact instance/status list

From the phone's `snapshot` (never fetched by the watch directly):

| Field | Source capability | When absent |
|---|---|---|
| Machine label, repository `owner/name` | identity | — |
| Executor state | identity `executor.state` | `unknown` shown as "?" with a legend, not "idle" |
| Active agents | `instance.status` | "—" with `unavailable`, not 0 |
| Commands awaiting (blocking count) | `commands.read` | "—" with the `unavailable` reason, never hidden and never 0 (Phase D X-56; MP-N7-C2-T02 already renders it this way); hidden only when `disabled` |
| Build-order % | `build_orders.progress` | hidden |
| Background agents (Executor) | MP-E3 when available | hidden |
| Freshness | `as_of` + phone reachability | "Needs iPhone nearby" / "Needs phone" when the watch cannot reach the phone; ages always shown |

Tapping an instance shows its open Commands only (compact cards). There is no
dashboard, no transcript browser (brief: full history on the watch is not a
requirement) and no controls other than answer and voice.

Optional glanceable surfaces (DESIGN-N7 decides): a watchOS widget or complication
(WidgetKit) and a Wear OS Tile showing the total blocking count. They read only the
last `snapshot`.

## 7. Notifications

- **Apple Watch:** v1 relies on **iPhone forwarding** (S15): when the iPhone is locked and the watch is on the wrist, the watch shows the iPhone's notification. The iPhone NSE decrypts first. That the watch then shows the decrypted text is supported only by vendor evidence (S39); DV-W1 must confirm it. The watch app does **not** register its own APNs token in v1. Doing so (S12) would need its own device credential and decryption key on the watch, a second pairing scope that MP-N2 does not define. It is deferred, as research N7-RQ4.
- **If the watch shows only the uniform fallback (Phase D feasibility M5).** The plan default is
  option **(a)**: accept the fallback on the watch ("aiur · New notification"); its default
  action opens the watch app, which fetches the Command card through the phone
  (`get_command`, MP-N7-C2-T04 "fallback open" path), so the card is one tap away. DV-W1
  therefore passes on "decrypted text, **or** fallback with the card one tap away"
  (MP-N7-C6-T01). Option **(b)**, promote N7-RQ4 (direct watch push with its own key) to a
  conditional chunk, is triggered only if the owner rejects (a) in DESIGN-N7 or DV-W1 fails
  even the relaxed criterion. Then MP-N2 must first define the second pairing scope. The
  choice is an owner decision in DESIGN-N7.
- **Actions:** the notification's default action opens the watch app's Command card, where options are buttons. Dynamic option titles as notification action buttons are **not** assumed: categories are registered in advance, so per-Command option text in the banner is unverified (N7-RQ1).
- **Wear OS (revised in Phase C, N7-RQ2):** the Android phone's FCM service decrypts and posts the notification with bridge tag `aiur-command` and dismissal id `<instance_id>:<decision_id>`. When the Wear app is installed it excludes that tag from bridging and posts its own notification (sent by the phone broker as watch-link `notify`), whose content intent opens the Wear Command card. Without the Wear app, the phone notification bridges by default ("open on phone"). See tickets/MP-N7-C3-T04.md.
- **Resolved elsewhere:** when a Command resolves on another surface, the phone removes or updates the notification; forwarded or bridged copies follow (DV-W7 checks Wear; Apple forwarding of removals is N7-RQ3).

## 8. Non-happy paths

| Case | Behaviour |
|---|---|
| Phone out of range or off | The watch shows the last snapshot labelled with its age and "Needs iPhone nearby" / "Needs phone". Answer and voice are disabled with that reason. |
| Phone reachable, daemon unreachable | The broker returns `unreachable` per machine. The watch shows it per instance (not "0 awaiting"). |
| Answer sent, reply lost | The watch shows "Sending…", then "Not confirmed. Check on phone." It never resends automatically; a user resend reuses the same `idempotency_key`, so the server dedupes. |
| Queued `transferUserInfo` answer (deliberate exception) | MP-N6 does **not** queue phone answers for later send (OQ-N6-1). The watch path is the one deliberate exception (Phase D feasibility m6): a watch answer that fails `sendMessage` is handed to `transferUserInfo`, because the watch cannot hold a request open; the system delivers it when the phone wakes. The late-delivery guard below makes this safe; DV-W4b tests it. If DESIGN-N6 OQ-N6-1 forbids any queuing, drop this fallback and show "Not sent. Open on iPhone" instead. |
| Queued `transferUserInfo` answer delivered late | The phone checks the Command's `expected_version` and age before submitting. If the Command changed or the answer is older than the stale budget (contract §6), it reports `stale` instead of submitting. A late answer must never land on a changed question. |
| Command already resolved | The card shows "Resolved by <surface> <age> ago" and the winning answer summary (MP-E2 409 data); options are hidden. |
| Two watches on one iPhone | WatchConnectivity supports switching (S6). The broker implements the activation callbacks; only the active watch receives snapshots. |
| Mic permission denied | Dictate (D-relay) and Converse show `needs_permission`; D-sys may still work because it uses the system input UI. |
| Voice session ends with a typed reason | The watch maps every voice-session §6 end reason and §8 code through the shared fixture `packages/aiur-mobile/fixtures/contract/voice/end-reasons.json` (voice-session §8.1; Phase D feasibility M7): `cost_cap` and `provider_quota` show their own copy with **no** retry; `provider_unavailable` shows "try later"; `transport_lost` offers Retry; `auth_changed` shows unpaired. An unknown code shows the cause-neutral "Voice stopped" copy, never a guessed cause. Owner: MP-N7-C4-T05. |
| Voice capability absent on the server | D-relay and Converse show unavailable with the reason; D-sys stays available (it needs no server voice). |
| Watch locked or off the wrist | No forwarding (S15); the phone shows the notification instead. |
| Battery | No polling on the watch. All updates are pushed from the phone through application context, which the system delivers opportunistically. |
| Privacy | The watch stores only the snapshot and open Command cards; no credentials and no transcript history. Snapshot data is cleared when the phone reports the machine unpaired. |

## 9. Contracts

- **Owned:** watch-link protocol (§4), internal to `packages/aiur-mobile`.
- **Consumed:** client-capability-model (watch rules §7, owned by MP-N1); command-request-and-resolution (MP-E2) via the phone; conversations (MP-E4) for an optional two-line context excerpt only; notification payload (MP-N4); voice for non-browser clients (MP-E5-C8 device voice path, voice-session §3.5; the §8.1 client error table) and MP-E6 for Converse; identity-and-capabilities (MP-R1).
- **Assumption to reconcile with MP-E2:** `client.surface: "watch"` is distinct from `"phone"` in the answer record even though the phone submits it, so audit logs show where the decision was made.

## 10. Acceptance criteria

- AC1. The watch app installs with the phone app on both platforms and shows the compact list within one snapshot cycle after the phone app has data.
- AC2. Unavailable capabilities never render as zero or as working controls (fixture tests in Swift and Kotlin using the shared fixtures).
- AC3. From a forwarded or bridged notification, the user reaches the Command card in at most two taps, sees the short summary and options, and answers. Exactly one answer is recorded with `client.surface: "watch"` (DV-W4).
- AC4. The mic always asks Dictate or Converse first; nothing records before a choice; no auto-record from a notification (UI tests).
- AC5. Dictation text is shown for review before Send on both paths (DV-W5).
- AC6. No pause, resume, spawn or other orchestration control exists in either watch app (a UI inventory test lists every interactive control).
- AC7. With the phone unreachable, the watch shows the age and "needs phone" state, and write actions are disabled (DV-W3).
- AC8. Every required DV-W row passes on physical devices. DV-W1 passes on decrypted text or on the fallback with the card one tap away (§7, M5).
- AC9. DESIGN-N7 is approved before any N7 implementation ticket starts.

## 11. Plan-refresh note

N7 follows N1 and the refactor. After MP-R1..R7 land, re-check: capability IDs
(`packages/aiur-contracts`); the MP-E2 answer path (it moves with the `commands`
package); and whether MP-R2's external subscription is websocket-only (the phone
subscribes, never the watch, S7). No daemon paths are cited by watch code; only the
phone's native core is affected.

## 12. Open questions

### Owner (Kevin)

- **OQ-N7-1.** Confirm phone-dependent watch apps for v1 (no standalone or LTE operation).
- **OQ-N7-2.** Watch dictation via the system recognizer (Apple or Google processes speech) by default, or always via the phone and ElevenLabs?
- **OQ-N7-3.** If turn-based Converse misses the DESIGN-N7 latency figure, is "Continue on phone" acceptable?
- **OQ-N7-4.** Glanceables: a complication or Tile with the blocking count, yes or no?
- **OQ-N7-5.** Is Wear OS needed in v1, or Apple Watch first? (The plan covers both; the order changes chunk scheduling only.)

### Research (Phase C)

Phase C status (2026-10-06):

- **N7-RQ1 — API resolved, forwarded case pending device.** `WKUserNotificationInterfaceController.notificationActions` (watchOS 5.0+) "dynamically update[s] the list of actions … only … during `didReceive(_:)`" (developer.apple.com/documentation/watchkit/wkusernotificationinterfacecontroller/notificationactions, accessed 2026-10-06). Whether forwarded notifications carry the decrypted options is device row DV-W10. On Wear OS, per-notification actions exist but bridged actions run on the phone; the Wear-local notification (C3-T04) avoids that. Ticket MP-N7-C2-T06 (conditional).
- **N7-RQ2 — resolved.** Bridged notifications include a button to launch the app on the phone and `WearableExtender` actions "execute on the phone, not on the watch" (developer.android.com/training/wearables/notifications, updated 2026-09-22). Decision: the Wear app posts its own Command notification and excludes tag `aiur-command` from bridging; dismissal id `<instance_id>:<decision_id>` (bridger page, updated 2026-09-22). Device rows DV-W7/W7b/W7c confirm a non-standalone app's `BridgingConfig` is honoured. Ticket MP-N7-C3-T04.
- **N7-RQ3 — not documented; device row DV-W11.** Apple's forwarding page (accessed 2026-10-06) does not cover removal. Fallback if not removed: watch-side cleanup on the next snapshot (MP-N6-C6 ticket filed from DV-W11).
- **N7-RQ4 — deferred; conditional chunk (Phase D M5).** Becomes a chunk only if DESIGN-N7 rejects the fallback-open design (§7 option (a)) or DV-W1 fails the relaxed criterion.
- **N7-RQ5 — not documented** (network-access page, updated 2026-09-22, says traffic is "generally proxied through the phone" and does not mention VPNs). Irrelevant to v1; advisory measurement in DV-W8.
- **RQ-N7-6 (new).** Do the daemon STT path and the MP-E6 provider accept watch audio relayed faster than real time? Until measured (DV-W6), the phone paces at real time. Blocks the fast-pacing option in MP-N7-C4-T04/T05.
