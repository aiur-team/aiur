---
feature_id: MP-N7
base_main_sha: 45a290e3
date: 2026-10-06
gate: every ticket below is blocked on DESIGN-N7 (owner-design-tasks/DESIGN-N7.md)
---

# MP-N7 — chunks and candidate tickets

Every ticket is **blocked by DESIGN-N7**. Command and voice tickets are also blocked
by DESIGN-N6 and DESIGN-E5/E6 (shared voice controls). Phase C writes the full
brief §9 bodies.

## N7-C1 — Phone watch broker and watch-link protocol

- **Outcome:** native broker code in the iOS app (Swift, WatchConnectivity) and the Android app (Kotlin, Data Layer) that serves the watch-link messages (plan.md §4) using the MP-N1 native cores, without needing the JS runtime.
- **Depends on:** MP-N1 N1-C2 (native cores) and N1-C3-T05 (watch snapshot projection); MP-E2 contract.
- **Tickets:**
  - N7-C1-T01 Define the watch-link message schemas (`v: 1`) as fixtures in `packages/aiur-mobile/fixtures/watch-link/`.
  - N7-C1-T02 iOS broker: `WCSession` activation with multi-watch callbacks (S6), `get_command` and `answer` handlers, `snapshot` via application context.
  - N7-C1-T03 Android broker: `WearableListenerService` / `MessageClient` handlers, `DataClient` snapshot item.
  - N7-C1-T04 Late-answer guard: reject queued answers whose Command changed or exceeded the stale budget (plan.md §8).
  - N7-C1-T05 Snapshot push triggers: on capability change, Command count change, reachability change, debounced.
- **Tests:** broker unit tests with a fake session/client; fixture decode in Swift and Kotlin; mutation check on the late-answer guard (remove the version check and confirm a test fails); DV-W2.

## N7-C2 — watchOS app (SwiftUI)

- **Outcome:** a single-target SwiftUI watch app (S13) inside the iOS bundle: compact instance list, per-instance open Commands, Command card with options and answer state, mic choice.
- **Depends on:** N7-C1; DESIGN-N7.
- **Tickets:**
  - N7-C2-T01 Add the watch target through the config plugin (`targets/watch`), sharing `AiurClientKit` models only (no keys).
  - N7-C2-T02 Instance list from `snapshot`, with freshness and "Needs iPhone nearby" states.
  - N7-C2-T03 Command card: summary, context excerpt (≤2 lines), options, recommendation marker, answer states (`sending`, `delivered`, `conflict`, `failed`, `stale`).
  - N7-C2-T04 Notification open routing to the Command card.
  - N7-C2-T05 Interactive-control inventory test (AC6).
- **Tests:** SwiftUI previews and snapshot tests from fixtures, including every unavailable state; DV-W1, DV-W3, DV-W4, DV-W9.

## N7-C3 — Wear OS app (Compose for Wear)

- **Outcome:** a non-standalone (`com.google.android.wearable.standalone=false`, S34) Compose for Wear OS app (Material 3 for Wear, S37) with the same screens as N7-C2.
- **Depends on:** N7-C1; DESIGN-N7.
- **Tickets:**
  - N7-C3-T01 Gradle project `packages/aiur-mobile/wear` including `android-core`; same application ID as the phone app for the Data Layer.
  - N7-C3-T02 Instance list and Command card screens.
  - N7-C3-T03 Bridged-notification handling: `dismissalId`, bridge tags, open-in-app behaviour (N7-RQ2).
  - N7-C3-T04 CI: build the Wear module in `mobile-package.yml`.
- **Tests:** Compose UI tests from fixtures; DV-W7, DV-W8.

## N7-C4 — Watch voice (Dictate and Converse)

- **Outcome:** the D16 mic choice on both watches; Dictate via the system recognizer (D-sys), optional D-relay through the phone; turn-based Converse through the phone to MP-E6.
- **Depends on:** N7-C2 or N7-C3; MP-N1 A5 (voice for non-browser clients) for D-relay and Converse; MP-E6 for Converse; OQ-N7-2, OQ-N7-3.
- **Tickets:**
  - N7-C4-T01 Mic choice sheet; no recording before a choice (AC4).
  - N7-C4-T02 D-sys on watchOS (system text input) and Wear (`RecognizerIntent`), review before Send.
  - N7-C4-T03 Recording to file (`AVAudioRecorder` 16 kHz mono; Wear `MediaRecorder`/`AudioRecord`) and transfer (`transferFile` / `ChannelClient`).
  - N7-C4-T04 Phone-side relay of a recorded file to the daemon voice path; transcript return.
  - N7-C4-T05 Turn-based Converse session: turn sequencing, reply playback, end-of-session; capability-gated.
  - N7-C4-T06 Disclosure copy for the system recognizer path (brief §7).
- **Tests:** unit tests for turn sequencing; a recorded-file fixture round trip through a fake daemon; DV-W5, DV-W6. Confirm that no audio file persists on the watch or phone after a turn (D17).

## N7-C5 — Glanceables (conditional on OQ-N7-4)

- **Outcome:** a watchOS widget or complication and a Wear OS Tile showing the total blocking count and the oldest blocker age, from the last snapshot.
- **Depends on:** N7-C2, N7-C3.
- **Tickets:** N7-C5-T01 watchOS WidgetKit complication; N7-C5-T02 Wear Tile (ProtoLayout).
- **Tests:** timeline and tile renderer tests including the stale and unavailable states.

## Chunk dependency graph

```text
MP-N1 (N1-C2, N1-C3) ─► N7-C1 ─┬─► N7-C2 ─┐
                               └─► N7-C3 ─┼─► N7-C4 (also MP-E5/E6, A5)
                                          └─► N7-C5 (conditional)
DESIGN-N7 gates all; DESIGN-N6, DESIGN-E5/E6 gate N7-C2-T03 and N7-C4.
```

## Open research handed to Phase C

N7-RQ1 (dynamic action titles), N7-RQ2 (Wear bridged intents), N7-RQ3 (forwarded
removal on Apple Watch), N7-RQ4 (watch-own APNs, deferred), N7-RQ5 (Wear proxied VPN).

## Phase C changes (2026-10-06)

Full ticket bodies are in [tickets/](tickets/README.md). Changes against the candidates above:

- N7-C3-T04 (CI) is merged into MP-N7-C3-T01; N7-C4-T06 (disclosure) into MP-N7-C4-T02.
- N7-C3-T03 is redesigned by the N7-RQ2 result: Command notifications on Wear OS are posted by
  the Wear app itself (bridging excluded for tag `aiur-command`), because bridged
  notifications only offer "open on phone" and their actions run on the phone (MP-N7-C3-T04).
- New MP-N7-C2-T06: per-Command option buttons in the Apple Watch long-look, conditional on
  device row DV-W10 (N7-RQ1).
- New chunk **MP-N7-C6 — Physical-device validation**: C6-T01 Apple Watch, C6-T02 Wear OS,
  with exact devices and procedures and new rows DV-W1b, W2b, W4b, W7b, W7c, W10–W13.
- Watch-link protocol gains `notify` / `notify_cancel` (Wear only).
- New research item RQ-N7-6 (faster-than-real-time audio relay), blocking C4-T04/T05 pacing.
