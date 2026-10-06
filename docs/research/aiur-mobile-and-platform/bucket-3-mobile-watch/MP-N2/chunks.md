# MP-N2 chunks

Parent: [plan.md](plan.md). Contract: [../../contracts/pairing-and-instance-registry.md](../../contracts/pairing-and-instance-registry.md).
Base: `45a290e3`. Paths under `src/lib/aiur/machine/` are **proposed**, not existing.
Every ticket that changes user-facing CLI output, setup or a screen is blocked on **DESIGN-N2**.

Dependency order:

```text
MP-N2-C1 store ─┬─► MP-N2-C3 settings+CLI ─► MP-N2-C4 gateway ─► MP-N2-C5 pairing ─► MP-N2-C7 revoke
                ├─► MP-N2-C6 instance device auth ◄───────────────────────┘
MP-N2-C2 advert+registry reader ─► MP-N2-C4 (registry API)
MP-N2-C8 QR settings surface (needs C4, C5, DESIGN-N2) ; MP-N2-C9 docs + device validation (last)
```

---

## MP-N2-C1 — Machine store library

- **Outcome:** a pure library that creates and reads the machine store (contract §5):
  machine id and key, device rows, pairing secrets, token hashes, journal; atomic writes;
  permission and owner checks; fail-closed reads.
- **Depends on:** none (MP-R1 placement only, A1).
- **Tickets:**
  - MP-N2-C1-T1 Store layout, schema version, `identity.json` and Ed25519 `machine_key` creation with 0700/0600 and an owner check mirroring `ensure_erlang_cookie` (engine:321-347).
  - MP-N2-C1-T2 Device rows, pairing secrets and token hashes, with atomic temp+fsync+rename writes and a single-writer lock.
  - MP-N2-C1-T3 `verify_token/1` with an mtime-keyed cache, constant-time compare of sha256 digests (the `SupervisorAuth` pattern, `supervisor_auth.ex:78-82`), expiry, revoked → error.
  - MP-N2-C1-T4 Append-only `journal.ndjson` with no secret fields.
- **Tests:** temp HOME and XDG dirs only (AGENTS.md "Reading real state"); permission
  failure → fail closed; corrupt JSON → `{:error, :store_corrupt}` and no token accepted;
  mutation check: replace the compare with `==` on raw tokens, or skip the expiry check, and a
  test must fail; a grep test that no token appears in the journal.
- **Research:** RQ-N2-6 locking between the gateway and CLI.

## MP-N2-C2 — Instance advertisement and registry reader

- **Outcome:** each instance writes `<slug>.advert.json` after its listener binds and
  refreshes it every 30 s; removes it on clean shutdown. A reader joins `.instance`
  records (parsed as text, never sourced), adverts and epmd liveness into the registry
  states of contract §6.3.
- **Depends on:** none for the writer; MP-N2-C1 for the "known instances" list.
- **Tickets:**
  - MP-N2-C2-T1 Advert writer process in the instance daemon: uses `HttpServer.base_url/0` and `bound_port/0` (`http_server.ex:129-156`); records the real bind host (not `display_host`) and `loopback_only`.
  - MP-N2-C2-T2 Removal on clean stop (`Aiur.Shutdown` path) and a stale-advert rule; never touches `.instance` files.
  - MP-N2-C2-T3 Safe `.instance` parser: `KEY=%q` lines, allow-listed keys only, no shell evaluation.
  - MP-N2-C2-T4 Registry state machine (`live/starting/stale/crashed/stopped/unknown`) as a pure function of (records, adverts, liveness, now), plus the 7-day `known_instances` list.
- **Tests:** table-driven state tests including "advert fresh but node down → crashed, not
  live" and "evidence missing → unknown"; mutation: default an unknown case to `live` and a test
  fails; an advert written for `--no-dashboard` has `bound: false`; a fixture `.instance`
  containing `$(touch /tmp/x)` is parsed without executing.
- **Research:** the refresh cadence versus the daemon heartbeat (`daemon_heartbeat.ex`).

## MP-N2-C3 — Machine settings and `aiur mobile` CLI

- **Outcome:** `~/.aiur/machine` (contract §8) and the commands `aiur mobile enable | disable |
  status [--json] | qr | devices | revoke <id> | unpair-all | gateway start|stop|status`.
  The optional `aiur init` step that offers mobile setup. Blocked on DESIGN-N2 for copy.
- **Depends on:** MP-N2-C1; OQ-N2-1 answered.
- **Tickets:**
  - MP-N2-C3-T1 Settings schema and loader (independent of `Aiur.Workflow`); validation errors name the key.
  - MP-N2-C3-T2 Launcher dispatch entries in `aiur-engine.sh` main case (next to `status`, engine:4110) and the RPC or direct-store paths.
  - MP-N2-C3-T3 `aiur mobile status --json` with machine id, gateway state, devices count, registry snapshot; ages on every observed field (AGENTS.md "If a surface computes an age, it renders the age").
  - MP-N2-C3-T4 `aiur init` optional step "Pair a phone with this machine?" offered for repo and global scopes (the alerts precedent, `init/alerts.ex:19-20`).
  - MP-N2-C3-T5 Docs-check: extend `scripts/check-config-docs.py` or add a sibling check so `~/.aiur/machine` keys must appear in `website/docs-app/reference/configuration.md`.
- **Tests:** "enable does not create `~/.aiur/config`" (acceptance 2); CLI golden output under
  a temp HOME; `aiurdev` and `aiur` share the dispatch (one engine).

## MP-N2-C4 — Gateway process

- **Outcome:** a per-user gateway node with an HTTP listener on `gateway.host:port`, the
  lean boot (no orchestrator), the store lock, the bind guard (refuse non-loopback while
  mobile is disabled; refuse non-loopback without TLS unless `endpoints` are declared as
  overlay addresses, final rule from MP-R3), registry endpoint `GET /v1/instances`, and
  `GET /v1/machine`.
- **Depends on:** MP-N2-C1, MP-N2-C2, MP-N2-C3; MP-R1 lean-boot decision (RQ-N2-3).
- **Tickets:**
  - MP-N2-C4-T1 Lean boot entry and supervision tree; node name `aiur-$USER-machine@127.0.0.1`.
  - MP-N2-C4-T2 Launcher lifecycle: start, stop, status, pid file, auto-start from instance launch when enabled (OQ-N2-2), non-fatal on failure.
  - MP-N2-C4-T3 Signed JSON responses (`machine_key`), versioned `contract` field.
  - MP-N2-C4-T4 Registry endpoint with the token plug; per-instance RPC with timeout (RQ-N2-4).
- **Tests:** boots with zero instances; refuses a second gateway; does not start
  `Aiur.Orchestrator` (assert child list); fails closed on a corrupt store.

## MP-N2-C5 — Pairing protocol

- **Outcome:** QR generation (contract §3), `POST /v1/pair/claim`, `/v1/pair/relink`,
  `/v1/token/challenge`, `/v1/token`, lockout after repeated bad proofs.
- **Depends on:** MP-N2-C4. Device side: MP-N1 app shell.
- **Tickets:**
  - MP-N2-C5-T1 QR URI builder and signer; terminal QR renderer for `aiur mobile qr` (library choice is a Phase C research item; must be a vetted dependency or a small in-repo encoder).
  - MP-N2-C5-T2 Claim endpoint: HMAC proof check, single use, expiry, device limit, lockout and alert.
  - MP-N2-C5-T3 Challenge and token endpoints: P-256 ECDSA verify with `:crypto`/`:public_key`, 60 s nonce, 15 min token.
  - MP-N2-C5-T4 Relink for a known `machine_id`.
  - MP-N2-C5-T5 Device-side reference client (test harness, not the app) used by integration tests and by N1.
- **Tests:** expired, reused and unknown secrets; tampered QR signature; replayed nonce;
  wrong curve; lockout timing with an injected clock.

## MP-N2-C6 — Instance device authentication

- **Outcome:** `AiurWeb.DeviceAuth` accepts a valid device bearer on every
  `:dashboard_auth` route as an alternative to Basic Auth; `POST /api/v1/device-session`
  bootstraps a dashboard session for a WebView; writes still need `:api_write` and
  `:require_writable`.
- **Depends on:** MP-N2-C1 (read-only), MP-N2-C5 (token format). Size owner: `router.ex`
  and `financial_data_access.ex` per the U8 ledger.
- **Tickets:**
  - MP-N2-C6-T1 Plug and router wiring inside `dashboard_basic_auth/2` (`router.ex:201-211`) so either credential stages the same session proof.
  - MP-N2-C6-T2 Device-session endpoint and LiveView mount compatibility (`FinancialDataAccess.on_mount`, `financial_data_access.ex:98-111`).
  - MP-N2-C6-T3 `api_write` origin rule for the app's WebView origin (RQ-N2-5).
  - MP-N2-C6-T4 Advert `mobile_device_auth` flag.
- **Tests:** mobile disabled → `device_auth_disabled` and Basic Auth unchanged; revoked token
  rejected without restart (acceptance 5); a device token on a read-only dashboard cannot
  POST messages; mutation: let the plug accept an expired token and a test fails.

## MP-N2-C7 — Revocation, unpair-all and device management

- **Outcome:** contract §4.5 endpoints and CLI; atomic unpair-all; MP-N4 deregistration
  hook with retries; split result (control versus push).
- **Depends on:** MP-N2-C5, MP-N2-C6; MP-N4 hook (stub until N4).
- **Tickets:**
  - MP-N2-C7-T1 List, rename and revoke a device (children cascade).
  - MP-N2-C7-T2 Unpair-all with the `confirm: machine_label` guard, store write, journal entry.
  - MP-N2-C7-T3 Deregistration outbox for push (persisted intent, retried, reported as pending).
- **Tests:** acceptance 5 and 6; concurrent revoke and token refresh; the offline device wipes
  its state on `device_revoked` (client harness).

## MP-N2-C8 — Settings-page QR surface

- **Outcome:** the QR and device list shown on the surfaces DESIGN-N2 approves
  (OQ-N2-5): the gateway's local loopback page and/or an instance dashboard settings view.
- **Depends on:** MP-N2-C4, MP-N2-C5, **DESIGN-N2**.
- **Tickets:** MP-N2-C8-T1 gateway local page; MP-N2-C8-T2 instance dashboard settings route
  (new `live` route under `:dashboard` session, `router.ex:139-148`) reading from the gateway;
  MP-N2-C8-T3 states: mobile disabled, gateway offline, no endpoints, QR expired.
- **Tests:** browser test for every state; the QR is not rendered for a locked session.

## MP-N2-C9 — Docs and physical-device validation

- **Outcome:** docs (`reference/cli.md`, `reference/configuration.md`, a guide page for
  pairing, the Auth section of AGENTS.md if any env var is added) and a device test plan:
  iPhone and Android on a tailnet, on a LAN, after a gateway restart, after an IP change,
  after a revoke from the second device.
- **Depends on:** all above; MP-N1 app build.
- **Tickets:** MP-N2-C9-T1 docs; MP-N2-C9-T2 device validation script and evidence template.

## Open research per chunk (Phase C)

| Chunk | Question |
| --- | --- |
| C1 | RQ-N2-6 lock protocol |
| C4 | RQ-N2-3 lean boot; RQ-N2-4 RPC mode and timeouts |
| C5 | QR encoder dependency; ATS and cleartext (RQ-N2-1) |
| C6 | RQ-N2-5 WebView origin and cookie injection |
| C4/C6 | RQ-N2-2 per-instance reachability versus a port proxy |
