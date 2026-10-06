---
contract_id: MP-CT-notification-destination-and-payload
owner_feature: MP-N4
co_authors: MP-N5 (intent and preference fields), MP-N6 (destination resolution)
consumers: MP-N2, MP-N3, MP-N7, MP-E2, MP-E4, MP-R1, MP-R4
status: draft — Phase B, awaiting coordinator reconciliation
base_main_sha: 45a290e3
date: 2026-10-06
---

# Contract: notification destination and payload

One contract for everything that leaves an aiur machine as a push notification, and for
how a tapped notification finds its way back to the right machine, instance, agent and
Command. Platform evidence for every limit below is in
[MP-N4/platform-evidence.md](../bucket-3-mobile-watch/MP-N4/platform-evidence.md).

Terminology: **daemon** = one aiur instance's BEAM. **push-relay** = the daemon-side
client component (name from [MP-R1 component-map](../bucket-1-refactor/MP-R1/component-map.md)
row `push-relay`). **relay service** = the separately deployed HTTPS service that holds
the APNs/FCM sender credentials. **device** = one paired phone or watch install (MP-N2).

## 1. Layers and who can read what

```text
NotificationIntent (daemon, plaintext, never leaves the machine)
  └─► ProtectedPayload (plaintext JSON, ≤ 2,400 bytes) ──HPKE seal per device──► Sealed (opaque)
        └─► RelayEnvelope (daemon → relay service, HTTPS, outbound only)
              └─► Provider request (relay → APNs / FCM) carrying Sealed + a generic fallback
```

| Party | Sees | Never sees |
| --- | --- | --- |
| Daemon (the machine) | everything | device private keys |
| Relay service | daemon source IP; relay `handle`; `push_class`; `ttl_s`; opaque `collapse_token`; ciphertext length; time of send; platform push token and app topic (it must, to call APNs/FCM); handle↔push-token mapping, so it can link the handles of several machines paired to one device | summary text, repo, ticket, Command id, machine id, instance key, device encryption keys |
| Apple (APNs) / Google (FCM) | push token, app topic / Firebase project, priority, push type, expiry/TTL, collapse id/key (opaque), payload length, time, the **generic fallback text** (§5), relay IP | everything inside `Sealed` |
| Paired device | everything in `ProtectedPayload` for its own key | other devices' payloads |

The relay is **not trusted for confidentiality or authenticity**; it is trusted only not
to drop or delay traffic. A relay that forges or replays a sealed blob is detected (§4).

## 2. NotificationIntent (daemon-internal)

Produced by the MP-N5 policy engine, consumed by push-relay. Persisted in the push outbox
before any send (persist-before-notify, matching `Aiur.DecisionStore`'s rule,
`src/lib/aiur/decision_store.ex`).

| Field | Type | Notes |
| --- | --- | --- |
| `intent_id` | string, `ni_<ulid>` | stable; the per-device notification id `nid` is derived from it |
| `kind` | `command.needs_you` \| `command.resolved` \| `progress.milestone` \| `progress.complete` \| `pr.merged` \| `digest` \| `optin.<event>` | `optin.*` is the extension point for N5 opt-in events |
| `dedup_key` | string | §6; identical keys never send twice to the same device |
| `stream` | string | ordering stream, e.g. `cmd:<command_id>`, `bo:<root_id>`; newer `seq` supersedes older on a stream |
| `seq` | int ≥ 1 | per `stream`, monotonic, durable |
| `urgency` | `high` \| `normal` | `high` only for Commands that need the human and are blocking (N5 rule) |
| `expires_at` | RFC 3339 | after this the device discards silently |
| `audience` | `all_paired` \| `[device_id]` | N5 filters by per-device preference before fan-out |
| `summary`, `destination`, `retracts` | as §3 | |

## 3. ProtectedPayload v1 (what a device decrypts)

```json
{
  "v": 1,
  "nid": "n_01J9…",                     // unique per device
  "kind": "command.needs_you",
  "issued_at": "2026-10-06T17:02:11Z",
  "expires_at": "2026-10-07T17:02:11Z",
  "stream": "cmd:dec_8f2…", "seq": 1,
  "urgency": "high",
  "summary": {
    "title": "Migration decision",        // couple words, ≤ 40 chars, required
    "subtitle": "aiur · #2731",           // instance label · requester, ≤ 60 chars
    "body": "Pick a schema migration strategy before #2731 can continue." // ≤ 160 chars, optional
  },
  "destination": { … §3.1 … },
  "retracts": ["n_01J8…"],               // nids this payload replaces or withdraws, may be empty
  "sig": { "kid": "mk_…", "alg": "Ed25519", "value": "base64url…" }
}
```

- **Size budget.** Sealed overhead is 32 bytes (X25519 `enc`) + 16 bytes (AEAD tag) +
  base64 inflation (×4/3). APNs and FCM both cap the whole payload at 4,096 bytes
  (evidence E-A1, E-F1). The plaintext cap is **2,400 bytes** after JSON encoding,
  leaving room for the fallback alert and keys. The encoder truncates `body` first, then
  `subtitle`; `title` and `destination` are never truncated. Over-budget after truncation
  is an encoder error, not a silent drop.
- **`summary.title` source.** For Commands: the E2 "short label" (`context.short_summary`
  or native header, DESIGN-E2 §4.1). The fallback when it is missing is decided in
  DESIGN-E2 §4.1 [decide]; N4 only enforces the 40-char cap.
- **Signature.** `sig.value` is Ed25519 over the canonical JSON of the payload without
  `sig` (RFC 8785 JSON Canonicalization), using the **machine identity key** from MP-N2.
  Assumption A-N2-2 below.

### 3.1 Destination

```json
{
  "machine_id": "<26-char base32>",       // MP-N2 stable machine identity
  "instance_key": "1a2b3c4d5e",           // aiur_instance_key(), aiur-engine.sh
  "repo": "aiur-team/aiur",               // display + sanity check only
  "target": {
    "kind": "command",                    // command | conversation | build_order | instance
    "command_id": "dec_8f2…",             // Aiur.Decision decision_id
    "ticket": "2731",                     // nil for Executor-originated Commands
    "agent": { "role": "worker", "session_id": "…" },   // role: worker | executor
    "anchor_id": "anc_…",                 // MP-E4 event-to-conversation anchor, optional
    "root_id": null                       // build-order root for progress kinds
  }
}
```

Rules:

1. A destination **names** objects; it grants nothing. Opening it always fetches the
   current state over the private path with the device credential (MP-N2). A device that
   is not paired with `machine_id` shows "Not paired with this machine" and fetches
   nothing.
2. Resolution order on tap (MP-N6 owns the client logic): machine → instance → target →
   anchor. Each missing level degrades to the level above with a visible note
   ("This Command is no longer on aiur · #2731; showing the instance"), never to a
   generic inbox or an unrelated chat.
3. `instance_key` alone is not trusted: the app checks that the instance it reaches on
   `machine_id` reports the same key and `repo`. A mismatch is "Instance changed" (the
   project root moved; MP-N2 discovery owns re-mapping).
4. No URL, hostname, IP or tailnet name appears in a destination. Reachability is the
   paired device's own registry (MP-N2), so a changed URL never invalidates a delivered
   notification.

### 3.2 Kinds and their destinations

| `kind` | `target.kind` | Default (D18) | Urgency |
| --- | --- | --- | --- |
| `command.needs_you` | `command` | always on | `high` if blocking, else `normal` |
| `command.resolved` | `command` | always on (it is a retraction) | `normal` |
| `progress.milestone` | `build_order` | on, every 25 % | `normal` |
| `progress.complete` | `build_order` | on | `normal` |
| `pr.merged` | `conversation` (ticket's worker) | opt-in | `normal` |
| `digest` | `instance` | follows its members | max of members |
| `optin.*` | per event | opt-in | `normal` |

## 4. Sealing (encryption and authenticity)

- **Scheme:** HPKE (RFC 9180) base mode, suite `DHKEM(X25519, HKDF-SHA256)`,
  `HKDF-SHA256`, `ChaCha20-Poly1305`. Available as CryptoKit `HPKE` (iOS 17+, watchOS
  10+) and Tink HPKE on Android (E-C1, E-C2). The daemon implements the same suite with
  Erlang `:crypto` primitives and is tested against RFC 9180 Appendix A vectors.
- **`info`** = `"aiur-push-v1"`. **`aad`** = `v ‖ device_id ‖ kid ‖ nid`, so a blob cannot
  be replayed to another device or under another key.
- **Device key:** one X25519 key pair per device install, generated **on the device**,
  private key never exported. iOS: keychain item in a shared keychain access group of the
  app and its Notification Service Extension, accessibility
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (E-B3). Android: Tink keyset wrapped
  by an Android Keystore key created **without** `setUnlockedDeviceRequired(true)` and
  stored in credential-encrypted storage (E-F9). Watch keys: MP-N7 / §7.
- **Authenticity:** the inner Ed25519 `sig` from the machine identity key. A device
  rejects (and does not display) a payload whose signature fails, whose `kid` it does
  not know, whose `expires_at` has passed, or whose `nid` it has already seen. Rejection
  falls back to the generic text only if the OS already displayed it (iOS NSE failure
  path, §5).
- **Rotation:** a device may hold two keys (`kid` current and previous) during rotation.
  The daemon seals to the newest registered `kid`. Re-pairing replaces both.

## 5. Provider mapping and fallback text

### APNs (iOS, and watchOS direct when MP-N7 uses it)

```json
{ "aps": { "alert": { "title": "aiur", "body": "New notification" },
           "mutable-content": 1 },
  "s": "<base64url Sealed>", "k": "<kid>", "v": 1 }
```

Headers: `apns-push-type: alert`; `apns-priority: 10` for `urgency: high`, `5`
otherwise; `apns-expiration` = `expires_at`; `apns-collapse-id` = `collapse_token`
(§6, ≤ 64 bytes, E-A2). No `category`, `thread-id` or `interruption-level` in clear:
the Notification Service Extension sets `categoryIdentifier`, `threadIdentifier`
(per instance) and `interruptionLevel` after decryption so Apple never sees them.

**Fallback.** If the extension cannot decrypt (device restarted and not yet unlocked,
time limit, crash, unknown key), iOS displays the original alert (E-A3). Therefore the
clear alert is a **single uniform string for every kind**. The string is a DESIGN-N4
decision; the default proposal is title `aiur`, body `New notification`. It must never
name a machine, repo, ticket, kind or count.

### FCM (Android)

Data-only message: `data = { "s": Sealed, "k": kid, "v": "1" }`; `android.priority`
`high` for `urgency: high`, `normal` otherwise; `android.ttl` = `expires_at - now`
(≤ 28 days, E-F3); `android.collapse_key` = one of **two** opaque constants (`a` for
Command streams, `b` for everything else) because FCM stores at most four collapse keys
per device (E-F2). No `notification` block — a notification block would be displayed by
the system without the app decrypting it (E-F1). The app posts the notification itself
from `onMessageReceived` after decrypting; failure posts the same uniform fallback.

A high-priority FCM message must result in a visible notification, or FCM deprioritizes
the app (E-F4). Rule: **only `urgency: high` uses high priority, and every `urgency: high`
payload that passes verification is displayed.** `command.resolved` uses normal priority.

## 6. Identity, de-duplication and ordering

- `nid` = `"n_" ‖ base32(HMAC-SHA256(device_push_secret, intent_id))[0..25]`.
  Different per device, stable across retries.
- `collapse_token` = base64url(HMAC-SHA256(device_push_secret, stream))[0..32]: opaque
  to Apple/Google/relay, stable per stream so a newer progress milestone or a resolution
  replaces an older undelivered one in APNs storage.
- `device_push_secret` is a 32-byte secret created at pairing and shared only between
  the device and the machine (MP-N2 credential bundle, assumption A-N2-3).
- Daemon-side `dedup_key` rules (owned by MP-N5, listed here for reconciliation):
  `command.needs_you` → `cmd:<command_id>:needs_you` (once per Command, matching E2 `human_needed`);
  `command.resolved` → `cmd:<command_id>:resolved`; `progress.milestone` →
  `<scope>:<id>:<generation>:m<pct>` (scope `bo` or `q`, generation from the E1 contract);
  `progress.complete` → `<scope>:<id>:<generation>:complete`;
  `pr.merged` → `pr:<repo>#<n>:merged`.
- Device rules: drop if `nid` seen; drop if a payload on the same `stream` with higher
  `seq` was already shown; drop if `expires_at` passed; apply `retracts` by removing the
  listed delivered notifications.

## 7. Device registration records

**Device → relay service** (`POST /v1/handles`, TLS):
`{platform: "apns"|"fcm", push_token, app_topic, environment: "production"|"sandbox"}` →
`{handle, send_secret}`. The device repeats this once per paired machine so each machine
holds a different handle. `DELETE /v1/handles/:handle` with `send_secret` revokes.

**Device → machine** (over the MP-N2 paired channel, never through the relay; stored as the
opaque `push_registration` of the device row in `devices.json`):

```json
{ "device_id": "d_…", "platform": "ios"|"android"|"watchos"|"wearos",
  "relay_url": "https://…", "handle": "h_…", "send_secret": "…",
  "device_push_secret": "base64url(32 bytes)",
  "enc_keys": [{"kid":"k_…","x25519_pub":"base64url…"}],
  "capabilities": {"nse": true, "decrypt_while_locked": "after_first_unlock",
                   "watch_forwarding": "unverified"} }
```

The MP-N2 gateway writes it; push-relay in each instance reads it. Watches that
receive pushes directly register as their own device with their own key (MP-N7).

## 8. Relay envelope (daemon → relay service)

`POST <relay_url>/v1/send` with header `Authorization: Bearer <send_secret>` and body
`{v:1, handle, push_class: "alert_high"|"alert_normal", ttl_s, collapse_token, sealed, kid}`.

Responses: `202` accepted (relay does not wait for APNs); `404 handle_unknown` and
`410 handle_gone` (APNs `Unregistered` / FCM `UNREGISTERED`) → push-relay marks that
device `push_state: gone` and stops sending; `429` with `retry_after_s`; `5xx` → retry
with backoff. The relay never logs `sealed` and retains `{handle, time, size, status}`
for at most 7 days (relay service config, MP-N4-C2).

## 9. Reconciliation with contracts owned elsewhere

Checked against the sibling drafts present on 2026-10-06. "Matches" means no change is
needed on either side; "Request" is a change this contract asks the owner to make.

| ID | Owner contract | Status | Detail |
| --- | --- | --- | --- |
| A-E2-1 | [command-request-and-resolution.md](command-request-and-resolution.md) §4, §8 | Matches | `human_needed` (`ticket.<id>.agent.decision.human-needed` / `executor.decision.human-needed`) fires **once per Command** when `human_visible_at` is first set, carrying `{decision_id, version, short_label, requester, blocking, urgency, cause}` and no question text. N5 maps it to `command.needs_you`; the dedup key is therefore per Command, not per routing epoch (§6). A Command deferred back to the Executor and escalated again does not push twice. |
| A-E2-2 | same, §8 | Matches | Terminal slugs on the same topic scheme drive `command.resolved`; the DecisionStore snapshot (journaled) is the boot-time reconciliation source. |
| A-E2-3 | same, §3 | Matches | `short_label` = `context.short_summary` → native `header` → `kind`. N4 caps it at 40 chars for the title. |
| A-E2-4 | same, §6, §9 | Matches | Phone/watch answers use the same answer shape with `actor: {kind: :operator}`, `client: {surface: "phone"\|"watch", device_id}`; conflicts are HTTP 409 `decision_conflict` extended with the winning answer; `:duplicate` for same-key retries; `answer_delivered` / `answer_in_flight` for late supersede. MP-N6 §5.2 maps these. |
| A-R2-1 | [events-and-replay.md](events-and-replay.md) §3, §6, §7 | Matches, with a note | Event ids are unique but **not a delivery order**; push-relay and the N5 policy use the proposed durable-consumer primitive (subscribe, replay from export `seq`, live, dedupe on id). `human_needed` and Command slugs are `journaled`; milestones are `ledgered`; `ticket.*.pr.merged` from GitHub is `live`, so a merge observed while the daemon is down is not notified (acceptable: opt-in, and staleness rules would drop it). |
| A-N2-1 | [pairing-and-instance-registry.md](pairing-and-instance-registry.md) §1, §5 | Matches | `machine_id` (26-char base32), machine store `devices.json` read by every instance; the gateway is the single writer. |
| A-N2-2 | same, §1 | Matches | `machine_key` is Ed25519; devices pin it from the QR. It signs `ProtectedPayload` (§4). |
| A-N2-3 | same, §2, §4.5, RC-3 | Matches | The device row has an opaque `push_registration`; this contract defines its content as the §7 record (`relay_url`, `handle`, `send_secret`, `enc_keys`, `device_push_secret`, capabilities). Revocation calls the MP-N4 deregistration hook. The device push key is separate from the P-256 device auth key, as N2 requires. |
| A-N2-4 | same, §4.4 | Matches | Instances accept the device bearer token on existing protected routes; MP-N6 adds `/api/v1/device/commands*` that **require** a device token so the recorded actor carries `device_id`. MP-N5 preference writes go through the gateway (single writer of the machine store). |
| A-N7-1 | same, RC-4 | Matches | A direct-push watch is a child device (`parent_device_id`) with its own push key; revoking the phone revokes it. |
| A-E1-1 | [queue-readiness-and-build-progress.md](queue-readiness-and-build-progress.md) §4 | **Request** | E1 emits milestones only at 25/50/75/100 per scope generation. N5 must also support 10 % and 50 % steps per device. Request: E1 additionally emits a `live` `system.build_order.<root>.progress.observed` (and `system.queue.<id>.progress.observed`) with `{percent, resolution, generation}` on each change, or exposes `Aiur.BuildQueue.progress/1` for N5 to read on the milestone/merge signal. N5 applies E1's no-burst / no-repeat / no-unknown rules per device step. |
| A-E4-1 | [conversations-transcripts-anchors.md](conversations-transcripts-anchors.md) | Matches | `anchor_id` = `anc_<sha256(event_ref, conversation_id)>`, with a `method` that may be `none`; absent anchors degrade per §3.1 rule 2. |
| A-E5-1 | [voice-session.md](voice-session.md) | Matches | Phone and watch authenticate voice sessions with the MP-N2 device credential; provider keys stay on the daemon. |
| A-R1-1 | [identity-and-capabilities.md](identity-and-capabilities.md); MP-R1 capability-matrix §2 | Matches | Capability ids `push`, `pairing`, `build_orders.progress`, `build_queue`, `commands.answer`, `voice.stt`, `voice.conversation`. |

## 10. Versioning

`v` is on every layer. A device that receives an unknown `v` shows the fallback and asks
the app to update; the daemon never downgrades a payload to fit an old device. Additive
fields are allowed within `v: 1`; unknown fields are ignored.
