---
artifact_contract: ce-unified-plan/v1
artifact_readiness: tickets-written (Phase C, 2026-10-06; see tickets/README.md)
feature_id: MP-N4
bucket: 3 (mobile and watch)
base_main_sha: 45a290e3
date: 2026-10-06
depth: deep
owns_contracts: [notification-destination-and-payload]
consumes_contracts: [command-request-and-resolution (MP-E2), events-and-replay (MP-R2), pairing-and-instance-registry (MP-N2), identity-and-capabilities (MP-R1), conversations-transcripts-anchors (MP-E4), queue-readiness-and-build-progress (MP-E1, via MP-N5)]
design_gate: DESIGN-N4
blockers: [DESIGN-N4, MP-N1 framework decision, MP-N2 pairing contract, Apple/Google publisher accounts (OQ-N4-1), physical-device validation V-* in device-validation-plan.md]
---

# MP-N4 — Private, end-to-end encrypted, rich background notifications

Companion files: [platform-evidence.md](platform-evidence.md) (sources, MP-Q2 resolution),
[chunks.md](chunks.md) (decomposition), [device-validation-plan.md](device-validation-plan.md).
Contract: [notification-destination-and-payload.md](../../contracts/notification-destination-and-payload.md).
Owner gate: [DESIGN-N4](../../owner-design-tasks/DESIGN-N4.md).

---

## 1. Summary

An aiur machine that is never publicly reachable sends **sealed** notifications outbound
to a small **relay service**, which hands them to APNs or FCM. Only a paired device can
open the seal. On iOS a Notification Service Extension decrypts and shows a couple-word
summary ("Migration decision · aiur #2731"); on Android the app decrypts a data message
and posts the notification itself. Tapping opens the app, which fetches the rich context
over the device's private path (MP-N2). Apple, Google and the relay see sizes, timing,
priority and one uniform fallback string, never content or identifiers.

## 2. Problem frame

- Today the operator notices blockers by reading GitHub email. aiur has **no push of any
  kind**: notifications are local sounds (`Aiur.Alerts`, `src/lib/aiur/alerts.ex`; config
  `alerts.*`, `src/lib/aiur/config/schema/alerts.ex:13-25`). Searches for apns, fcm,
  firebase, web push, ntfy, pushover return nothing (baseline N4, §6).
- The only internet-facing piece is the inbound `hooks.aiur.dev` webhook tunnel, which is
  path-scoped and has no outbound or device role (`website/docs-app/apis/github.md:744-760`).
- The dashboard binds to loopback by default and refuses a non-loopback bind without
  credentials (`src/lib/aiur/http_server.ex`, `guard_dashboard_credentials/3`). That
  privacy posture must survive: push cannot be a reason to open a port.

## 3. Requirements (from brief §6 N4, D18, D19, settled §3)

- N4-R1. Timely awareness when a Command needs the human, while the app is backgrounded,
  suspended or terminated (not force-quit; see §7).
- N4-R2. Outbound only. No inbound port, no port forwarding, no public dashboard, no
  mandatory Tailscale or Cloudflare.
- N4-R3. Protected contents (summary, repo, ticket, Command, agent) are decryptable only
  by authorized paired devices. Apple/Google/relay visibility is stated exactly (contract §1).
- N4-R4. A concise couple-word summary is visible on the lock screen while protected data
  stays encrypted in transit; richer context is fetched privately on open.
- N4-R5. Honest constraints: no promise of an always-awake app, guaranteed immediate
  delivery, or background fetch on push. Physical-device validation before "done".
- N4-R6. Works with only the relevant components installed: requires `pairing`,
  `commands` and the event bus; `build_orders` is optional (capability-matrix row `push`).
- N4-R7. Revocation: unpairing a device (D19, MP-N2) stops all pushes to it within one send.

## 4. Repository findings (extends baseline N4; verified at `45a290e3`)

| Finding | Evidence | Consequence |
| --- | --- | --- |
| Commands persist before they notify: fsynced `decisions.ndjson`, then projection, then Exchange and PubSub | `src/lib/aiur/decision_store.ex` (moduledoc and `request/2` at :154); baseline E2 | push-relay subscribes after persistence; a push never precedes durable state |
| `decision.requested/acknowledged/resolved` can only be published through the durable path | `src/lib/aiur/events/publisher.ex:57,191` | N5 listens to these durable topics for Command transitions |
| `DecisionAttention` re-asks every 15 min | `src/lib/aiur/decision_attention.ex:17,217-267` | re-asks must **not** become re-pushes; N5 dedup keys exclude re-ask ticks |
| Global durable event ids that survive restart | `src/lib/aiur/events/id_generator.ex:83,106` | push outbox and N5 cursor key on event id |
| `Decision` carries `context.short_summary`, `options`, `recommendation`, `urgency`, `blocking`, `authority` | `src/lib/aiur/decision.ex:20-40,124-135` | summary title source; `blocking` drives `urgency: high` |
| Build-order progress is an integer percent with a resolution quality | `src/lib/aiur/build_order/root_summary.ex:6,21-23` (`:resolved \| :partial \| :unresolved \| :unknown`) | N5 notifies milestones only for `:resolved` progress |
| PR merges already reach the Executor binding set | `src/lib/aiur/executor_bindings.ex:25` (`ticket.*.pr.merged`) | opt-in `pr.merged` source exists |
| Runtime state and decision state directories exist | `src/lib/aiur/config/paths.ex:61,243` | push outbox lives under `runtime_state_dir` per instance |
| No advertised URL concept; default `server.port: 0` | baseline R3; `http_server.ex:143` `base_url/0` | context fetch depends on MP-N2's stable reachability, not on N4 |
| Instance key = first 10 hex of sha256(project root) | `packaging/npm/aiur-cli/libexec/aiur-engine.sh` `aiur_instance_key()` (baseline N2) | `destination.instance_id` = `<machine_id>/<instance_key>` (RC-02) |
| MP-R1 already names the components | `bucket-1-refactor/MP-R1/component-map.md:126` (`push-relay`: optional package; "relay service is separate"), `capability-matrix.md:65,87` | N4 adopts these names |
| Khala cannot carry push today | Khala @ `d898e6b8`: README "research, not an implemented service"; `docs/product/decisions.md:7`; no push code | MP-Q2 resolution, platform-evidence.md |

## 5. Proposed boundaries

| Component | Kind | Public interface | Required deps | Optional deps | Prior refs |
| --- | --- | --- | --- | --- | --- |
| `push-crypto` (in `aiur-contracts`, mirrored in Swift/Kotlin) | library | `seal(payload, device_key) -> sealed`, `open(...)`, canonical JSON, signature, golden vectors | none | — | new |
| `push-relay` (daemon) | optional package, supervised child | `PushRelay.enqueue(intent)`; reads device registry; reports capability `push` with states `available \| unavailable(reason) \| degraded(reason)` | identity (machine key), pairing-discovery (device registry), event-bus, commands | build-orders (progress kinds via N5) | Prior-boundaries: new #41 candidate beside `EXE`/`DEC` (feature-boundaries §F); Prior-units: none (post-refactor) |
| `notification-policy` (MP-N5) | module inside push-relay package | `Policy.evaluate(event) -> [intent]` | push-relay | build-orders | — |
| **relay service** | separate deployable (`services/push-relay-service`, proposed path) | `POST /v1/handles`, `DELETE /v1/handles/:h`, `POST /v1/send` (contract §7–8) | APNs `.p8` key, FCM service account | Cloudflare Workers adapter | new; MP-R4 provider boundary |
| iOS NSE + app keychain group | native (Swift) target inside the MP-N1 app | none (system-invoked) | CryptoKit (iOS 17+) | — | MP-N1 |
| Android messaging service | native (Kotlin) inside the MP-N1 app | none | Tink, Firebase Messaging | — | MP-N1 |

Independence: the daemon never links the relay service; it speaks HTTPS to a configured
URL. The relay service never links aiur code beyond `push-crypto` constants (it does not
even need those; it forwards opaque bytes). The mobile app does not need the dashboard
(`dashboard-ui`) for notifications or Command answers (capability-matrix "Phone" row).

### Configuration (new keys; docs ship with the change per `AGENTS.md`)

Machine-level, in **`~/.aiur/machine`** under `push:` (RC-03; pairing contract §8). The
Phase B draft put them in `~/.aiur/config`, which is the fallback *workflow* config
(`workflow.ex:84-93`) — superseded.

| Key | Default | Meaning |
| --- | --- | --- |
| `push.enabled` | `false` | master switch; `aiur init`/setup can offer it (MP-N2 setup flow) |
| `push.send_timeout_ms` | `5000` | per relay request |
| `push.outbox.max_age_seconds` | `86400` | outbox entries older than this are coalesced or dropped (N5 rules) |
| `push.allow_loopback_relay` | `false` | allow `http://127.0.0.1`/`localhost` relay URLs (tests, self-hosting development) |

The relay URL is not a machine setting: each device registers with a relay and the
registration carries `relay_url` (contract §7). No secrets in config: `send_secret`,
`device_push_secret` and device public keys live in the device row's opaque
`push_registration` in the MP-N2 machine store (`devices.json`, 0600, written only by the
MP-N2 gateway; pairing contract §5). Each instance daemon reads it and sends its own
instance's notifications; the gateway calls push-relay's deregistration function on
revoke and unpair-all (pairing contract §4.5, RC-3). Ticket: MP-N4-C3-T01.

## 6. Key technical decisions

- **KD-N4-1 Sealed payload, not "empty push then fetch".** The app cannot be relied on to
  fetch in the background (E-A5 background pushes are throttled; E-F5 short window; the
  phone may not be on the tailnet). Sealing a ≤ 2.4 KB summary gives a useful lock-screen
  line with zero network. Rich context is fetched only on open.
- **KD-N4-2 HPKE (RFC 9180) X25519/HKDF-SHA256/ChaCha20-Poly1305 + Ed25519 inner
  signature.** Standard, available natively on both platforms (E-C1, E-C2) and on the
  pinned OTP 28 `:crypto` (E-C4, verified in Phase C), no custom crypto. The signature
  authenticates the machine because base-mode HPKE does not. Phase C refinements
  (contract §11): detached signature over exact bytes in a binary frame (no JSON
  canonicalization); device and key bound through HPKE `info` with empty AAD, because
  Tink's public HPKE API exposes only `info` (E-C5); one push key per device per machine.
- **KD-N4-3 Per-device sealing and fan-out.** One push per device; no shared group key.
  Revoking one device needs no re-keying of others. Cost: N sends per event, fine at
  personal scale (a handful of devices).
- **KD-N4-4 Uniform clear fallback.** Same title/body for every kind, so a failed decrypt
  leaks nothing about kind or count (E-A3). Category, thread and interruption level are
  set on-device after decryption.
- **KD-N4-5 Alert pushes only (`apns-push-type: alert`, FCM data high/normal).** No
  reliance on background pushes for anything user-visible. Retractions are best effort
  (§7.4).
- **KD-N4-6 No network in the NSE in v1.** Keeps the 30 s budget for decrypt + verify,
  avoids leaking timing to the machine from a locked device, and avoids the tailnet-down
  failure inside the extension.
- **KD-N4-7 Relay is a thin opaque forwarder with no user accounts.** Handles are bearer
  capabilities created by the device. The relay stores `handle → {platform, push_token,
  topic, env, sha256(send_secret), created_at, last_used}` and nothing else.
- **KD-N4-8 Minimum OS: iOS 17 / watchOS 10 (CryptoKit HPKE).** Android minimum is
  MP-N1's; Tink HPKE has no OS floor of its own beyond Tink's.

## 7. Non-happy paths

### 7.1 Capability absence

- `push.enabled: false` → capability `push: unavailable(disabled)`; invalid settings →
  `unavailable(not_configured)` (closed reason enum, identity contract §2.2; MP-N4-C3-T04
  is the normative table). App settings show "Notifications are off on <machine>" with the setup path (DESIGN-N4).
- No paired device → nothing is sent; intents are not retained (no backlog to burst later).
- `build_orders` absent → progress kinds never generated (N5); Commands still notify.
- Relay unreachable → `push: degraded(not_running, since)` (the enum has no
  relay-specific reason; the human-readable "relay unreachable" line is `aiur push status`,
  MP-N4-C3-T07); outbox retries with
  exponential backoff (1 s → 5 min cap); N5 staleness rules apply on recovery (no burst).

### 7.2 Device and key state

| State | iOS | Android | User sees |
| --- | --- | --- | --- |
| Locked, after first unlock | NSE reads `AfterFirstUnlock` key, decrypts | messaging service decrypts with credential-encrypted keyset | real summary (privacy of lock-screen preview is the OS setting) |
| Restarted, never unlocked | key unavailable → fallback text (E-A3, E-B3) | messaging service is not direct-boot-aware (E-F9, RQ-N4-4 settled), so FCM messages are handled after first unlock and decrypt normally; V-A3 records the observed timing | iOS: "aiur · New notification"; real content after unlock + open. Android: the real summary after first unlock |
| NSE timeout/crash | original alert = fallback | n/a | fallback |
| App force-quit (iOS app switcher) / swiped from recents or Settings → Force stop (Android) | alert pushes with NSE still display — **UNVERIFIED**, V-I4 (record) | swiped from recents: delivery expected (V-A2b, required on Pixel, record on Samsung); Settings → Force stop: **no delivery** until reopened (E-F7, V-A4) | Android settings screen warns when the app detects it was force-stopped (DESIGN-N4) |
| Notifications permission denied | APNs token still issued, nothing displays | `POST_NOTIFICATIONS` denied (E-F8) | app reports `permission_denied` to the machine so the dashboard can show "phone notifications blocked" |
| Unknown `kid` / bad signature / expired / seen `nid` **on a readable keyset** (remote cause, possibly an attack) | NSE returns empty content if filtering entitlement granted (E-A7, OQ-N4-3), else a neutral "Notification could not be verified" | not posted (silent drop) | — |
| **Local key loss** (Android Keystore master key invalidated, keyset unreadable; iOS keychain read error other than `errSecInteractionNotAllowed`) — Phase D M6 | uniform fallback shown (`Fallback(KEYS_UNAVAILABLE)`, MP-N4-C4-T02) | uniform fallback **posted** (`Fallback(KEYS_UNAVAILABLE)`, MP-N4-C5-T02); in-app open shows "Open aiur to re-pair" | fallback, never nothing; the device reports `push_health: keys_lost` (contract §7) on its next online call and the dashboard / `aiur push status` show "phone notifications broken" (MP-N4-C3-T07) |

A local cause and a remote cause are never collapsed (AGENTS.md "a collapsed cause names
the collapse at the source"): silent drop is reserved for verification failures on a
keyset the device *could* read.

### 7.3 Delivery timing and staleness

- APNs stores one notification per app per device while offline (E-A4); FCM stores up to
  100 then drops all (E-F2). Neither is a queue; the app always reconciles with the
  machine on open ("3 Commands need you").
- **Accepted but never displayed (Phase D M3).** APNs and FCM are best effort and return
  no display receipt; the NSE makes no network call (KD-N4-6). A lost `human_required`
  push is therefore a *delivery-reliability* risk, not a noise question. Recovery
  (proposed; owner choice in DESIGN-N5 OQ-N5-2): **one** bounded reminder for a
  `blocking` Command still `with_human` after N minutes (proposed default 30), sent as
  `command.needs_you` with `attempt: 2`, the same `stream` and `collapse_token` (it
  replaces, never stacks), the next `seq`, and dedup key `cmd:<command_id>:reminder`
  (contract §3, §6). Every Command payload carries `summary.badge` (open blocking
  Commands needing the human on that instance), so the app icon badge recovers the count
  even when a banner was lost. Policy owner: MP-N5-C2-T01; device row V-R5. If the owner
  refuses reminders, AC-N4-1 records that the only recovery is opening the app.
- Every payload carries `expires_at`; Commands: 24 h or the Command's own expiry if
  shorter; progress: 2 h; `pr.merged`: 6 h. Devices discard expired payloads silently.
- Ordering is not guaranteed (E-A2 "may reorder"); `stream`/`seq` makes the device show
  only the newest per stream.

### 7.4 Resolution elsewhere (retraction)

When a Command resolves (answered on dashboard, another device, the Executor, moot),
N5 emits `command.resolved` with `retracts: [nid]`, normal priority, same
`collapse_token` as the original. Effects: (a) if the original is still in APNs/FCM
storage it is replaced; (b) the NSE/Android service removes the delivered notification
when it runs; (c) on iOS, whether an NSE may suppress its own banner needs the filtering
entitlement (E-A7) — without it the retraction displays as a quiet passive "Answered on
<surface>" line. Owner decides presentation (DESIGN-N4 D-4). The app re-checks state on
open regardless, so a missed retraction degrades to "Already resolved" (MP-N6).

### 7.5 Multiple machines and devices

- Each machine has its own handle per device, so unpairing one machine deletes only that
  handle. The relay can still link them through the shared push token (stated in contract §1).
- Several instances on one machine share the device registry; each instance daemon sends
  only its own instance's intents. Cross-instance coalescing is out of scope (no combined
  inbox, brief §3).
- Phone + watch: by default iOS forwards the phone's notification to the watch (E-B1).
  Direct-to-watch push is an MP-N7 option; the system de-duplicates only for the same app
  pair (E-B2).

### 7.6 Security and privacy

- Threats covered: passive relay/provider (content sealed), malicious relay (forgery →
  signature fails; replay → `nid`/expiry; drop/delay → not preventable, detected by the
  app's reconciliation on open), stolen `send_secret` (attacker can send *sealed* noise
  to a handle but cannot forge content; rate-limited; rotate by re-registering), lost
  phone (remote unpair-all, D19; keys are `ThisDeviceOnly`).
- Not covered and stated: traffic analysis of timing/size; the relay operator learning
  how many machines a device is paired with. Clear metadata, listed in contract §1
  (Phase D security m2): `k` (`kid`, stable per device and machine) in the provider
  payload; the FCM `collapse_key` `a`/`b`, which tells Google "Command or not"; the
  `push_class` and priority, which together tell the relay and Apple/Google when a
  blocking Command occurs; and the device IP that the relay sees at `POST`/`DELETE
  /v1/handles`.
- **Fallback is pinned at the relay (Phase D security m1).** The relay pins the uniform
  fallback per `app_topic` (env `AIUR_RELAY_FALLBACK_<APP_TOPIC_SLUG>`, JSON
  `{title, body}`) and refuses an envelope whose `fallback` differs (`422
  fallback_mismatch`); it never places any other clear alert text (MP-N4-C2-T01/T02).
  A relay operator or a holder of the APNs key can still show the fallback or any clear
  alert when the NSE does not run; signed content is the only authentic content.
- **Lock screen (Phase D security m9).** Decrypted summaries appear on the lock screen and
  on a forwarded watch. Proposed default (owner choice, DESIGN-N4): **hide the body when
  locked** — iOS `hiddenPreviewsBodyPlaceholder` on the categories (MP-N4-C4-T03),
  Android `VISIBILITY_PRIVATE` with a public version that carries the uniform fallback
  text (MP-N4-C5-T03). The title follows the OS preview setting.
- Logging: push-relay logs `intent_id`, `device_id`, outcome; never summary text. The
  relay never logs bodies. A test asserts no summary text in daemon logs (C3).

## 8. Alternatives considered

| Alternative | Why not (now) |
| --- | --- |
| Empty "tickle" push + background fetch over tailnet | Background pushes throttled and not guaranteed (E-A5); phone may be off-tailnet; no lock-screen summary when fetch fails. Kept as the *open* path, not the *notify* path. |
| Plaintext summary in APNs alert + encrypted details | Leaks the couple-word summary (often a repo or ticket topic) to Apple/Google; violates N4-R3. |
| Khala homeserver + Sygnal | Not built (platform-evidence); hidden mandatory dependency on a hosted product. |
| Extend the `hooks.aiur.dev` tunnel | Inbound-only by design; widening exposes the dashboard (`github.md:760`). |
| Shared group key for all devices | Revocation forces re-keying everyone; per-device sealing is simpler at this scale. |
| Web Push (RFC 8030/8291) to a PWA | No PWA/service worker exists (baseline N1); iOS Web Push requires a home-screen web app and gives no watch path; native NSE is needed for the watch story anyway. Re-evaluate only if MP-N1 picks a PWA. |
| Encrypted response mailbox on the relay (answers from off-network phones) | Valuable when the phone cannot reach the machine, but it makes the relay store user responses and adds a polling loop in every daemon. Deferred: OQ-N4-2. |

## 9. Acceptance criteria

1. AC-N4-1 With the app backgrounded and the phone locked (after first unlock), a
   `human_required` blocking Command produces a lock-screen notification whose title is
   the Command short label and whose subtitle names the instance, on iOS and Android
   physical devices (V-I1, V-A1). If that push is accepted but never displayed, exactly
   one reminder follows while the Command stays `with_human` (§7.3, V-R5) — unless the
   owner refuses reminders in DESIGN-N5 OQ-N5-2, in which case this criterion records
   that the only recovery is the app badge and opening the app.
2. AC-N4-2 A packet capture at the relay and the APNs/FCM request bodies contain no
   repo name, ticket number, Command id, machine id or summary text (C2/C3 tests +
   V-P1). The only clear strings are the uniform fallback.
3. AC-N4-3 With the device restarted and not unlocked, the notification shows the
   uniform fallback; after unlock and tap, the app shows the real Command (V-I3).
4. AC-N4-4 A payload re-signed by a different key, replayed with a seen `nid`, or past
   `expires_at` is not shown as real content (unit tests on both platforms + V-S1).
5. AC-N4-5 Unpairing a device makes the next send to it return no provider request
   (relay handle deleted; daemon registry entry gone) — integration test C3.
6. AC-N4-6 With no inbound route to the machine (no tunnel, no port forward, dashboard
   on loopback), AC-N4-1 still passes; context loads once the phone is on a path MP-N2
   considers reachable, otherwise the app shows "Can't reach <machine>" with the sealed
   summary.
7. AC-N4-7 Relay down for 2 h, then back: no more than one notification per stream plus
   at most one digest per instance is delivered (N5 rules; V-R2).
8. AC-N4-8 Capability report shows `push` as `unavailable(disabled | not_configured |
   dependency_unavailable)`, `degraded(not_running | unknown)` or `available`, never
   silently missing (C3-T04 table).
9. AC-N4-9 Every V-* item in device-validation-plan.md has a recorded result, including
   the UNVERIFIED items E-B6, E-F7, E-F9, E-W1 resolved one way or the other.

## 10. UX requirements → DESIGN-N4

Notification presentation (lock screen, banner, notification centre grouping, watch
short/long look, fallback copy, retraction appearance, permission and setup states).
See [DESIGN-N4](../../owner-design-tasks/DESIGN-N4.md). Implementation of every
user-visible ticket is blocked on it; C1–C3 (crypto, relay, daemon client) may proceed.

## 11. Open questions

**Owner (Kevin):**
- OQ-N4-1 Who publishes the store apps and operates the default relay service (aiur-team
  org Apple Developer + Firebase accounts, and a host such as a container or Cloudflare
  Worker)? Without it, only self-built apps can receive pushes. Paid accounts are needed.
- OQ-N4-2 Should a later chunk add an encrypted response mailbox so a phone off the
  private network can still answer? (Changes the relay from forwarder to store.)
- OQ-N4-3 Apply for the NSE filtering entitlement (cleaner retraction and silent drop of
  unverifiable payloads)? Apple approval is not guaranteed.
- OQ-N4-4 Fallback copy and whether blocking Commands use Time Sensitive interruption
  (DESIGN-N4 D-1, D-3).

**Research (Phase C, evidence-resolvable):**
- RQ-N4-1 **Resolved (Phase C):** OTP 28 `:crypto` provides X25519, Ed25519,
  ChaCha20-Poly1305 and HMAC-SHA256; RFC 9180 A.2.1 reproduced (E-C4). C1-T01 adds the
  runtime guard.
- RQ-N4-2 Watch shows NSE-decrypted content for forwarded notifications? (E-B6) — V-W1.
- RQ-N4-3 iOS alert+NSE delivery after force-quit — V-I4.
- RQ-N4-4 **Settled (Phase D, documentation):** Firebase documents Direct Boot receipt
  (it needs `firebase-messaging-directboot`, `android:directBootAware="true"` and Play
  services 19.0.54+, and the service must not touch credential-encrypted storage). Our
  keys live in CE storage, so the messaging service is **not** marked direct-boot-aware;
  messages are handled after first unlock (E-F9). V-A3 stays a record row.
- RQ-N4-5 Can an iOS NSE remove other delivered notifications
  (`removeDeliveredNotifications`) — V-I6.
- RQ-N4-6 UnifiedPush provider for de-Googled Android: demand and relay adapter shape.
- RQ-N4-7 Relay hosting cost and rate limits for the default deployment (measured, not
  estimated, per `AGENTS.md` savings rule if claimed). Blocks C2-T06.
- RQ-N4-8 (new) Can a Cloudflare Worker send to APNs (HTTP/2) and sign ES256 within
  limits? Blocks only the optional C2-T07.
- RQ-N4-9 (new) How the Android app detects it was force-stopped (candidate:
  `ApplicationExitInfo` reasons, API 30+); re-read E-F7 against the FCM troubleshooting
  page and the Android "stopped state" documentation. C5-T03's warning branch stays
  blocked until a dated developer.android.com page is cited.

## 12. Plan refresh after the refactor (MP-R1..R7)

N4 lands in wave 5, after the refactor. Paths in this plan are **pre-refactor**. After
MP-R1/R2 land, refresh: (a) `Aiur.Events.*` module paths → the `event-bus` package;
(b) the durable decision topics → the `commands` package (`aiur_decisions`, boundary 27
`DEC`); (c) `Config.Paths` → `aiur_config`; (d) the capability registry API from
`contracts/identity-and-capabilities.md`. Contract field names do not change. Ticket
MP-N4-C3-T00 is the refresh task.

## 13. Phase C ticket map

[tickets/README.md](tickets/README.md) lists 34 tickets. Relay *code* (C2-T01..T05),
crypto (C1) and the daemon component (C3-T00..T06) are specified to implementation depth
and are not blocked by OQ-N4-1; only the default relay deployment (C2-T06), the optional
Workers port (C2-T07) and the device run (C7-T02) wait for the publisher/operator answer.
