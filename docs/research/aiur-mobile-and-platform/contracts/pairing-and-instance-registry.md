---
contract_id: MP-CT-pairing-and-instance-registry
owner_feature: MP-N2 (pairing, device credentials, machine registry); MP-N3 (per-instance summary payload, §7)
status: reconciled (Phase C, 2026-10-06): RC-01, RC-02, RC-03, RC-15 applied
base_main_sha: 45a290e3
date: 2026-10-06
consumers: MP-N1, MP-N3, MP-N4, MP-N5, MP-N6, MP-N7, MP-E3, MP-R1, MP-R3
---

# Contract: pairing, device credentials and the machine instance registry

This contract says how a phone (or watch) becomes an **authorized device** of a
**machine**, how it proves that on every request, how that authority ends, and
how it finds the aiur **instances** on that machine and reads a short summary of
each. It is the single place these rules live; feature plans reference it.

Settled inputs (do not reopen): D19 (pairing grants full access to every
instance on the paired machine, revocable per device, remote unpair-all is
first-class), brief §3 (private access; Tailscale optional; Cloudflare not
mandatory), brief §6 N2 (machine-level durable pairing, optional at setup,
enable later, QR on a settings page at any time, authorization separate from
reachability).

Words: **machine** = one OS user account on one host running aiur (the launcher
keys every instance by `$USER`, `aiur-engine.sh:294`). **Instance** = one aiur
daemon for one project root (`aiur_instance_key`, `aiur-engine.sh:269-278`).
**Gateway** = the new machine-level process this contract introduces (MP-N2).
**Device** = one installed app on one phone or watch.

## 1. Identity

| Identifier | Definition | Stability | Owner |
| --- | --- | --- | --- |
| `machine_id` | 128-bit random value, base32 (26 chars). **Created by MP-R1 at first daemon boot** in `~/.config/aiur/machine/identity.json` (RC-01; `identity-and-capabilities.md` §1.1). MP-N2 only reads it and never creates a second identity. | Survives restarts, hostname changes and IP changes. A new value only through the MP-R1 identity reset path (invoked by `aiur mobile reset`); every device must then re-pair. | MP-R1 (identity); MP-N2 consumes |
| `machine_label` | Display name, stored in `identity.json` (MP-R1). Default: short hostname. Never used as a key. | Mutable. | MP-R1 field; MP-N2 shows it |
| `machine_key` | Ed25519 key pair, software, created by `aiur mobile enable` as `machine_key` (private, 0600) and `machine_key.pub` in the machine store. Signs QR payloads and registry responses. | Until `aiur mobile reset`. | MP-N2 |
| `instance_key` | Today's launcher key: first 10 hex chars of sha256(realpath(project root)) (`aiur-engine.sh:269-278`). | Changes if the project root moves. Two clones of one repo are two instances. | MP-R1 (assumed unchanged) |
| `instance_id` | `<machine_id>/<instance_key>` (RC-02). The only key a client stores for an instance. The former name `instance_ref` is retired. | As `instance_key`. | MP-R1 (identity contract §1.2) |
| `device_id` | 128-bit random, base32, made by the gateway at pairing. | Until revoked. Re-pairing the same phone makes a new `device_id`. | MP-N2 |
| `repository` | `{tracker, owner, name}` for GitHub (`Aiur.GitHub.Config.repo/0`, `src/lib/aiur/github/config.ex:24-30`), or `{linear, project_slug}`. Display only; not unique per machine. | Config-derived. | MP-R1 identity contract (assumed) |

Collision rule: two instances with the same `repository` on one machine are
shown separately and disambiguated by the project-root basename. The full
project path is never sent to a device (it is local filesystem detail; the
basename is enough).

## 2. Device credentials and key separation

Each device holds three independent secrets. None is derived from another.

| Key | Where it lives | Purpose | Owner |
| --- | --- | --- | --- |
| **Device auth key** (P-256, signing only) | Made on the device in hardware: iOS Secure Enclave, Android Keystore (TEE or StrongBox). Non-exportable. | Proves the device in the token exchange (§4). | MP-N2 |
| **Device push key** (P-256 ECDH or the scheme MP-N4 picks) | Made on the device; may need to be readable by a notification extension, so its storage class is MP-N4's decision. | Decrypts protected push payloads. | **MP-N4** (N2 only carries the public half and the registration) |
| **Access token** (opaque, 256-bit) | Device memory and keychain; machine store holds only sha256(token). | Bearer for gateway and instance requests. TTL 15 min. | MP-N2 |

Evidence for the hardware choice (accessed 2026-10-06):

- Secure Enclave "works only with NIST P-256 elliptic curve keys … for creating and
  verifying cryptographic signatures, or for elliptic curve Diffie-Hellman key
  exchange", and keys cannot be moved in or out
  (<https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave>).
  Ed25519 therefore cannot be the device key.
- Android Keystore keys bound to secure hardware are "never exposed outside of
  secure hardware"; StrongBox supports "ECDSA, ECDH P-256"
  (<https://developer.android.com/privacy-and-security/keystore>).

Separation rules:

1. Pairing secrets, device keys and access tokens are never written to `.aiur/config`,
   `~/.aiur/.env`, the instance records or any log. Logs carry `device_id` only.
2. A device never receives `AIUR_DASHBOARD_PASSWORD`, `AIUR_SUPERVISOR_TOKEN`,
   `GITHUB_TOKEN`, provider keys or the Erlang cookie. The device path is a new,
   separate credential; the existing ones keep their current meaning
   (`AiurWeb.FinancialDataAccess`, `src/lib/aiur_web/financial_data_access.ex:50-84`;
   `AiurWeb.SupervisorAuth`, `src/lib/aiur_web/supervisor_auth.ex:28-82`).
3. Revoking a device ends its access tokens and its push registration. Revocation
   cannot recall plaintext the device already received (the same honesty rule as
   Khala KHA-128 R4, `khala:docs/plans/2026-09-16-kha-128-device-agent-revocation.md`).

## 3. Pairing QR payload

The QR is shown by `aiur mobile qr` (terminal), by the gateway's local settings
page, and by any instance dashboard settings page that can reach the gateway
(DESIGN-N2 decides which of these ship). The QR is a URI:

```text
aiur-pair:v1?m=<machine_id>&n=<url-encoded machine_label>
  &e=<endpoint 1>&e=<endpoint 2>…        # gateway base URLs, most preferred first
  &k=<base64url machine_key public, 32 bytes>
  &s=<base64url pairing secret, 32 bytes>
  &x=<expiry, unix seconds>
  &t=<base64url sha256(SPKI) of the TLS certificate>   # only under RQ-TRANSPORT option T-B
  &sig=<base64url Ed25519 signature by machine_key over all fields above>
```

Rules:

- **Pairing secret:** single use, expires 10 minutes after display (configurable,
  §8), and at most 3 are outstanding; showing a new QR invalidates the oldest. Only
  sha256(secret) is stored.
- **Endpoints** list what the operator configured or what the gateway bound
  (§6). A loopback endpoint is never included. If none is reachable from off the
  machine, `aiur mobile qr` refuses and says which setting to change (MP-R3 owns
  the wording of reachability errors).
- **No instance list** in the QR. Discovery happens after pairing (§6).
- The device pins `k` for this `machine_id`. Every later registry response is
  signed by the pinned key; a mismatch is a hard error ("this is not the machine
  you paired"), never a silent re-pin.
- A QR whose `machine_id` the device already knows is a **re-link**, not a new
  pairing: the device updates endpoints and label and does not create a second
  device entry (§4.3).

## 4. Protocol

All paths are on the gateway unless marked. JSON bodies. Every response carries
`contract: "aiur.machine/v1"`.

### 4.0 Bytes that are signed (settled in Phase C)

- **Canonical JSON:** every `secret_proof` and every `sig` is computed over the RFC 8785
  JSON Canonicalization Scheme serialization (<https://www.rfc-editor.org/rfc/rfc8785>,
  accessed 2026-10-06) of the body **without** the `secret_proof` / `sig` member.
- **Machine signatures** (`sig`, QR `sig`): Ed25519 (RFC 8032) over those bytes; for the QR,
  over the URI query string with `sig` removed, parameters in the order shown in §3.
- **Device signatures** (§4.2): ECDSA P-256 with SHA-256, DER-encoded, base64url, over the
  ASCII bytes `nonce "." device_id "." machine_id`.
- **Encoding:** base64url without padding everywhere.
- Every signed response covers `contract`, `machine_id` and `observed_at`.
- The test vectors in MP-N2-C4-T03 (response signatures) and MP-N2-C5-T05 (pairing and
  token) are generated from these rules; the native cores
  (MP-N1-C2-T03) and the gateway must agree with them byte for byte.

### 4.1 Claim (first pairing)

```text
POST /v1/pair/claim
{ "machine_id", "secret_proof": HMAC-SHA256(secret, canonical(body without proof)),
  "device": { "auth_public_key": <P-256 SPKI b64url>, "platform": "ios|android|watchos|wearos",
              "label": "Kevin's iPhone", "app_version": "…",
              "parent_device_id": null | <device_id> },
  "push": null | { opaque MP-N4 registration } }
→ 201 { "device_id", "machine": {machine_id, machine_label, endpoints[]},
        "registered_at", "sig" }
```

Errors: `pair_secret_expired`, `pair_secret_used`, `pair_secret_unknown`,
`pairing_disabled` (mobile turned off), `device_limit` (default 20 devices). Five
wrong proofs in a minute lock claiming for 5 minutes, record a `claim_lockout`
journal entry and show it in `aiur mobile status` (the lean gateway has no alert ledger,
`src/lib/aiur/alerts.ex:9-13,103-106`; CR-N2-2). Pairing bodies contain no non-integer
numbers; a body with one is rejected `invalid_body` (CR-N2-7, avoids RFC 8785 float formatting).

The secret is never sent; only an HMAC over the body is, so a passive observer of
one request cannot claim with it. Confidentiality of later traffic is a transport
property (§6.2), not a pairing property.

### 4.2 Token exchange

```text
POST /v1/token/challenge  { "device_id" }                 → { "nonce", "expires_at" (60 s) }
   # a nonce is consumed by the first /v1/token attempt, success or failure; ≤ 4 live nonces per device (CR-N2-5)
POST /v1/token            { "device_id", "nonce", "signature": ECDSA-P256(nonce.device_id.machine_id, §4.0) }
→ { "access_token", "expires_at" (15 min), "machine_id", "sig" }
```

The device refreshes before expiry. A revoked or unknown `device_id` gets
`401 device_revoked`, and the app shows the "removed from this machine" state
(DESIGN-N2) and stops retrying.

### 4.3 Re-link and endpoint refresh

`GET /v1/machine` (token) returns the current `machine_label` and endpoint list,
signed. Under RQ-TRANSPORT option T-B it also returns `tls_spki_sha256` (and
`tls_spki_sha256_next` during a key rotation); a device accepts a new pin only from a
response signed by the pinned `machine_key` (MP-N2-C10-T04). The device replaces its stored endpoints on every success. If every stored
endpoint fails, the app offers "scan the QR again"; scanning a QR with a known
`machine_id` while the device still has a valid `device_id` calls
`POST /v1/pair/relink` with body `{machine_id, device_id, secret_proof}` (proof per §4.0
over that body), and refreshes endpoints without a new device entry. Relink never changes
the device auth key; a lost key means revoke and pair again (CR-N2-6).

### 4.4 Using the token on an instance

Instances accept the gateway-minted token directly:

- **JSON:** `Authorization: Bearer <access_token>` on any route the
  `:dashboard_auth` pipeline protects today (`src/lib/aiur_web/router.ex:111-199`).
- **WebView:** native code calls `POST /api/v1/device-session` (instance) with the bearer
  and receives a single-use, short-lived `/device-session/<code>` URL; the WebView loads it,
  and the instance sets the signed dashboard session with a **device-kind** session marker
  (`{kind: "device", device_id}`), checked on every LiveView mount against the machine store.
  It does not reuse today's proof marker, which is derived from the Basic-Auth pair
  (`src/lib/aiur_web/financial_data_access.ex:82-93`; `proof.ex:18-38,79-124`). Details:
  MP-N2-C6-T02. The
  session secret is regenerated at every boot (`src/lib/aiur/http_server.ex:268-270`),
  so after an instance restart the app silently repeats this exchange.
- **Cookie scope.** Cookies do not isolate by port (RFC 6265 §8.5,
  <https://www.rfc-editor.org/rfc/rfc6265#section-8.5>), so every instance on one host
  would share today's single `_aiur_key` cookie (`src/lib/aiur_web/endpoint.ex:8-12`).
  When device auth is enabled, each instance names its session cookie
  `_aiur_key_<instance_key>` (MP-N2-C6), so WebViews for two instances on one machine do
  not overwrite each other's session.

An instance checks a token by reading the machine store (§5) and caching by file
mtime; a revoked device fails on the next request after the store changes.
Device auth adds a way to authenticate; it does not widen authority:
`observability.dashboard_writable`, `:api_write` and `:require_writable`
(`router.ex:50-62`) still apply, with one adjustment: a request authenticated by a device
bearer skips the `:api_write` Origin check (a bearer is not an ambient browser credential)
but still needs `X-Aiur-Request: 1` and `:require_writable` (CR-N2-8, MP-N2-C6-T03).
"Full access" (D19) means the same authority a Basic-Auth operator has on that instance, no more.

When mobile is disabled, or no machine store exists, instances reject device
tokens with `401 device_auth_disabled`, and Basic Auth behaviour is unchanged.

### 4.5 Device management, revocation and unpair-all

| Call | Who | Effect |
| --- | --- | --- |
| `GET /v1/devices` | token | List devices: id, label, platform, paired_at, last_seen_at, parent. |
| `DELETE /v1/devices/<id>` | token, or CLI `aiur mobile revoke <id>` | Delete the device row and its token hashes; children (watches paired through it) go too. Calls the MP-N4 deregistration hook (best effort, retried). |
| `POST /v1/devices/unpair-all` | token plus `{"confirm": machine_label}`, or CLI `aiur mobile unpair-all` | Delete every device, every outstanding pairing secret and every token in one atomic store write; record an `unpair_all` journal entry; call MP-N4 for each device. The calling device is included. |
| `POST /v1/devices/<id>/rename` | token | Change the label. |

"Remote" unpair-all means from any paired device, so a lost phone is cut off
from another device. The result reports **control revocation** (rows deleted,
tokens dead: synchronous) separately from **push deregistration** (relay or
provider side: may be pending), following the Khala KHA-128 rule. A device that is
offline when revoked learns on its next request (`401 device_revoked`) and wipes its
stored tokens, endpoints and cached summaries for that machine.

Expiry: access tokens 15 min; pairing secrets 10 min; device rows **do not
expire** by default (durable pairing). An optional idle expiry is owner question
OQ-N2-3.

## 5. Machine store (on disk)

Directory: `${XDG_CONFIG_HOME:-~/.config}/aiur/machine/`, next to the existing
launcher state (`AIUR_BG_STATE_DIR`, `aiur-engine.sh:280-286`), mode 0700, files
0600, owned by `$USER` (the same ownership check the cookie gets,
`aiur-engine.sh:321-347`).

| File | Content |
| --- | --- |
| `identity.json` | **Owned and written by MP-R1** at first daemon boot (RC-01): machine_id, machine_label, created_at. MP-N2 reads it and never writes it. If it is absent or corrupt, every MP-N2 command fails closed with `identity_unavailable` and tells the operator to start any aiur instance once (or run the MP-R1 identity repair); MP-N2 never regenerates it. |
| `machine_key`, `machine_key.pub` | Ed25519 private key (raw 32-byte seed, 0600) and public key (raw 32 bytes), created by `aiur mobile enable` |
| `store.json` | MP-N2 store schema version (`{"schema": 1}`) |
| `devices.json` | device rows: device_id, label, platform, auth_public_key, parent_device_id, paired_at, last_seen_at, push_registration (opaque, MP-N4), token_hashes[{hash, expires_at}] |
| `pairing.json` | outstanding pairing secret hashes with expiry and use flag |
| `journal.ndjson` | append-only: paired, relinked, revoked, unpair_all, claim_lockout (no secrets) |
| `known_instances.json` | gateway-kept list of instances seen in the last 7 days (§6.3 `stopped`) |
| `store.lock/` | `mkdir` lock holding the writer's pid (algorithm of `acquire_aiur_launch_lock`, `aiur-engine.sh:1522-1563`) |
| `gateway.pid`, `gateway.log` | gateway lifecycle (MP-N2-C4-T02) |

`devices.json` also keeps a bounded `recently_revoked` list of device ids, so a revoked
device receives `device_revoked` rather than `token_unknown`.

Writes: the gateway is the single writer (write temp, fsync, rename). Instances
and the CLI read only, except that the CLI may write when the gateway is not
running, under the same lock directory pattern the launcher uses
(`acquire_aiur_launch_lock`, `aiur-engine.sh:1522-1567`).

## 6. Instance registry

### 6.1 Sources joined by the gateway

1. **Launcher records** `~/.config/aiur/instances/<node-slug>.instance`
   (`write_aiur_instance_record`, `aiur-engine.sh:1586-1612`). Written at launch,
   deleted on clean stop (`aiur-engine.sh:2104`, `:3619`), left behind after a
   crash. These files are shell-`source`d (`aiur-engine.sh:2187`); the gateway parses
   them as `KEY=value` text and never executes them, and nothing in this contract
   adds fields to them.
2. **Instance advertisement** (new, MP-N2-C2):
   `~/.config/aiur/instances/<node-slug>.advert.json`, written by the instance
   BEAM after the HTTP listener binds and refreshed every 30 s:
   `{contract: "aiur.advert/v1", instance_id, instance_key, node, repository,
   project_root_basename, pid, started_at, heartbeat_at, dashboard: {bound: bool,
   base_url|null, device_url|null, transport: "https"|"http_overlay"|"none", bind_host,
   port|null, loopback_only: bool}, mobile_device_auth: bool, summary_rpc: "v1"|null}`.
   `device_url` is `Aiur.HttpServer.device_url/0` (MP-N2-C10-T01).
   `base_url` comes from `Aiur.HttpServer.base_url/0` (`http_server.ex:141-156`),
   which is nil unless a listener is really bound. Removed on clean shutdown.
3. **Node liveness** through epmd (`probe_node_liveness`, `aiur-engine.sh:2136-2149`).

### 6.2 Reachability is not authorization

- A device must hold a valid token for every call. Being on the tailnet or LAN
  grants nothing.
- The gateway binds loopback by default, the same default instances use since
  #2995 (`default_dashboard_host`, `aiur-engine.sh:728-730`). Off-machine access
  needs an explicit `machine.gateway.host` (§8). MP-R3 owns the binding guard; this
  contract requires that the gateway refuses a non-loopback bind while mobile is
  disabled.
- Tokens are bearer secrets. Over plain HTTP they are only as private as the
  network path. Plain HTTP is acceptable only on an encrypted overlay (for example a
  tailnet). Otherwise the operator configures HTTPS. Platform limits (accessed
  2026-10-06): iOS 17 ATS "no longer allows connections to IP addresses by default"
  (<https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking>);
  Android API 28+ defaults `cleartextTrafficPermitted="false"`
  (<https://developer.android.com/privacy-and-security/security-config>). How the app
  reaches HTTP endpoints (ATS exception for 100.64.0.0/10, or HTTPS via `tailscale cert`,
  which publishes machine names to Certificate Transparency,
  <https://tailscale.com/kb/1153/enabling-https>) is **RQ-TRANSPORT** (RC-15), specified
  in §8.1 and owned by MP-N2 with MP-R3.

### 6.3 Registry API

```text
GET /v1/instances[?include=summary]   (token)
→ { machine_id, observed_at, instances: [ InstanceEntry ], sig }
```

`InstanceEntry`:

```text
{ instance_id, instance_key, repository, project_root_basename,
  state: "live" | "starting" | "stale" | "stopped" | "crashed" | "unknown",
  state_reason, last_seen_at,
  dashboard: { reachable_for_devices: bool, url|null, reason|null },
  summary: InstanceSummary | {status: "unavailable"|"unsupported", reason} }   # §7
```

State rules (each evaluated by the gateway at `observed_at`):

| State | Evidence |
| --- | --- |
| `live` | node up in epmd and advert `heartbeat_at` younger than 90 s |
| `starting` | launcher record present, node up, no advert yet, record younger than 5 min |
| `stale` | node up but advert older than 90 s, or summary RPC timed out |
| `crashed` | launcher record present, node down (no clean stop removed it) |
| `stopped` | no record, but the gateway saw this instance in the last 7 days (gateway-kept `known_instances` list) |
| `unknown` | evidence missing or contradictory; never upgraded to `live` |

The gateway never deletes launcher records (the launcher owns them).
`dashboard.reachable_for_devices` is false, with a reason, when the instance is
loopback-only, not bound (`--no-dashboard` or a port conflict), or has device auth
off. `reason ∈ {loopback_only, not_bound, device_auth_off, tls_unavailable,
cleartext_not_allowed, unknown}` (closed list; unclassified causes are `unknown`).
`dashboard.url` is the instance's HTTPS device URL (`Aiur.HttpServer.device_url/0`,
MP-N2-C10-T01), or its overlay HTTP URL only when `transport.allow_cleartext_overlay`
is true (§8.1). The phone shows the summary and explains why "Open dashboard" is unavailable.

## 7. Per-instance summary (owned with MP-N3)

Producer: a new `Aiur.InstanceSummary.v1/0` inside each instance, called by the
gateway over the existing control RPC plane (the same distribution the launcher uses for
`aiur status`, `run_release_rpc_with_timeout`, `aiur-engine.sh:2333-2387`; same
per-user cookie). It works with `--no-dashboard`. An instance on an older release
returns `undef`, and the gateway reports `{status: "unsupported", reason: "instance release predates summary v1"}`.

Every field is a **Fact**:
`{status: "available"|"unavailable"|"disabled"|"unknown", value, observed_at, age_ms, reason}`.
`value` is present only when `status == "available"`. A consumer must never treat a
missing value as 0.

| Field | Source at 45a290e3 | Notes |
| --- | --- | --- |
| `agents.active` | `Orchestrator.dashboard_snapshot/2` (`orchestrator.ex:684`), `length(snapshot.running)` as in `Presenter.state_payload` (`presenter.ex:41-58`) | Status `stale` maps to Fact `available` with `freshness: "stale"` and the snapshot's age; `:snapshot_unpublished` and `:orchestrator_unavailable` map to `unavailable` with that reason. |
| `agents.capacity` | snapshot `capacity` | Optional. |
| `fleet.globally_paused` | snapshot `globally_paused` | Shown so that "0 active" while paused reads as paused, not idle. |
| `commands.awaiting` / `commands.awaiting_blocking` | `Aiur.DecisionQuery.counts/1` (`decision_query.ex:76-96`) `awaiting`, `awaiting_blocking`; after MP-E2-C7-T1 lands, the E2 "needs you" count definition (DESIGN-E2 §6.2) replaces it with the same field names | nil means `unavailable`. `health.status == :partial` adds `lower_bound: true` ("at least"). The UI term is **"units awaiting commands"** / aria **"Commands awaiting you"** (`overview.ex:53,168-169`). |
| `executor` | `Aiur.Executor.Roster.build(record?: false)` (`executor/roster.ex:50-67`) | Value `{state, consumers}`. Aggregate: `active` if any consumer is active, else `stalled` if any is stalled, else `idle`, else `expired`, else `absent` (no claims; the MP-R1 identity term, §1.4), else `unknown`. Pass `record?: false` so a summary read does not change the roster's evidence. MP-E3 adds harness and conversation fields later. |
| `build_orders` | `Aiur.BuildOrder.GraphProjection.catalog/1` (`graph_projection.ex:44`) roots: `RootSummary.progress` and `progress_resolution` (`root_summary.ex:21-22`) | List of non-completed roots `{identity, progress, resolution}` (root **titles are omitted**: the summary is mirrored to watches and cached on phones, and carries no ticket text; a title, if DESIGN-N3 needs one, is read from the instance dashboard); `disabled` when the instance has no build-order capability. Which root(s) the phone shows is DESIGN-N3 OQ. |
| `background_agents` | none today | `unavailable` with `reason: "capability_not_provided"` until MP-E3 supplies it. |
| `capabilities` | MP-R1 capability contract | List consumed as-is. |

Summary size budget: under 4 KiB per instance. It carries no ticket text,
Command questions or transcript content, because it is served to the registry
list and may be mirrored to a watch.

## 8. Machine settings (`~/.aiur/machine`)

Pure YAML, read by the gateway, `aiur mobile`, and the instance HTTP server's
transport loader (§8.1), never by the workflow loader. Settled by RC-03: machine-level
settings (mobile, pairing, relay, transport) live in this file; `~/.aiur/config` is
unchanged. Note the two paths: **settings** are `~/.aiur/machine` (a file the operator
edits), **state** is `~/.config/aiur/machine/` (a directory aiur writes).

```yaml
mobile:
  enabled: false                 # aiur mobile enable|disable
gateway:
  host: 127.0.0.1                # explicit; never auto-detected
  port: 4710                     # fixed, so the phone's endpoints stay valid; 0 is rejected
  endpoints: []                  # advertised base URLs; empty = derive from host:port
pairing:
  secret_ttl_seconds: 600
  max_devices: 20
  pin_rotation_grace_seconds: 604800   # T-B only
transport:                       # RQ-TRANSPORT (RC-15); see §8.1
  tls:
    cert_file: null              # PEM chain; e.g. written by `tailscale cert`
    key_file: null               # PEM private key, mode 0600
    bind_host: null              # address the HTTPS listeners bind (e.g. the tailnet IP); null = HTTPS off
    advertise_host: null         # DNS name the certificate covers (e.g. host.tailnet.ts.net)
  allow_cleartext_overlay: false # true only if the owner keeps the HTTP-degraded mode
```

`gateway.tls` from the Phase B draft is replaced by the single machine-wide
`transport.tls`: one certificate names the host, and every instance and the gateway
serve it on their own ports.

### 8.1 Transport security (RQ-TRANSPORT, owned by MP-N2 with MP-R3)

The dashboard serves plain HTTP only (`src/lib/aiur/http_server.ex:64,147`). iOS ATS
refuses HTTP and, since iOS 17, IP literals; Android refuses cleartext from API 28; an
HTTP origin is not a secure context, so the WebView microphone cannot work. Every
ticket that loads a dashboard in a WebView therefore depends on RQ-TRANSPORT.

**Owner choice (DESIGN-N2 §transport, open):**

| Option | What the operator does | Evidence (accessed 2026-10-06) | Cost |
| --- | --- | --- | --- |
| **T-A (recommended): publicly trusted certificate files** | Point `transport.tls` at a cert and key. The documented recipe is `tailscale cert`; any ACME client or CA works, so Tailscale stays optional. | `tailscale cert` gets a Let's Encrypt certificate; "you are responsible for renewing" (90-day validity); "machine names are still published in the public ledger" (<https://tailscale.com/kb/1153/enabling-https>) | Machine name in CT logs; renewal every ≤ 90 days |
| T-B: aiur-managed self-signed certificate, SPKI pin carried in the QR | aiur generates the cert; the QR gains `&t=<base64url sha256(SPKI)>`; the native core pins it | WKWebView server-trust override does **not** apply to WebSocket connections (Apple DTS, r. 25491679, <https://developer.apple.com/forums/thread/104376>), so LiveView's socket fails unless it falls back to long-poll, which the endpoint disables today (`longpoll: false`, `src/lib/aiur_web/endpoint.ex:14-17`; `/voice` is WebSocket-only, `:26-29`). Google Play flags `onReceivedSslError` handlers that do not validate (<https://support.google.com/faqs/answer/7071387>). | No CT disclosure; every WebView path needs custom trust code and a device proof that LiveView works |

Rules that hold for either option:

1. With `transport.tls` set (cert, key, bind_host and advertise_host), every instance
   and the gateway open a **second, HTTPS listener** on `bind_host` (instance port:
   OS-assigned, reported in the advert; gateway port: `gateway.port`) and advertise
   `https://<advertise_host>:<port>` (`InstanceEntry.dashboard.url`, QR `e=`). The
   existing HTTP listener and `Aiur.HttpServer.base_url/0` are **unchanged**
   (`server.host`/`server.port`, loopback by default), because local consumers such as
   the Claude hook settings (`claude/hook_settings.ex:68` via `:dashboard_url_fun`)
   call it on `127.0.0.1`, which a tailnet certificate does not name. The certificate's
   names must cover `advertise_host`; a mismatch or an expiry under 14 days is reported
   by `aiur mobile status` before a phone sees it.
   The HTTPS listener keeps the existing fail-closed credential rule
   (`guard_dashboard_credentials`, `http_server.ex:167-202`): a non-loopback bind needs
   Basic Auth credentials **or** mobile device auth enabled (MP-N2-C6); MP-R3-C1 extends
   its census to cover the second listener.
2. Without `transport.tls`, the advertised URLs are `http://`. The QR refuses to show
   non-loopback HTTP endpoints unless `transport.allow_cleartext_overlay: true`
   (the HTTP-degraded mode of MP-N1 §5 / DESIGN-N1 D-N1-6). In that mode the app shows
   a persistent warning and the WebView mic as `unavailable`. Overlay endpoints are
   advertised by **DNS name, never IP literal** (iOS 17 ATS refuses IP literals, and the
   app's build-time ATS / network-security exceptions can only name domains such as
   `ts.net`; MP-N1-C5-T02). In practice the degraded mode works on the phone only with a
   Tailscale MagicDNS name, pending device check N1-RQ7 / MP-N2-C10-T05 TR-7.
3. Basic Auth, device tokens and the dashboard session are never weakened by TLS and
   never strengthened by the network: reachability is not authorization (§6.2).
4. Certificate renewal does not need a restart: the listener re-reads the files when
   their mtime changes (MP-N2-C10-T01).

Why not a section of `~/.aiur/config`: that file is the **fallback workflow
config**, used whenever a directory has no `./.aiur/config`
(`Aiur.Workflow.resolve_config_path/1`, `src/lib/aiur/workflow.ex:84-93`). Creating
it only to hold mobile keys would make every unconfigured directory start a run
with default workflow settings. A sibling machine file follows the existing
precedent of machine-level `~/.aiur/alerts` (`init/alerts.ex:19-20`,
`init/scaffold.ex:32-33`). The user-facing name stays "global machine
configuration". Reconciliation item RC-1 below.

## 9. Failure behaviour (summary)

| Situation | Behaviour |
| --- | --- |
| Gateway not running | `aiur mobile status` says so; instances still accept already-issued tokens until they expire (the store is readable); new tokens cannot be minted, so the phone shows the machine as "Gateway offline", not "no instances". |
| Machine unreachable | The phone shows last-known entries with their age, never zeros. |
| Store corrupt or unreadable | The gateway refuses to start pairing, and instances reject device tokens (fail closed). Basic Auth is unaffected. |
| Clock skew | Token expiry is checked on the machine only. Challenge nonces are machine-timed. |
| Two gateways | A lock in the store (one writer); the second exits with "gateway already running (pid)". |
| Version skew | `contract` fields are versioned; unknown major is rejected, unknown fields ignored. |

## 10. Reconciliation status

Applied in Phase C (2026-10-06): RC-01 (identity.json from MP-R1 at first boot; MP-N2
reads only), RC-02 (`instance_id` everywhere), RC-03 (`~/.aiur/machine`), RC-15
(§8.1 RQ-TRANSPORT). The Phase B items below remain for history.

### Phase B items

- **RC-1** The assignment text says pairing is exposed "via `~/.aiur/config`". This
  contract uses `~/.aiur/machine` for the hazard in §8. Owner confirms (DESIGN-N2 Q1).
- **RC-2** `machine_id` is defined here; MP-R1's identity-and-capabilities contract
  should adopt or reference it, and confirm `instance_key` is unchanged.
- **RC-3** MP-N4 owns push key format and the relay registration; this contract carries
  it as an opaque `push` object and calls a `deregister(device_id)` hook on revoke.
- **RC-4** MP-N7: a standalone watch is a child device (`parent_device_id`); revoking
  the phone revokes the watch.
- **RC-5** MP-R3 owns bind guards and endpoint wording; the gateway reuses them.
- **RC-6** MP-E1 owns "build progress"; §7 reads `RootSummary.progress` directly until E1
  publishes its contract.
