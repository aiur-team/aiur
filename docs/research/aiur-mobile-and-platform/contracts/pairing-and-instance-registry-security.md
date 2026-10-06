---
contract_id: MP-CT-pairing-and-instance-registry (part: security)
owner_feature: MP-N2
status: Phase D fix pass (2026-10-06): RC-37, RC-42, security B1, M1, M2, M3, m6
base_main_sha: 45a290e3
date: 2026-10-06
---

# Pairing contract — security sibling

This file is **normative**. It is part of
[pairing-and-instance-registry.md](pairing-and-instance-registry.md), split out in the
Phase D fix pass so the main contract stays under 500 lines. Section numbers here are
`§S<n>`; the main contract links to each one from the section it extends.

## S0. Hardware evidence for the device auth key (moved from main §2)

Accessed 2026-10-06:

- Secure Enclave "works only with NIST P-256 elliptic curve keys … for creating and
  verifying cryptographic signatures, or for elliptic curve Diffie-Hellman key
  exchange", and keys cannot be moved in or out
  (<https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave>).
  Ed25519 therefore cannot be the device key.
- Android Keystore keys bound to secure hardware are "never exposed outside of
  secure hardware"; StrongBox supports "ECDSA, ECDH P-256"
  (<https://developer.android.com/privacy-and-security/keystore>).

## S1. Threat model: same-user processes (main §2.1; RC-42, security B1)

**Statement.** Any process running as `$USER` can read and write
`~/.config/aiur/machine/` and so can obtain D19 authority over every instance on the
machine, including instances of other repositories. Agents run as `$USER`:

- Claude workers default to `permission_mode: bypassPermissions`
  (`src/lib/aiur/claude/config.ex:8` at `45a290e3`) and have full access to `$HOME`.
- Codex `workspace-write` limits writes, not reads, so a Codex worker can read
  `machine_key` and every `send_secret`.

**Attack paths this design does not stop:**

1. Write a `devices.json` row with an attacker P-256 key (the CLI may write while the
   gateway is down, and the `store.lock/` directory is advisory), then mint a token at
   `/v1/token`, or write a `token_hashes` entry directly and skip the gateway.
2. Use that bearer to answer `human_required` Commands as `:operator`
   (`POST /api/v1/device/commands/:id/answer`, MP-N6-C1-T03). The answer records
   `actor_source: :device` (command contract §6), so it looks like a phone. D9 and D12
   do not hold against this attacker.
3. Read `machine_key` plus a `send_secret` and send correctly signed, sealed pushes to
   the operator's phone (phishing inside the trusted app).
4. With the Erlang cookie, call `DecisionStore.answer/5` directly. That answer records
   `actor_source: :rpc` (command contract §4 "What `human_required` does and does not stop").

**What the design does protect against:** network attackers (HMAC pairing proof,
pinned `machine_key`, bearer only over HTTPS or a verified overlay, §S3), lost or stolen
phones (revocation, §S2), other OS users (0700/0600 plus the ownership check), and
log leakage (separation rule 1).

**Detection (built now, MP-N2-C1-T02/T03/T04):** the device-row integrity check, §S4. It
detects attack path 1 when the attacker does not also forge `journal.ndjson`. An attacker
who forges both is not detected; that is why the owner item below exists.

**Owner item DESIGN-N2 Q8 (open; text handed to the DESIGN-N2 owner):** accept the
risk, or require one mitigation before `mobile.enabled` may be `true`:

| Option | What it does | Strength |
| --- | --- | --- |
| (a) Agents run as a separate OS user | The machine store is unreadable to agents. A documented setup option. | Strongest; closes paths 1–4 except where the agent user is given the cookie. |
| (b) Gateway holds `machine_key` in the OS keyring (Secret Service / Keychain) and is the only signer; instances verify each `devices.json` row by a per-row MAC keyed from the keyring | Raises the cost of paths 1 and 3. | Does not stop a determined same-UID process (it can call the keyring too). |
| (c) The daemon adds the store paths to each harness's deny configuration (Codex sandbox read-deny; Claude `permissions.deny`) | Stops casual reads by tools that honour deny rules. | Weak: Bash bypasses Claude deny rules; the docs must say so. |

Whatever Q8 decides, `aiur mobile enable` prints the §S1 statement (MP-N2-C3-T02) and the
pairing guide (MP-N2-C9-T01) says the same thing in user words. DESIGN-N2 Q8 (the owner
gate) recommends: ship (c) and the §S4 integrity alert by default, show the residual risk
in `enable` output, document (a) as the hardening step, and do not block `mobile.enabled`
on (a). An explicit acceptance step (`--accept-same-user-risk`) is only built if the owner
asks for it in Q8; MP-N2-C3-T02 keeps it behind that answer.

## S2. Revocation propagation and latency budget (main §4.4; security M1, M2)

**Watcher.** `Aiur.Machine.Store.Watcher` (MP-N2-C1-T03) runs in **every instance BEAM**
that has device auth enabled, under the instance's web supervision tree:

- every 2 s (`@poll_ms 2_000`), `File.stat/2` of `devices.json`; when `{mtime, size,
  inode}` changes, re-read through the store library and diff the active device ids;
- `Phoenix.PubSub.local_broadcast(Aiur.PubSub, "devices:revoked", {:devices_revoked, ids})`
  for every id that disappeared, inside that instance only;
- on an unreadable or corrupt store, broadcast every previously active id (fail closed,
  main §9) and emit one `machine_store_unreadable` alert per transition;
- the gateway runs the same watcher for its own sockets. No writer broadcasts across
  BEAMs, and nothing depends on the writer reaching the instance.

**Per-surface budget (normative; each owner ticket tests its row):**

| Surface | Mechanism | Budget after the store write | Owner test |
| --- | --- | --- | --- |
| HTTP JSON (`:dashboard_auth`, `:device_auth`) and gateway `/v1/*` | `verify_token/1`, mtime cache | next request | MP-N2-C6-T01 |
| Phoenix channels (`events:feed`) | Watcher, then channel `{:stop, :device_revoked}` | ≤ 2 s poll + channel round trip (assert ≤ 3 s) | MP-R2-C7-T05 |
| `/voice/device` | Watcher; MP-E5-C8-T02's 15 s store check stays as a backstop | ≤ 3 s (backstop ≤ 15 s) | MP-E5-C8-T02 |
| LiveView device sessions (WebView) | Watcher, then `AiurWeb.Endpoint.broadcast("device_session:" <> device_id, "disconnect", %{})`; plus a `handle_event` write hook that calls `device_active?/1` | disconnect ≤ 3 s; any write after the store write refused at once | MP-N2-C6-T02 |
| Push | the outbox drops jobs for revoked devices (MP-N4-C3-T05) | next send | MP-N4-C3-T05 |
| Notifications already shown, cached summaries, plaintext already received | not recalled | never (main §2 rule 3) | — |

**Test shape that can fail (required for every watcher-driven row):** the test writes
`devices.json` **directly**, as the gateway or the CLI in another process would (temp
file, rename), and sends no message to the watcher or to PubSub. It then asserts that the
surface closes within its budget. A test that broadcasts on `devices:revoked` itself
skips the step that fails in production and does not count (AGENTS.md "fixtures built to
avoid the failure mode").

## S3. Device bearers and transport (main §4.4; security M3)

A device bearer is valid on every instance of the machine for 15 minutes (D19), so one
sniffed token gives write authority everywhere. The device-bearer plug
(`AiurWeb.Plugs.DeviceBearer`, MP-N2-C6-T01) accepts a bearer only when one of these is
true; otherwise it answers `401 {"error": "device_auth_insecure_transport"}` **before**
looking the token up:

1. the request arrived on the HTTPS listener (`conn.scheme == :https`; the endpoint serves
   both schemes after MP-N2-C10-T01 adds the `https:` key);
2. the peer is loopback (`{127,0,0,1}` or `::1` only, the MP-R3-C1-T01 loopback rule) on any listener;
3. the request arrived on the plain HTTP listener, `transport.allow_cleartext_overlay`
   is `true`, **and** the HTTP listener's bound address
   (`Aiur.HttpServer.bound_address(:http)`, from `Bandit.PhoenixAdapter.server_info/2`, not
   from config text; MP-N2-C10-T01) is inside `transport.cleartext_overlay_cidrs` (default `100.64.0.0/10`,
   `fd7a:115c:a1e0::/48`). A wildcard bind (`0.0.0.0`, `::`) never matches.

The operator flag alone is never enough: rule 3 checks the address. Loopback is not a
boundary behind a local tunnel or reverse proxy that forwards remote traffic to
`127.0.0.1`; the token is the boundary, and the transport guide (MP-N2-C9-T01, MP-R3)
says so. Basic Auth behaviour on these listeners is unchanged.

## S4. Device-row integrity check (RC-42)

- **Journaling (MP-N2-C1-T02 callback slot, MP-N2-C1-T04 wiring).** Every writer (gateway or CLI) appends a `paired` entry
  `{device_id, auth_key_sha256, at, writer: "gateway"|"cli"}` to `journal.ndjson` in the
  same locked write that adds a `devices.json` row, and a `relinked` entry on relink.
- **Check (MP-N2-C1-T03).** `Machine.Store.integrity/0` returns the device ids whose
  row has no matching `paired` entry, or whose `auth_public_key` hash differs from it.
  It runs at gateway start, on every watcher-detected change, and in
  `aiur mobile status`.
- **Effect.** An unmatched row is **not active**: `verify_token/1` and
  `device_active?/1` return false for it, and `/v1/token` answers
  `401 device_unverified`. The lean gateway has no alert ledger (main §4.1, CR-N2-2), so
  the alert is raised by each **instance's** `Store.Watcher`: one needs-attention alert
  `machine_store_untracked_device` per id per instance (deduplicated by id; no secrets,
  `device_id` and label only). `aiur mobile status` computes `integrity/0` live and lists
  each flagged row under "needs attention" with the fix: `aiur mobile revoke <id>`.

## S5. Transport evidence (moved from main §6.2 and §8.1)

Platform limits (accessed 2026-10-06): iOS 17 ATS "no longer allows connections to IP
addresses by default"
(<https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking>);
Android API 28+ defaults `cleartextTrafficPermitted="false"`
(<https://developer.android.com/privacy-and-security/security-config>). How the app
reaches HTTP endpoints (ATS exception for `ts.net`, or HTTPS via `tailscale cert`, which
publishes machine names to Certificate Transparency,
<https://tailscale.com/kb/1153/enabling-https>) is **RQ-TRANSPORT** (RC-15), main §8.1.

| Option | What the operator does | Evidence (accessed 2026-10-06) | Cost |
| --- | --- | --- | --- |
| **T-A (recommended): publicly trusted certificate files** | Point `transport.tls` at a cert and key. The documented recipe is `tailscale cert`; any ACME client or CA works, so Tailscale stays optional. | `tailscale cert` gets a Let's Encrypt certificate; "you are responsible for renewing" (90-day validity); "machine names are still published in the public ledger" (<https://tailscale.com/kb/1153/enabling-https>) | Machine name in CT logs; renewal every ≤ 90 days |
| T-B: aiur-managed self-signed certificate, SPKI pin carried in the QR | aiur generates the cert; the QR gains `&t=<base64url sha256(SPKI)>`; the native core pins it | WKWebView server-trust override does **not** apply to WebSocket connections (Apple DTS, r. 25491679, <https://developer.apple.com/forums/thread/104376>), so LiveView's socket fails unless it falls back to long-poll, which the endpoint disables today (`longpoll: false`, `src/lib/aiur_web/endpoint.ex:14-17`; `/voice` is WebSocket-only, `:26-29`). Google Play flags `onReceivedSslError` handlers that do not validate (<https://support.google.com/faqs/answer/7071387>). | No CT disclosure; every WebView path needs custom trust code and a device proof that LiveView works |
