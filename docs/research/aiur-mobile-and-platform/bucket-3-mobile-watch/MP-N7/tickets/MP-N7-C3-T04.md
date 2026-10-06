---
ticket_id: MP-N7-C3-T04
feature_id: MP-N7
chunk_id: MP-N7-C3
bucket: 3-mobile-watch
title: Wear OS Command notifications posted by the Wear app (bridging disabled for the Command tag) with dismissal sync
status: blocked
blocked_by: [DESIGN-N7, DESIGN-N4, MP-N7-C3-T03, MP-N7-C1-T03, MP-N4-C5-T02, MP-N4-C6-T02]
prior_units: []
prior_boundaries: []
prior_features: [MP-N4, MP-N1]
prior_findings: ["N7-RQ2 resolved: bridged actions run on the phone"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C3-T04 — Wear OS notifications that open the Wear app

## Identity and outcome

- Bucket 3, MP-N7, chunk C3.
- **User value:** a blocker notification on a Wear OS watch opens the Command card **on
  the watch**, not "open on phone", and disappears on both devices once handled.
- **Deliverable:**
  1. Wear app: at first run, `BridgingManager.setConfig(BridgingConfig.Builder(ctx,
     isBridgingEnabled = true).addExcludedTags(setOf("aiur-command")).build())` so phone
     notifications tagged `aiur-command` are not bridged, while everything else still is.
  2. Wear app: on watch-link `notify`, post a local notification on channel
     `aiur_commands` with `contentIntent` → `CommandCardScreen(instance, decision)` and
     `WearableExtender().setDismissalId(dismissal_id)`; on `notify_cancel`, cancel it.
  3. Phone broker (`AiurWearListenerService`, MP-N7-C1-T03): forward `notify` /
     `notify_cancel` (via `MessageClient.sendMessage`, fire-and-forget is acceptable here:
     the phone still has its own notification) whenever the phone's FCM service posts or
     removes an `aiur-command` notification.
- **Non-goals:** the phone-side notification itself (MP-N4-C5-T02 posts it; MP-N4-C6-T02
  sets the bridge tag and dismissal id, see CONTRACT-REQUESTS item 4).

## Dependencies and blockers

DESIGN-N7 (screen 8), DESIGN-N4 (text); MP-N7-C3-T03, MP-N7-C1-T03, MP-N4-C5-T02,
MP-N4-C6-T02.

## Verified starting point

**N7-RQ2, resolved (accessed 2026-10-06):**

- "If you are using bridged notifications, any notification automatically includes a
  button to launch the app on the phone", and `WearableExtender` actions "execute on the
  phone, not on the watch" (<https://developer.android.com/training/wearables/notifications>,
  updated 2026-09-22). A bridged notification therefore cannot open the Wear app's card,
  and an option action on it would run on the phone and be recorded with the wrong surface.
- Bridging control: `setBridgeTag` on the phone notification; `BridgingConfig` with
  excluded tags; `setDismissalId` — "When a user dismisses a notification, all
  notifications with the same dismissal ID are dismissed on both watch and phone"; "Dismissal
  IDs work with Android phones but not with iPhone pairings"
  (<https://developer.android.com/training/wearables/notifications/bridger>, updated 2026-09-22).

Decision: Wear app posts its own notification for Commands. If the Wear app is not
installed, no `BridgingConfig` exists and the phone notification bridges by default, so a
watch without the app still gets awareness.

**UNVERIFIED (device):** (a) that `BridgingConfig` set by a *non-standalone* Wear app is
honoured (the doc frames it for standalone apps, "particularly important for … Wear OS 5 or
higher"); (b) that a dismissal id on a watch-local notification dismisses the phone copy.
Both are DV-W7 rows (MP-N7-C6-T02). Fallback if (a) fails: keep bridging, no Wear-local
notification, and the watch user taps "open on phone" — recorded as a DV result and a
DESIGN-N7 note, not improvised.

## Chosen design

- Tag `aiur-command` (constant shared with MP-N4-C5-T02 via the contract fixture
  `fixtures/watch-link/constants.json`).
- Dismissal id `<instance_id>:<decision_id>` (plan §7).
- Ordering: phone FCM service posts phone notification → calls broker `notify`. Watch
  posts local notification. Resolution elsewhere → phone removes its notification
  (MP-N6-C6) → broker `notify_cancel` → watch cancels.
- No mic, no audio on open (brief N6).
- Notification channel importance high (blocker); DESIGN-N4 confirms.

## Implementation steps

1. Wear: `BridgingSetup.kt` invoked from `Application.onCreate` (idempotent).
2. Wear: handle `notify`/`notify_cancel` in its `WearableListenerService`.
3. Phone: broker hooks called by the FCM service (MP-N4-C5-T02 exposes a native callback).
4. Tests.

## Non-happy paths

- Watch out of range when `notify` is sent: `sendMessage` fails silently; phone notification
  remains; when the watch reconnects, the next snapshot shows the Command in the list.
  (No replay of stale notifications after reconnect: brief N5 "no burst of outdated alerts".)
- Command already resolved by the time the watch posts: card refetch shows resolved state.
- Revoked machine: `notify_cancel{revoked}` for all its dismissal ids.

## Compatibility and rollout

Behind `WearFeatures.localCommandNotifications` (default on after DV-W7 passes; off →
bridging fallback). Rollback = flag off.

## Verification

```text
packages/aiur-mobile/wear/gradlew -p packages/aiur-mobile/wear :app:testDebugUnitTest --tests '*NotifyHandlerTest' --tests '*BridgingSetupTest'
packages/aiur-mobile/android/gradlew -p packages/aiur-mobile/android :aiur-native:testDebugUnitTest --tests '*WearNotifyForwarderTest'
```

| Test | Expected | Must fail without |
|---|---|---|
| `BridgingSetupTest.excludesCommandTag` | config captured with excluded `aiur-command`, bridging enabled | the config call |
| `NotifyHandlerTest.postsWithDismissalIdAndCardIntent` | posted notification has dismissal id and intent extras for the card | posting code |
| `NotifyHandlerTest.cancelRemoves` | cancel → `NotificationManager.cancel` with the same id | cancel path |
| `NotifyHandlerTest.noAudioOnOpen` | intent handler does not touch `AudioManager` | — (guard; commented) |
| `WearNotifyForwarderTest.forwardsOnPostAndRemove` | broker sends both messages | forwarder hooks |

Device rows: DV-W7, DV-W7b (MP-N7-C6-T02).

## Completion and handoff

- [ ] Local notifications open the Wear card; flag default decided by DV-W7.
- Dependents: MP-N7-C6-T02.
