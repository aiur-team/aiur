---
contract_id: MP-CT-notification-destination-and-payload
owner_feature: MP-N4
co_authors: MP-N5 (intent and preference fields), MP-N6 (destination resolution)
consumers: MP-N2, MP-N3, MP-N7, MP-E2, MP-E4, MP-R1, MP-R4
status: draft v2 — Phase C (RC-02, RC-03, RC-08..RC-10 applied; crypto framing fixed, §11)
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
  └─► ProtectedPayload (UTF-8 JSON, ≤ 2,400 bytes)
        └─► InnerFrame = 0x01 ‖ Ed25519 sig (64 B) ‖ payload bytes ──HPKE seal per device key──► Sealed (opaque)
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
| `instance_id` | string | `<machine_id>/<instance_key>` (RC-02); the daemon that produced the intent |
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
  "retracts": ["n_01J8…"]                // nids this payload replaces or withdraws, may be empty
}
```

The payload carries **no** signature field. The signature is detached and travels in the
inner frame (§4), computed over the exact payload bytes, so no platform has to reproduce a
canonical JSON form (Phase C change, §11).

- **Size budget.** Payload JSON ≤ **2,400 bytes**. Inner frame adds 65 bytes (version
  byte + 64-byte signature); HPKE adds 32 bytes (`enc`) + 16 bytes (AEAD tag); so
  `Sealed` ≤ 2,513 bytes, which is ≤ 3,351 characters as unpadded base64url. The
  provider wrapper (§5) with the uniform fallback (≤ 200 bytes UTF-8 for title + body)
  and the `k`/`v` keys stays below the 4,096-byte cap of APNs and FCM (E-A1, E-F1). The
  encoder truncates `body` first, then `subtitle`, on a UTF-8 code-point boundary;
  `title` and `destination` are never truncated. Over budget after truncation is an
  encoder error, not a silent drop. Floats are not allowed anywhere in the payload.
- **`summary.counts`** (digest only, additive in v1): `{"<kind>": n, …}` counts of the
  folded intents (MP-N5-C3-T01). The device renders the digest from counts per DESIGN-N4;
  `summary.title` is a neutral placeholder for older apps.
- **`summary.title` source.** For Commands: the E2 "short label" (`context.short_summary`
  or native header, DESIGN-E2 §4.1). The fallback when it is missing is decided in
  DESIGN-E2 §4.1 [decide]; N4 only enforces the 40-char cap.
- **Signature.** Detached Ed25519 by the **machine identity key** (`machine_key`, MP-N2),
  over the domain-separated message in §4. Assumption A-N2-2 below.

### 3.1 Destination

```json
{
  "machine_id": "<26-char base32>",       // MP-R1/MP-N2 stable machine identity
  "instance_id": "<machine_id>/1a2b3c4d5e", // RC-02; instance_key = aiur_instance_key(), aiur-engine.sh
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
3. `instance_id` alone is not trusted: the app checks that the instance it reaches on
   `machine_id` reports the same `instance_id` and `repo`. `instance_id` must start
   with `machine_id + "/"`; a payload that breaks this is rejected as malformed. A mismatch is "Instance changed" (the
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

- **Scheme:** HPKE (RFC 9180) base mode, single-shot (sequence 0), suite
  `DHKEM(X25519, HKDF-SHA256)`, `HKDF-SHA256`, `ChaCha20-Poly1305` (kem 0x0020, kdf 0x0001,
  aead 0x0003). Available as CryptoKit `HPKE` (iOS 17+, watchOS 10+) and Tink HPKE on
  Android (E-C1, E-C2). The daemon implements it with Erlang `:crypto` primitives on the
  pinned OTP 28 (X25519 `:eddh`, HMAC-SHA256, `chacha20_poly1305`); RFC 9180 A.2.1 was
  reproduced with those primitives in Phase C (MP-N4-C1-T01, evidence E-C4).
- **`info`** = ASCII `aiur-push-v1` ‖ 0x00 ‖ `device_id` ‖ 0x00 ‖ `kid` (UTF-8). Both
  values are known to the device before it decrypts (`kid` is in the clear wrapper, §5;
  it maps to the device's own `device_id` for that machine), so a blob cannot be replayed
  to another device or key: HPKE binds `info` into the key schedule.
- **`aad`** = empty. Reason: Tink's `HybridDecrypt` passes its `contextInfo` as the HPKE
  `info` and always uses empty associated data (tink-java `HpkeDecrypt.java` @
  `d042a5f7`, 2026-10-05: `HpkeContext.createRecipientContext(…, info)` then
  `context.open(…, EMPTY_ASSOCIATED_DATA)`), so the binding must live in `info` to use
  Tink's public API on Android. CryptoKit accepts both. (The Phase B draft put `nid` in
  the AAD; a device cannot know `nid` before decrypting. Replay is caught by `nid` inside
  the payload, §6.)
- **`Sealed`** = `enc` (32 bytes) ‖ ciphertext ‖ tag (16 bytes) — Tink's RAW hybrid wire
  format for HPKE (no 5-byte prefix; Tink wire-format page, updated 2026-09-30).
- **Inner frame (the HPKE plaintext):** byte 0 = frame version `0x01`; bytes 1–64 =
  Ed25519 signature; bytes 65… = the ProtectedPayload JSON bytes exactly as signed.
- **Signed message** = ASCII `aiur-push-v1-sig` ‖ 0x00 ‖ `info` ‖ payload bytes. The device
  verifies the signature over the bytes it received and only then parses them as JSON.
  No canonicalization is needed on any platform.
- **Device push key:** one X25519 key pair **per device install per paired machine**,
  generated **on the device**, private key never exported. `kid` = `k_` + 26 base32 chars,
  random, unique on the device; the device keeps `kid → {machine_id, device_id, key}`.
  iOS: keychain item in a shared keychain access group of the app and its Notification
  Service Extension, accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  (E-B3). Android: Tink keyset wrapped by an Android Keystore key created **without**
  `setUnlockedDeviceRequired(true)` and stored in credential-encrypted storage (E-F9).
  Watch keys: MP-N7 / §7. This key is separate from the P-256 device auth key (pairing
  contract §2).
- **Authenticity:** the inner Ed25519 signature by the machine key pinned at pairing for
  the `machine_id` that `kid` maps to. A device rejects (and does not display as real) a
  payload whose signature fails, whose frame version or `v` it does not know, whose
  `destination.machine_id` differs from the machine `kid` maps to, whose `expires_at`
  has passed (5-minute skew tolerance), or whose `nid` it has already seen. Rejection
  falls back to the generic text only if the OS already displayed it (iOS NSE failure
  path, §5).
- **Rotation:** a device may hold two keys per machine (current and previous `kid`) during
  rotation. The daemon seals to the newest registered `kid`. Re-pairing replaces both.
- **Runtime guard:** the daemon checks `crypto:supports/1` for `eddh`/`x25519`,
  `eddsa`/`ed25519` and `chacha20_poly1305` at start (the list can be reduced by the
  linked libcrypto or FIPS mode); if any is missing, capability `push` is
  `unavailable` with reason `dependency_unavailable`, `depends_on: ["runtime.crypto"]`.

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
name a machine, repo, ticket, kind or count, and title + body together are ≤ 200 bytes
UTF-8 (§3 size budget). The daemon owns the string (one value per machine, shipped with
the release); the relay service only copies the `fallback` field it is given (§8).

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

- `nid` = `"n_"` ‖ the first 26 characters of the lowercase, unpadded RFC 4648 base32
  encoding of HMAC-SHA256(`device_push_secret`, `"nid\x00"` ‖ `intent_id`).
  Different per device, stable across retries.
- `collapse_token` = the first 32 characters of the unpadded base64url encoding of
  HMAC-SHA256(`device_push_secret`, `"collapse\x00"` ‖ `stream`): opaque
  to Apple/Google/relay, stable per stream so a newer progress milestone or a resolution
  replaces an older undelivered one in APNs storage.
- `device_push_secret` is a 32-byte secret created at pairing and shared only between
  the device and the machine (MP-N2 credential bundle, assumption A-N2-3).
- Daemon-side `dedup_key` rules (owned by MP-N5, listed here for reconciliation):
  `command.needs_you` → `cmd:<command_id>:needs_you` (once per Command, matching E2 `human_needed`);
  `command.resolved` → `cmd:<command_id>:resolved`; `progress.milestone` →
  `<scope>:<id>:<generation>:m<pct>` (scope `bo` or `q`, generation from the E1 contract;
  `pct` is the per-device step threshold crossed, so 10/20/…/90 occur for a 10 % step —
  RC-10: N5 computes per-device thresholds from E1's progress read API and
  progress-changed signal, E1's milestone events stay at 25 %);
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

The MP-N2 gateway writes it; push-relay in each instance reads it. The record in one
machine's store lists only the push keys made for that machine (§4: one key per device
install per machine). `relay_url` must be `https://`; push-relay refuses any other scheme
except `http://127.0.0.1` / `http://localhost` when `push.allow_loopback_relay: true`
(tests and self-hosted development only). Watches that receive pushes directly register
as their own device with their own key (MP-N7).

Machine-level push settings live in `~/.aiur/machine` under `push:` (RC-03; pairing
contract §8), never in `~/.aiur/config`: `enabled` (default `false`),
`outbox.max_age_seconds` (`86400`), `send_timeout_ms` (`5000`),
`allow_loopback_relay` (`false`). No secret is ever a setting.

## 8. Relay envelope (daemon → relay service)

`POST <relay_url>/v1/send` with header `Authorization: Bearer <send_secret>` and body
`{v:1, handle, push_class: "alert_high"|"alert_normal", ttl_s, collapse_token, sealed, kid,
idempotency_key, fallback: {title, body}}`. `idempotency_key` is the `nid` (opaque); the
relay answers a repeated `(handle, idempotency_key)` within 24 h with the first result
and does not send twice. `fallback` is the uniform string of §5, identical for every send.

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
| A-R2-1 | [events-and-replay.md](events-and-replay.md) §3, §6, §7 | Matches, with a note | Event ids are unique but **not a delivery order**. RC-09: the N5 policy reads the export feed through the DurableConsumer (MP-R2-C6-T04) when `events.export.enabled` is true, and otherwise a live `Exchange` subscription; in both modes boot and `gap` reconciliation from the owning stores plus the N5 dedup ledger give correctness, and the export journal only narrows the window in which live-class opt-in events are lost. `human_needed` and Command slugs are `journaled`; milestones are `ledgered`; `ticket.*.pr.merged` from GitHub is `live`, so a merge observed while the daemon is down is not notified (acceptable: opt-in, and staleness rules would drop it). |
| A-N2-1 | [pairing-and-instance-registry.md](pairing-and-instance-registry.md) §1, §5 | Matches | `machine_id` (26-char base32), machine store `devices.json` read by every instance; the gateway is the single writer. |
| A-N2-2 | same, §1 | Matches, with a request | `machine_key` is Ed25519; devices pin it from the QR. It signs the inner frame (§4). Request (MP-N4 CONTRACT-REQUESTS CR-N4-2): MP-N2-C1 exposes a read-only signing function that instance daemons call, so push-relay never copies the private key. |
| A-N2-3 | same, §2, §4.5, RC-3 | Matches | The device row has an opaque `push_registration`; this contract defines its content as the §7 record (`relay_url`, `handle`, `send_secret`, `enc_keys`, `device_push_secret`, capabilities). Revocation calls the MP-N4 deregistration hook. The device push key is separate from the P-256 device auth key, as N2 requires. |
| A-N2-4 | same, §4.4 | Matches | Instances accept the device bearer token on existing protected routes; MP-N6 adds `/api/v1/device/commands*` that **require** a device token so the recorded actor carries `device_id`. MP-N5 preference writes go through the gateway (single writer of the machine store). |
| A-N7-1 | same, RC-4 | Matches | A direct-push watch is a child device (`parent_device_id`) with its own push key; revoking the phone revokes it. |
| A-E1-1 | [queue-readiness-and-build-progress.md](queue-readiness-and-build-progress.md) §4 | **Resolved by RC-10** | MP-E1-C7 exposes `Aiur.BuildQueue.progress/1` and an internal progress-changed signal; milestone events stay at 25/50/75/100. N5 reads the facts on each signal and computes per-device 10/25/50 thresholds, applying E1's no-burst / no-repeat / no-unknown rules per device step. Topic registration in the MP-R2-C5 catalog per RC-08. |
| A-E4-1 | [conversations-transcripts-anchors.md](conversations-transcripts-anchors.md) | Matches | `anchor_id` = `anc_<sha256(event_ref, conversation_id)>`, with a `method` that may be `none`; absent anchors degrade per §3.1 rule 2. |
| A-E5-1 | [voice-session.md](voice-session.md) | Matches | Phone and watch authenticate voice sessions with the MP-N2 device credential; provider keys stay on the daemon. |
| A-R1-1 | [identity-and-capabilities.md](identity-and-capabilities.md); MP-R1 capability-matrix §2 | Matches | Capability ids `push`, `pairing`, `build_orders.progress`, `build_queue`, `commands.answer`, `voice.stt`, `voice.conversation`. `push` uses only the contract's reason enum: `not_configured`, `disabled`, `not_running`, `dependency_unavailable` (`depends_on` e.g. `["pairing"]`, `["runtime.crypto"]`), `unknown`; `degraded` carries `since`. RC-02: payloads use `instance_id`. |

## 10. Versioning

`v` is on every layer. A device that receives an unknown `v` shows the fallback and asks
the app to update; the daemon never downgrades a payload to fit an old device. Additive
fields are allowed within `v: 1`; unknown fields are ignored.

## 11. Phase C changes (2026-10-06)

| Change | Why |
| --- | --- |
| Detached Ed25519 signature in a binary inner frame; `sig` removed from the JSON; no RFC 8785 | Three platforms would otherwise need byte-identical canonical JSON; signing exact bytes removes that interop risk. |
| Binding moved to HPKE `info` = `aiur-push-v1` ‖ 0 ‖ `device_id` ‖ 0 ‖ `kid`; AAD empty; no `nid` | The receiver cannot know `nid` before decrypting; Tink's public HPKE API exposes only `info` (contextInfo), not AAD. |
| One push key per device install per machine | Lets `kid` identify the machine and `device_id` before decrypting; unpairing one machine deletes only its key. |
| `instance_id` in intent and destination | RC-02. |
| `push:` settings in `~/.aiur/machine` | RC-03. |
| `summary.counts` for `digest` | MP-N5 digests carry counts; the device owns the wording. |
| Relay envelope adds `idempotency_key` and `fallback` | Daemon retries after a timeout must not double-send; the fallback string is owned by the daemon release, not the relay. |
| Erlang `:crypto` evidence | E-C4 resolved for OTP 28 (MP-N4-C1-T01): RFC 9180 A.2.1 and RFC 8032 test 1 reproduced. |
| A-E1-1 resolved | RC-10. |
