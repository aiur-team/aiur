# MP-N2-ACC — MP-N2 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-N2-C3-T04, MP-N2-C4-T04, MP-N2-C6-T03, MP-N2-C7-T03, MP-N2-C8-T02, MP-N2-C9-T01, MP-N2-C9-T02, MP-N2-C10-T04

## Outcome

The Executor proves MP-N2 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-N2/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (39)

- MP-N2-C1-T01 — Machine store layout, read-only identity binding and the Ed25519 machine key
- MP-N2-C1-T02 — Device rows, pairing secrets and token hashes with atomic writes and a single-writer store lock (resolves RQ-N2-6)
- MP-N2-C1-T03 — verify_token/1 with an mtime-keyed cache, constant-time hash compare, expiry and revocation
- MP-N2-C1-T04 — Append-only machine journal with no secret fields
- MP-N2-C2-T01 — Instance advertisement writer (<slug>.advert.json, 30 s refresh, device URL from the transport listener)
- MP-N2-C2-T02 — Remove the advert on clean shutdown and define the stale-advert rule
- MP-N2-C2-T03 — Safe parser for launcher .instance records (allow-listed keys, bash %q decoding, never executed)
- MP-N2-C2-T04 — Registry state machine (live/starting/stale/crashed/stopped/unknown) as a pure function, plus known_instances
- MP-N2-C3-T01 — ~/.aiur/machine settings schema and loader (mobile, gateway, pairing, transport), independent of Aiur.Workflow
- MP-N2-C3-T02 — aiur mobile launcher dispatch, enable/disable/devices, and CLI write routing (gateway up → RPC, gateway down → locked direct write)
- MP-N2-C3-T03 — aiur mobile status [--json]: machine, gateway, devices, registry snapshot, with an age on every observed field
- MP-N2-C3-T04 — Optional aiur init step: \"Pair a phone with this machine?\" for repo and global scopes
- MP-N2-C3-T05 — Extend check-config-docs.py so every ~/.aiur/machine key must be documented (machine: prefix)
- MP-N2-C4-T01 — Lean gateway boot (hidden node aiur-$USER-machine, no Aiur.Application tree) and its supervision tree — resolves RQ-N2-3
- MP-N2-C4-T02 — Launcher lifecycle: aiur mobile gateway start|stop|status, pid file, best-effort auto-start at instance launch
- MP-N2-C4-T03 — Gateway device-token plug, signed versioned JSON responses (machine_key), and GET /v1/machine
- MP-N2-C4-T04 — GET /v1/instances registry endpoint and the instance RPC client (:erpc from the hidden gateway, 2 s per instance) — resolves RQ-N2-4
- MP-N2-C5-T01 — Pairing secret issuance, signed aiur-pair:v1 QR URI and aiur mobile qr terminal rendering
- MP-N2-C5-T02 — Gateway POST /v1/pair/claim: HMAC proof, single use, expiry, device limit and claim lockout
- MP-N2-C5-T03 — Gateway /v1/token/challenge and /v1/token: P-256 ECDSA proof of the device key, 15-minute access tokens
- MP-N2-C5-T04 — GET /v1/machine endpoint refresh and POST /v1/pair/relink for a known machine
- MP-N2-C5-T05 — Reference device client (test harness) and cross-language pairing test vectors
- MP-N2-C5-T06 — Phone app: first-run, add-machine, QR scan, pin confirmation and relink screens (native)
- MP-N2-C6-T01 — Instance AiurWeb.DeviceAuth: accept device bearer tokens on :dashboard_auth routes; advert mobile_device_auth flag
- MP-N2-C6-T02 — WebView session bootstrap: one-time device-session code and a device kind of the dashboard session proof
- MP-N2-C6-T03 — :api_write for native device calls: bearer-authenticated requests skip the Origin check but keep X-Aiur-Request and :require_writable
- MP-N2-C7-T01 — Device management: list, rename and revoke (gateway endpoints and aiur mobile devices|revoke), children cascade
- MP-N2-C7-T02 — Unpair-all: one atomic store write from any paired device or aiur mobile unpair-all, with a split control/push result
- MP-N2-C7-T03 — Push deregistration outbox: persisted intent, retries, pending reporting; calls MP-N4-C3-T05 when installed
- MP-N2-C7-T04 — Phone app: paired machines and devices list, rename, revoke, unpair-all and the 'removed from this machine' state
- MP-N2-C8-T01 — Gateway local settings page (loopback only, one-time link): pairing QR, expiry countdown, device list, all states
- MP-N2-C8-T02 — Instance dashboard /settings/mobile LiveView: QR and device list read from the gateway over distribution RPC
- MP-N2-C9-T01 — Docs: aiur mobile CLI reference, ~/.aiur/machine configuration reference, new pairing guide page and sidebar entry
- MP-N2-C9-T02 — Physical-device validation of pairing, discovery, relink, revoke and unpair-all
- MP-N2-C10-T01 — Instance dashboards open a second, HTTPS listener from the machine transport settings
- MP-N2-C10-T02 — Gateway HTTPS, https endpoints in QR and registry, cleartext guard and TLS health in status
- MP-N2-C10-T03 — Option T-A: aiur mobile tls status and setup guidance for publicly trusted certificates (tailscale cert recipe)
- MP-N2-C10-T04 — Option T-B: aiur-managed self-signed certificate, SPKI pin in the QR, LiveView long-poll fallback
- MP-N2-C10-T05 — Physical-device validation of the transport (ATS, cleartext, LiveView socket, WebView mic secure context)

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
