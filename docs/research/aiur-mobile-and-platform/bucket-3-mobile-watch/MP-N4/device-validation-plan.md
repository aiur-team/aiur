---
feature_id: MP-N4 (also covers MP-N5 delivery rules and MP-N6 tap-to-context)
base_main_sha: 45a290e3
date: 2026-10-06
status: plan — not run; running it is a separate, explicitly authorized step (brief §2 Phase D)
---

# Physical-device validation plan

Simulators and emulators are not accepted evidence for any row marked **device**. The iOS
Simulator does not reproduce APNs storage, power-based deferral, Focus, or watch
forwarding; Android emulators do not reproduce OEM battery policies. Every result is
recorded with device model, OS build, app build, relay build, timestamps (send at daemon,
accept at relay, provider response, display on device) and a screenshot or screen
recording.

## 1. Device matrix

| Slot | Device | OS | Why |
| --- | --- | --- | --- |
| I1 | iPhone with Face ID | current iOS major at run time | primary |
| I2 | older iPhone that still runs iOS 17+ | oldest supported (KD-N4-8) | CryptoKit HPKE floor |
| W1 | Apple Watch paired to I1 | current watchOS | forwarding, direct push |
| A1 | Google Pixel | current Android | reference FCM behaviour |
| A2 | Samsung Galaxy | current One UI | OEM battery management |
| A3 | Android device on Android 13 | API 33 | `POST_NOTIFICATIONS` floor |
| WO1 | Wear OS watch paired to A1 | current Wear OS | bridging |

Network setups: (N-a) phone on the same private network as the machine (tailnet on, or
LAN); (N-b) phone on cellular, tailnet **off**; (N-c) airplane mode; (N-d) machine
offline. The machine is never reachable inbound in any setup (verified by an external
port scan of the machine's public IP before the run).

## 2. Scenarios

**This is the canonical push device matrix (Phase D, feasibility M4).** MP-N1's
DV-P1..P4 and DV-P8 are stable IDs that link to the rows here; their pass criteria are
not restated in MP-N1. App-state rows are split so that no row requires an outcome the
platform documents as impossible (V-A4).

Each scenario runs on every applicable slot. Pass criteria are in the last column.
"Required" rows block MP-N4 completion when they fail; "record" rows must have a result
but cannot fail the feature.

| ID | Scenario | Setup | Pass |
| --- | --- | --- | --- |
| V-I1 / V-A1 | Blocking `human_required` Command, app backgrounded, phone locked after first unlock | N-a | decrypted title+subtitle on lock screen; p95 send→display recorded (no fixed SLA claimed) |
| V-I2 / V-A2 | Same, app terminated by the system (not force-quit) | N-b | **required**: decrypted notification shown (N1 DV-P1, system-terminated) |
| V-A2b | Android app swiped away from recents, then Command | N-b | **required on A1 (Pixel)**: decrypted notification shown; **record on A2 (Samsung)** (OEM policy) (N1 DV-P1) |
| V-I3 / V-A3 | Device restarted, not unlocked | N-b | iOS: uniform fallback (E-B3). Android: record whether FCM delivers before first unlock (RQ-N4-4) and what shows |
| V-I4 | iOS app force-quit from app switcher, then Command | N-b | **record** whether alert+NSE still displays (RQ-N4-3) (N1 DV-P1) |
| V-A4 | Android app force-stopped in Settings → Force stop | N-b | **required**: no delivery (E-F7) **and** the MP-N4-C5-T03 warning shown on next launch (N1 DV-P1) |
| V-NS1 | Corrupted ciphertext; decrypt artificially delayed past 30 s (debug build flag) | N-a | **required**: uniform fallback / placeholder, no crash, no ciphertext or base64 shown (N1 DV-P2) |
| V-K1 | Invalidate the Android Keystore master key (remove the lock screen on an affected OEM, or the debug "invalidate key" action); then Command | N-b | **required**: the uniform fallback is **posted** (not nothing); in-app open shows "Open aiur to re-pair"; after the next online call the machine reports `push_health: keys_lost` and `aiur push status` shows "phone notifications broken" (Phase D M6) |
| V-A5 | Doze: `adb shell dumpsys deviceidle force-idle`; high vs normal priority | N-b | high delivers promptly; normal deferred; record both |
| V-A6 | 20 high-priority Commands in a day, all displayed | N-b | no deprioritization observed (E-F4) |
| V-I5 | Low Power Mode + Focus on; blocking Command | N-b | record behaviour per DESIGN-N4 interruption choice (Time Sensitive or not). If Time Sensitive is chosen: the app has the `com.apple.developer.usernotifications.time-sensitive` entitlement (MP-N1-C6-T01), and the record states whether a level set **by the NSE** (`interruptionLevel` on `bestAttemptContent`, not in the clear payload) is honoured |
| V-R1 | Airplane mode 3 h while 5 Commands, 2 resolutions, 3 progress milestones occur; then reconnect | N-c → N-b | ≤ 1 notification per stream + ≤ 1 digest per instance; resolved Commands not shown as open; no milestone older than the newest |
| V-R2 | Relay down 2 h during events; relay back | N-a | same as V-R1 (outbox staleness, AC-N4-7) |
| V-R3 | Machine offline after notification sent; user taps | N-d | app shows sealed summary + "Can't reach <machine>"; no answer submitted |
| V-R4 | Tailnet off, user taps | N-b | as V-R3; after enabling tailnet, "Retry" loads context |
| V-R5 | Dropped first push: device offline past the APNs single-store window (send a second, unrelated app notification to evict it), blocking Command stays `with_human` past the reminder interval | N-c → N-b | **required if DESIGN-N5 adopts reminders**: exactly one reminder (`attempt: 2`) arrives and replaces, not stacks; none after the Command resolves; the app icon badge equals the open blocking count (Phase D M3) |
| V-LS1 | Lock-screen privacy default (DESIGN-N4 lock-screen choice, proposed "hide body when locked") | N-a | record what the locked screen and a forwarded watch show; with "hide body": no summary body visible while locked (iOS placeholder, Android public version = fallback) |
| V-S1 | Forged payload (wrong signing key), replayed `nid`, expired payload sent via relay test tool | N-a | not shown as real content |
| V-S2 | Unpair device from machine, then trigger Command | N-a | no provider request for that device; relay handle gone |
| V-S3 | Remote unpair-all (D19) | N-a | all handles deleted; no pushes to any device |
| V-P1 | Capture relay request bodies and provider requests during V-I1 | N-a | no repo/ticket/Command/machine id or summary in clear |
| V-M1 | Two phones paired; answer on phone A | N-a | phone B notification retracted or shows "Answered on another device" on open (MP-N6) |
| V-M2 | Dashboard answers first, phone taps later | N-a | phone shows resolved state, cannot resubmit (D11) |
| V-M3 | Executor answered, not yet delivered; human answers on phone | N-a | human answer supersedes (D11), confirmation shown per DESIGN-E2 §4.4 |
| V-M4 | Two phones answer the same Command within 1 s | N-a | **required if a second phone slot exists**: one answer wins, the loser sees the winner, no duplicate delivery (N1 DV-P8) |
| V-W1 | Phone locked, watch on wrist; Command arrives | N-b | record whether watch shows decrypted content or fallback (E-B6) |
| V-W2 | Watch: tap notification → compact Command context → option → submitted | N-a | (MP-N6/N7) delivered; acknowledgement visible |
| V-W3 | Wear OS bridged notification; resolve on phone | N-a | watch notification dismissed (dismissal id) |
| V-W4 | Wear OS inline reply / RemoteInput on bridged notification | N-a | record support (E-W1 UNVERIFIED); only matters if DESIGN-N6 uses it |
| V-N1 | Tap notification (any state) | N-a | app opens to the exact Command context; mic is **not** active; mic choice sheet only after explicit tap (D16) |
| V-N2 | Tap notification while the same conversation is already open | N-a | no duplicate screen; context scrolls to the Command anchor |
| V-N3 | Tap a notification for a Command resolved since delivery | N-a | resolved state with who/when; no submit control |
| V-N4 | Tap with app cold-started from terminated | N-b → N-a | lands on the Command after pairing store loads; no flash of a generic inbox |
| V-N5 | Phone Converse session open (MP-N6-C4-T03): (a) restart the daemon mid-session; (b) reach the daily voice cap; (c) revoke the device mid-session | N-a | **required**: (a) `transport_lost` copy with Retry, transcript intact on the machine; (b) `cost_cap` copy, **no** Retry offered; (c) `auth_changed` copy, session ended, no Retry. Each reason shows its own copy, never a generic "error" (voice-session §8; feasibility M2/M7) |
| V-PR1 | Build order jumps 20 % → 70 % in one refresh | N-a | exactly one milestone notification (50 %), N5 high-water rule |
| V-PR2 | Build order progress drops (new tickets) and re-crosses 50 % | N-a | no repeat of 50 % |
| V-PR3 | Build order completes | N-a | one completion notification |
| V-I6 | NSE attempts `removeDeliveredNotifications` for a retraction | N-a | record whether it works (RQ-N4-5) |
| V-L1 | Payload at the 2,400-byte plaintext cap with long body | N-a | delivers; body truncated per contract §3 |

## 3. Measurements and report

- Latency is reported as observed distributions per scenario and network, not as a
  guarantee. The report states sample size and dates.
- Battery: record battery drain over a 24 h soak with 50 notifications on I1 and A2 vs a
  control day; report only measured numbers.
- The report lists every UNVERIFIED evidence item (E-B6, E-F7, E-W1, RQ-N4-3/5; E-F9 /
  RQ-N4-4 was settled from documentation in Phase D, and V-A3 confirms it)
  with its outcome and updates [platform-evidence.md](platform-evidence.md) accordingly.
- Any scenario that fails blocks MP-N4 completion until the plan is changed and re-run.

## 4. Prerequisites (owner-provided)

Apple Developer Program membership and a Firebase project for the publishing identity
(OQ-N4-1), TestFlight / internal testing tracks, the physical devices above, and a
deployed relay service in sandbox mode. Running the validation is a separately
authorized experiment, not implied by this plan.
