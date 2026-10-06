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
| `snapshot` | phone → watch | `updateApplicationContext` / `DataClient` item `/aiur/snapshot` | Latest compact list (§6) with `as_of`. Overwrites; only the newest matters. |
| `get_command {instance_id, decision_id}` | watch → phone | `sendMessage` with reply / `MessageClient` request | Fetch one Command card. Wakes the iOS app (S6). |
| `answer {instance_id, decision_id, expected_version, idempotency_key, selected_option_id | custom_response}` | watch → phone | `sendMessage`; on failure `transferUserInfo` with **no automatic replay** (see §8) / `MessageClient` | Submit an answer. The phone adds `client.surface: "watch"` and `device_id`. |
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
| D-relay | Record to a file (`AVAudioRecorder`, S10; Wear `MediaRecorder`), send it to the phone (`transferFile` / `ChannelClient`), the phone streams it to the daemon's STT (MP-N1 A5), and the transcript returns for review | Same provider as the dashboard | Seconds of extra latency; depends on A5; not real-time |

Recommendation: offer **D-sys** by default, and D-relay only when the operator
requires that speech never goes to Apple or Google (OQ-N7-2). Both show the text for
review before Send.

### Converse

Live duplex audio from the watch is not feasible for an ordinary watchOS app: a
WebSocket to the daemon is blocked (S7), and the phone relay is not designed for
streaming. So Converse on the watch is **turn-based**:

1. Press to talk; press again to end the turn (the dashboard's half-duplex shape, baseline E6).
2. The audio file goes to the phone (`voice_turn`). The phone forwards it to the MP-E6 conversation component through A5.
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
| Commands awaiting (blocking count) | `commands.read` | hidden if unavailable |
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
- **Actions:** the notification's default action opens the watch app's Command card, where options are buttons. Dynamic option titles as notification action buttons are **not** assumed: categories are registered in advance, so per-Command option text in the banner is unverified (N7-RQ1).
- **Wear OS:** the Android phone's FCM service decrypts and posts the notification. Wear OS bridges it automatically (S33). A `dismissalId` equal to `<instance_id>:<decision_id>` keeps dismissal in sync. Content intent on the watch opens the Wear app's Command card when the app is installed (bridged notifications with app-specific actions need `setBridgeTag` handling; Phase C confirms, N7-RQ2).
- **Resolved elsewhere:** when a Command resolves on another surface, the phone removes or updates the notification; forwarded or bridged copies follow (DV-W7 checks Wear; Apple forwarding of removals is N7-RQ3).

## 8. Non-happy paths

| Case | Behaviour |
|---|---|
| Phone out of range or off | The watch shows the last snapshot labelled with its age and "Needs iPhone nearby" / "Needs phone". Answer and voice are disabled with that reason. |
| Phone reachable, daemon unreachable | The broker returns `unreachable` per machine. The watch shows it per instance (not "0 awaiting"). |
| Answer sent, reply lost | The watch shows "Sending…", then "Not confirmed. Check on phone." It never resends automatically; a user resend reuses the same `idempotency_key`, so the server dedupes. |
| Queued `transferUserInfo` answer delivered late | The phone checks the Command's `expected_version` and age before submitting. If the Command changed or the answer is older than the stale budget (contract §6), it reports `stale` instead of submitting. A late answer must never land on a changed question. |
| Command already resolved | The card shows "Resolved by <surface> <age> ago" and the winning answer summary (MP-E2 409 data); options are hidden. |
| Two watches on one iPhone | WatchConnectivity supports switching (S6). The broker implements the activation callbacks; only the active watch receives snapshots. |
| Mic permission denied | Dictate (D-relay) and Converse show `needs_permission`; D-sys may still work because it uses the system input UI. |
| Voice capability absent on the server | D-relay and Converse show unavailable with the reason; D-sys stays available (it needs no server voice). |
| Watch locked or off the wrist | No forwarding (S15); the phone shows the notification instead. |
| Battery | No polling on the watch. All updates are pushed from the phone through application context, which the system delivers opportunistically. |
| Privacy | The watch stores only the snapshot and open Command cards; no credentials and no transcript history. Snapshot data is cleared when the phone reports the machine unpaired. |

## 9. Contracts

- **Owned:** watch-link protocol (§4), internal to `packages/aiur-mobile`.
- **Consumed:** client-capability-model (watch rules §7, owned by MP-N1); command-request-and-resolution (MP-E2) via the phone; conversations (MP-E4) for an optional two-line context excerpt only; notification payload (MP-N4); voice for non-browser clients (A5, MP-E5/MP-R5) and MP-E6 for Converse; identity-and-capabilities (MP-R1).
- **Assumption to reconcile with MP-E2:** `client.surface: "watch"` is distinct from `"phone"` in the answer record even though the phone submits it, so audit logs show where the decision was made.

## 10. Acceptance criteria

- AC1. The watch app installs with the phone app on both platforms and shows the compact list within one snapshot cycle after the phone app has data.
- AC2. Unavailable capabilities never render as zero or as working controls (fixture tests in Swift and Kotlin using the shared fixtures).
- AC3. From a forwarded or bridged notification, the user reaches the Command card in at most two taps, sees the short summary and options, and answers. Exactly one answer is recorded with `client.surface: "watch"` (DV-W4).
- AC4. The mic always asks Dictate or Converse first; nothing records before a choice; no auto-record from a notification (UI tests).
- AC5. Dictation text is shown for review before Send on both paths (DV-W5).
- AC6. No pause, resume, spawn or other orchestration control exists in either watch app (a UI inventory test lists every interactive control).
- AC7. With the phone unreachable, the watch shows the age and "needs phone" state, and write actions are disabled (DV-W3).
- AC8. Every required DV-W row passes on physical devices.
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

- **N7-RQ1.** Can per-Command option text appear as notification action buttons on watchOS and Wear OS (runtime category registration from the NSE path)?
- **N7-RQ2.** Wear OS: does a bridged notification's content intent open the installed Wear app, or must the Wear app post its own local notification (and disable bridging for that tag)?
- **N7-RQ3.** Apple: when the iPhone removes a delivered notification, is the forwarded watch copy removed?
- **N7-RQ4.** Watch-own APNs registration and keys (deferred standalone path): what MP-N2 would need.
- **N7-RQ5.** Does Wear OS traffic proxied through the phone use the phone's VPN, such as Tailscale (S35 silent)? Only relevant if a standalone path is ever considered.
