# MP-N2 tickets — machine pairing, discovery and transport

Base `45a290e3`, researched 2026-10-06. **39 tickets, all `blocked`** on DESIGN-N2 (MP-REQ2).
DESIGN-N2's own text says C1, C2, C4 and C6 have no user-facing surface; the brief's gate still
applies, and the coordinator may relax it for those chunks. The **wave** column is the longest
dependency chain through MP-N1/N2/N3/N7 tickets.

**RQ-TRANSPORT (RC-15) is owned here:** chunk C10 and contract §8.1. The owner's choice in
DESIGN-N2 §transport (requested, see CONTRACT-REQUESTS.md) selects C10-T03 (T-A, recommended) or
C10-T04 (T-B); C10-T01, T02 and T05 apply to both.

| ID | Title | Status | Blocked by | Wave |
|---|---|---|---|---|
| [MP-N2-C1-T01](MP-N2-C1-T01.md) | Machine store layout, read-only identity binding and the Ed25519 machine key | blocked | DESIGN-N2, MP-R1-C2-T01 | 1 |
| [MP-N2-C2-T03](MP-N2-C2-T03.md) | Safe parser for launcher .instance records (allow-listed keys, bash %q decoding, never exe | blocked | DESIGN-N2 | 1 |
| [MP-N2-C3-T01](MP-N2-C3-T01.md) | ~/.aiur/machine settings schema and loader (mobile, gateway, pairing, transport), independ | blocked | DESIGN-N2 | 1 |
| [MP-N2-C1-T02](MP-N2-C1-T02.md) | Device rows, pairing secrets and token hashes with atomic writes and a single-writer store | blocked | DESIGN-N2, MP-N2-C1-T01 | 2 |
| [MP-N2-C10-T01](MP-N2-C10-T01.md) | Instance dashboards open a second, HTTPS listener from the machine transport settings | blocked | DESIGN-N2, RQ-TRANSPORT, MP-N2-C3-T01, MP-R3-C1-T02 | 2 |
| [MP-N2-C3-T05](MP-N2-C3-T05.md) | Extend check-config-docs.py so every ~/.aiur/machine key must be documented (machine: pref | blocked | DESIGN-N2, MP-N2-C3-T01 | 2 |
| [MP-N2-C1-T03](MP-N2-C1-T03.md) | verify_token/1 with an mtime-keyed cache, constant-time hash compare, expiry and revocatio | blocked | DESIGN-N2, MP-N2-C1-T02 | 3 |
| [MP-N2-C1-T04](MP-N2-C1-T04.md) | Append-only machine journal with no secret fields | blocked | DESIGN-N2, MP-N2-C1-T02 | 3 |
| [MP-N2-C2-T01](MP-N2-C2-T01.md) | Instance advertisement writer (<slug>.advert.json, 30 s refresh, device URL from the trans | blocked | DESIGN-N2, RQ-TRANSPORT, MP-N2-C3-T01, MP-N2-C10-T01, MP-R1-C2-T02, MP-R1-C2-T03 | 3 |
| [MP-N2-C4-T01](MP-N2-C4-T01.md) | Lean gateway boot (hidden node aiur-$USER-machine, no Aiur.Application tree) and its super | blocked | DESIGN-N2, MP-N2-C1-T02, MP-N2-C3-T01, MP-R1-C1-T01 | 3 |
| [MP-N2-C2-T02](MP-N2-C2-T02.md) | Remove the advert on clean shutdown and define the stale-advert rule | blocked | DESIGN-N2, MP-N2-C2-T01 | 4 |
| [MP-N2-C3-T02](MP-N2-C3-T02.md) | `aiur mobile` launcher dispatch, enable/disable/devices, and CLI write routing (gateway up | blocked | DESIGN-N2, MP-N2-C3-T01, MP-N2-C1-T01, MP-N2-C1-T02, MP-N2-C1-T04 | 4 |
| [MP-N2-C4-T03](MP-N2-C4-T03.md) | Gateway device-token plug, signed versioned JSON responses (machine_key), and GET /v1/mach | blocked | DESIGN-N2, MP-N2-C4-T01, MP-N2-C1-T03, MP-N2-C1-T01 | 4 |
| [MP-N2-C2-T04](MP-N2-C2-T04.md) | Registry state machine (live/starting/stale/crashed/stopped/unknown) as a pure function, p | blocked | DESIGN-N2, MP-N2-C2-T02, MP-N2-C2-T03, MP-N2-C1-T02 | 5 |
| [MP-N2-C3-T04](MP-N2-C3-T04.md) | Optional `aiur init` step: \"Pair a phone with this machine?\" for repo and global scopes | blocked | DESIGN-N2, MP-N2-C3-T02 | 5 |
| [MP-N2-C4-T02](MP-N2-C4-T02.md) | Launcher lifecycle: `aiur mobile gateway start|stop|status`, pid file, best-effort auto-st | blocked | DESIGN-N2, MP-N2-C4-T01, MP-N2-C3-T02 | 5 |
| [MP-N2-C3-T03](MP-N2-C3-T03.md) | `aiur mobile status [--json]`: machine, gateway, devices, registry snapshot, with an age o | blocked | DESIGN-N2, MP-N2-C3-T02, MP-N2-C2-T04, MP-N2-C4-T02 | 6 |
| [MP-N2-C4-T04](MP-N2-C4-T04.md) | GET /v1/instances registry endpoint and the instance RPC client (:erpc from the hidden gat | blocked | DESIGN-N2, MP-N2-C4-T03, MP-N2-C2-T04 | 6 |
| [MP-N2-C10-T02](MP-N2-C10-T02.md) | Gateway HTTPS, https endpoints in QR and registry, cleartext guard and TLS health in statu | blocked | DESIGN-N2, RQ-TRANSPORT, MP-N2-C10-T01, MP-N2-C4-T01, MP-N2-C3-T03 | 7 |
| [MP-N2-C10-T03](MP-N2-C10-T03.md) | Option T-A: `aiur mobile tls` status and setup guidance for publicly trusted certificates  | blocked | DESIGN-N2, "RQ-TRANSPORT (DESIGN-N2 §transport = T-A)", MP-N2-C10-T02, MP-N2-C3-T02 | 8 |
| [MP-N2-C5-T01](MP-N2-C5-T01.md) | Pairing secret issuance, signed `aiur-pair:v1` QR URI and `aiur mobile qr` terminal render | blocked | DESIGN-N2, MP-N2-C1-T01, MP-N2-C1-T02, MP-N2-C3-T02, MP-N2-C4-T01, MP-N2-C10-T02 | 8 |
| [MP-N2-C10-T04](MP-N2-C10-T04.md) | Option T-B: aiur-managed self-signed certificate, SPKI pin in the QR, LiveView long-poll f | blocked | DESIGN-N2, "RQ-TRANSPORT (DESIGN-N2 §transport = T-B)", MP-N2-C10-T02, MP-N2-C5-T01, MP-N1-C9-T01 | 9 |
| [MP-N2-C5-T02](MP-N2-C5-T02.md) | Gateway `POST /v1/pair/claim`: HMAC proof, single use, expiry, device limit and claim lock | blocked | DESIGN-N2, MP-N2-C5-T01, MP-N2-C1-T02, MP-N2-C1-T04, MP-N2-C4-T01, MP-N2-C4-T03 | 9 |
| [MP-N2-C5-T03](MP-N2-C5-T03.md) | Gateway `/v1/token/challenge` and `/v1/token`: P-256 ECDSA proof of the device key, 15-min | blocked | DESIGN-N2, MP-N2-C5-T02, MP-N2-C1-T03 | 10 |
| [MP-N2-C5-T04](MP-N2-C5-T04.md) | `GET /v1/machine` endpoint refresh and `POST /v1/pair/relink` for a known machine | blocked | DESIGN-N2, MP-N2-C5-T02, MP-N2-C5-T03, MP-N2-C10-T02 | 11 |
| [MP-N2-C6-T01](MP-N2-C6-T01.md) | Instance `AiurWeb.DeviceAuth`: accept device bearer tokens on `:dashboard_auth` routes; ad | blocked | DESIGN-N2, MP-N2-C1-T03, MP-N2-C5-T03, MP-N2-C2-T01, MP-R3-C1-T01 | 11 |
| [MP-N2-C5-T05](MP-N2-C5-T05.md) | Reference device client (test harness) and cross-language pairing test vectors | blocked | DESIGN-N2, MP-N2-C5-T01, MP-N2-C5-T02, MP-N2-C5-T03, MP-N2-C5-T04, MP-R1-C3-T06 | 12 |
| [MP-N2-C6-T02](MP-N2-C6-T02.md) | WebView session bootstrap: one-time device-session code and a device kind of the dashboard | blocked | DESIGN-N2, RQ-TRANSPORT, MP-N2-C10-T01, MP-N2-C6-T01, MP-R1-C2-T02 | 12 |
| [MP-N2-C6-T03](MP-N2-C6-T03.md) | `:api_write` for native device calls: bearer-authenticated requests skip the Origin check  | blocked | DESIGN-N2, MP-N2-C6-T01, MP-N2-C10-T01 | 12 |
| [MP-N2-C7-T01](MP-N2-C7-T01.md) | Device management: list, rename and revoke (gateway endpoints and `aiur mobile devices|rev | blocked | DESIGN-N2, MP-N2-C5-T03, MP-N2-C6-T01, MP-N2-C1-T02, MP-N2-C1-T04, MP-N2-C3-T02 | 12 |
| [MP-N2-C7-T02](MP-N2-C7-T02.md) | Unpair-all: one atomic store write from any paired device or `aiur mobile unpair-all`, wit | blocked | DESIGN-N2, MP-N2-C7-T01 | 13 |
| [MP-N2-C7-T03](MP-N2-C7-T03.md) | Push deregistration outbox: persisted intent, retries, `pending` reporting; calls MP-N4-C3 | blocked | DESIGN-N2, MP-N2-C7-T01, MP-N2-C4-T01 | 13 |
| [MP-N2-C8-T01](MP-N2-C8-T01.md) | Gateway local settings page (loopback only, one-time link): pairing QR, expiry countdown,  | blocked | DESIGN-N2, "DESIGN-N2 Q5 (which surfaces show the QR)", MP-N2-C5-T01, MP-N2-C7-T01, MP-N2-C4-T01 | 13 |
| [MP-N2-C8-T02](MP-N2-C8-T02.md) | Instance dashboard `/settings/mobile` LiveView: QR and device list read from the gateway o | blocked | DESIGN-N2, "DESIGN-N2 Q5 (QR on instance dashboards; Basic-Auth holders can pair)", MP-N2-C8-T01, MP-N2-C5-T01, MP-N2-C4-T01 | 14 |
| [MP-N2-C9-T01](MP-N2-C9-T01.md) | Docs: `aiur mobile` CLI reference, `~/.aiur/machine` configuration reference, new pairing  | blocked | DESIGN-N2, MP-N2-C3-T05, MP-N2-C5-T01, MP-N2-C7-T02, MP-N2-C8-T01, MP-N2-C10-T02 | 14 |
| [MP-N2-C5-T06](MP-N2-C5-T06.md) | Phone app: first-run, add-machine, QR scan, pin confirmation and relink screens (native) | blocked | DESIGN-N2, DESIGN-N1, DESIGN-N4, MP-N2-C5-T02, MP-N2-C5-T03, MP-N2-C5-T04, MP-N2-C5-T05, MP-N1-C2-T05, MP-N1-C3-T01, MP-N1-C4-T01 | 15 |
| [MP-N2-C7-T04](MP-N2-C7-T04.md) | Phone app: paired machines and devices list, rename, revoke, unpair-all and the 'removed f | blocked | DESIGN-N2, DESIGN-N1, MP-N2-C7-T01, MP-N2-C7-T02, MP-N2-C5-T06, MP-N1-C2-T05, MP-N1-C3-T02, MP-N1-C4-T01 | 16 |
| [MP-N2-C10-T05](MP-N2-C10-T05.md) | Physical-device validation of the transport (ATS, cleartext, LiveView socket, WebView mic  | blocked | DESIGN-N2, RQ-TRANSPORT, MP-N2-C10-T01, MP-N2-C10-T02, "MP-N2-C10-T03 or MP-N2-C10-T04 (whichever the owner chose)", MP-N1-C4-T02, MP-N2-C6-T02, OQ-N1-4 | 17 |
| [MP-N2-C9-T02](MP-N2-C9-T02.md) | Physical-device validation of pairing, discovery, relink, revoke and unpair-all | blocked | DESIGN-N2, OQ-N1-4, MP-N2-C5-T06, MP-N2-C6-T02, MP-N2-C7-T04, MP-N2-C10-T05, MP-N3-C4-T01 | 18 |

## Dependency order (summary)

```text
C3-T01 settings ─┬─► C10-T01 instance HTTPS ─► C2-T01 advert ─► C2-T02 ─► C2-T04 registry
MP-R1-C2-T01 ─► C1-T01 ─► C1-T02 ─┬─► C1-T03, C1-T04 ─► C3-T02 CLI ─► C4-T02, C3-T04
                                  └─► C4-T01 gateway ─► C4-T03 ─► C4-T04 ─► C10-T02 ─► C5-T01 QR
C5-T01 ─► C5-T02 claim ─► C5-T03 token ─► C5-T04 relink ─► C5-T05 vectors ─► C5-T06 app screens
C5-T03 ─► C6-T01 device auth ─► C6-T02 WebView session, C6-T03 write rule
C6-T01 ─► C7-T01 revoke ─► C7-T02 unpair-all, C7-T03 push outbox ─► C7-T04 app screens
C8-T01/T02 QR surfaces (DESIGN-N2 Q5) ; C10-T03 or C10-T04 ; C9-T01 docs ; C10-T05, C9-T02 devices last
```

## What may run concurrently

- C2-T03 (record parser) and C3-T01 (settings loader) have no MP-N2 predecessor: start first.
- C1-T03 and C1-T04 in parallel; C6-T02 and C6-T03 in parallel; C7-T02 and C7-T03 in parallel.
- C10-T03 / C10-T04 in parallel with C5 (they only write files and settings).

## Research questions

Resolved: RQ-N2-2 (no port proxy), RQ-N2-3 (lean gateway entry), RQ-N2-4 (`:erpc`), RQ-N2-5
(one-time device-session URL), RQ-N2-6 (`mkdir` lock), QR encoder (`eqrcode` 0.2.1).
RQ-N2-1 became RQ-TRANSPORT (owner choice pending; device proof in C10-T05).

Contract requests: [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md).
