---
feature_id: MP-N1
covers: [MP-N1, MP-N4 client side, MP-N6 phone, MP-N7 (DV-W rows)]
base_main_sha: 45a290e3
date: 2026-10-06
---

# Physical-device validation plan (phone and watch)

Brief §6 N4 requires validation on physical devices before implementation is
called complete. Simulators are not enough here: the watchOS simulator always
allows low-level networking (TN3135, S7), notification forwarding to a watch
needs real pairing, and the NSE's behaviour while the device is locked cannot be
reproduced faithfully on a simulator.

This plan defines the matrix and the procedure. Running it is part of each
chunk's verification; it is not authorised now.

## 1. Device matrix

| Slot | Minimum | Purpose |
|---|---|---|
| iPhone A | Supported iOS (OQ-N1-2), physical | Primary iOS runs |
| Apple Watch A | Paired to iPhone A, current watchOS (S14) | DV-W rows |
| Android phone A | Android 13+ (to exercise `POST_NOTIFICATIONS`, S30), Google Play services | Primary Android runs |
| Wear OS watch A | Wear OS 5 or 6, paired to Android phone A | DV-W rows |
| Optional iPhone B / Android B | Any | Multi-device conflicts (DV-P8) |
| aiur machine | One host with two instances, reachable over the operator's tailnet and over LAN | Reachability rows |

Owner question OQ-N1-4 confirms which devices exist. A missing slot is recorded as
"not validated on <slot>" in the readiness report, never silently skipped.

## 2. Phone rows

| ID | Scenario | Procedure | Pass condition | Required |
|---|---|---|---|---|
| DV-P1 | Encrypted push, app in foreground, background and killed | Send a sealed test-vector payload through APNs or FCM for each app state | The decrypted short summary appears in all three states. Killed and force-quit states are included. | Yes |
| DV-P2 | NSE timeout and failure | Corrupt the ciphertext; then delay decryption past 30 s in a debug build | The generic placeholder shows; there is no crash and no ciphertext shown (S3) | Yes |
| DV-P3 | Locked since reboot | Reboot the phone, do not unlock, send a push | The placeholder shows (key class AfterFirstUnlock, S5). After unlocking, opening the notification still routes correctly. | Yes |
| DV-P4 | Android Doze and priority | Put the phone in Doze (`adb shell dumpsys deviceidle force-idle`), send a high-priority data message | A visible notification appears within the documented behaviour. Record latency. Confirm no deprioritization after 20 sends that each produce a visible notification (S29). | Yes |
| DV-P5 | Reachability states | Turn the tailnet off; stop one instance; make one instance's capability stale | The meta-dashboard shows `unreachable`, `unavailable` and `stale` distinctly, each with age | Yes |
| DV-P6 | WebView rendering | Load `/`, `/chat/...`, `/commands`, `/build-orders` at the narrowest device width and at 430 px | No horizontal page scroll. The native header does not cover controls. Record any surface that should go native (surface-boundary.md §3). | Yes |
| DV-P7 | WebView mic | On an HTTPS origin, open a worker chat, press Dictate | The OS mic permission prompt appears once per the app policy; transcription returns. On an HTTP origin the mic shows `unavailable` with its reason. | Yes |
| DV-P8 | Conflicting answers | Two phones (or phone + dashboard) answer the same Command within 1 s | One wins; the other shows the winner's summary; no duplicate delivery | Yes if slot B exists |
| DV-P9 | Session expiry and revocation | Expire the WebView session; then revoke the device from the machine | A single silent re-bootstrap on expiry. On revocation, the machine disappears and its credentials and cookies are wiped (inspect the keychain via a debug screen) | Yes |
| DV-P10 | Network transition | Start an answer on Wi-Fi, switch to cellular mid-request | The idempotent retry yields one recorded answer | Yes |
| DV-P11 | Notification-tap routing | Tap a Command notification for instance 2 while instance 1's WebView is open | The native Command screen for the right instance and Command opens; Back returns to the prior screen | Yes |
| DV-P12 | Permission denied | Deny notifications, mic and camera | Each affordance shows `needs_permission` with a Settings link; nothing else breaks | Yes |
| DV-P13 | Battery and data sanity | Leave the app backgrounded 8 h with 2 instances | No measurable background activity attributable to the app beyond pushes (iOS battery screen; Android `dumpsys batterystats`) | Advisory |

## 3. Watch rows (owned by MP-N7, listed here so one plan covers devices)

| ID | Scenario | Pass condition | Required |
|---|---|---|---|
| DV-W1 | Apple Watch shows the NSE-decrypted text | With iPhone locked and watch on wrist (S15), the watch shows the decrypted summary, not the placeholder (S39 is vendor evidence only) | Yes |
| DV-W2 | Watch app → phone wake | With the iPhone app suspended, opening a Command on the watch fetches it through `sendMessage` (S6). Record latency. | Yes |
| DV-W3 | Phone unreachable | With the iPhone out of Bluetooth range, the watch shows "Needs iPhone nearby" rather than stale data presented as live | Yes |
| DV-W4 | Watch answer | Choosing a suggested option on the watch records exactly one answer with `client.surface: "watch"` | Yes |
| DV-W5 | Watch dictate | System dictation on the watch returns text for review before Send (the same review rule as E5 dictation) | Yes |
| DV-W6 | Watch converse | Turn-based converse through the phone (MP-N7 §5): measure the round trip; record whether it meets DESIGN-N7's latency acceptance | Yes |
| DV-W7 | Wear OS bridging | A phone-decrypted notification bridges to the Wear OS watch once; dismissing on one device dismisses on the other (`setDismissalId`, S33) | Yes |
| DV-W8 | Wear OS standalone network | With the phone off, confirm the Wear app shows "Needs phone" (non-standalone). Record whether bridged traffic through the phone reaches a tailnet-only daemon (S35 UNVERIFIED) | Yes |
| DV-W9 | WebSocket on watchOS | Confirm that a `URLSessionWebSocketTask` to the daemon stays `.waiting` on device (S7). This guards against designs that pass only on the simulator. | Yes |

## 4. Procedure rules

- Every run records: device model, OS version, app build and git SHA, daemon version, network path (tailnet or LAN), and timestamps. Store results in the chunk's ticket as a table, not a sentence.
- A latency figure is a measurement with units and a count (for example "median 2.1 s over 20 sends"), following AGENTS.md "A claimed saving must be measured".
- Failures are filed as tickets with the row ID. A required row that fails blocks "complete" for the owning feature.
- Sealed test vectors come from `packages/aiur-mobile/fixtures/contract/` so the device test and the unit test use the same bytes.
