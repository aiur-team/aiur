# MP-N2 Phase C — contract and coordinator requests

Written 2026-10-06 against base `45a290e3`. MP-N2 owns
`contracts/pairing-and-instance-registry.md`; items marked **(owner)** are for the contract owner to
apply; items marked **(coordinator)** touch files MP-N2 does not own.

## Coordinator

1. **DESIGN-N2 §transport (RC-15, RQ-TRANSPORT).** Add a `§transport` decision to
   `owner-design-tasks/DESIGN-N2.md`:
   - T-A (publicly trusted certificate files; `tailscale cert` recipe; machine name published to
     Certificate Transparency) **vs** T-B (aiur self-signed certificate with an SPKI pin in the QR;
     WKWebView cannot override WebSocket trust, so LiveView needs a long-poll fallback and the WebView
     mic is unavailable on iOS). Options and evidence: contract §8.1; tickets MP-N2-C10-T01..T05.
   - Whether the HTTP-degraded mode (`transport.allow_cleartext_overlay`, DESIGN-N1 D-N1-6) survives.
   - **Recommendation: T-A; keep the overlay flag off by default.** MP-N2-C10-T03 or -T04 is closed
     according to the answer; T01, T02, T05 apply to both.
2. **MP-R3 (bind guards and docs).** MP-R3-C1-T01/T02 (route-auth census, bind-guard tests) must
   cover the second, HTTPS listener (MP-N2-C10-T01) and list `AiurWeb.DeviceAuth` (MP-N2-C6-T01) and
   the device-session routes (MP-N2-C6-T02) as authenticators. MP-R3-C2-T01 (§ Tailscale in
   `reference/optional-optimizations.md`) links to the pairing guide's transport section
   (MP-N2-C9-T01).
3. **DESIGN-N2 Q5 consequence.** MP-N2-C8-T02 hides the QR from device-session viewers (a paired
   phone cannot mint pairings for others). DESIGN-N2 should confirm or overrule this.
4. **MP-N4-C3-T05** implements the `Aiur.Machine.PushDeregistrar` behaviour defined in MP-N2-C7-T03
   (`deregister(push_registration) :: :ok | {:retry, reason} | {:gone}`).
5. **MP-N1 IDs used here** (from fork A's final list): MP-N1-C2-T03 (pairing/token protocol in the
   native cores; consumes MP-N2-C5-T05 vectors), MP-N1-C2-T05 (`AiurNative` module), MP-N1-C3-T01
   (resolver/cache), MP-N1-C4-T01 (navigation), MP-N1-C4-T02 (WebView host; consumes MP-N2-C6-T02).
   Typed write-error mapping incl. `device_revoked` is MP-N1-C3-T02 (capability cache; fork A merged it there); citations corrected by the parent on 2026-10-06.
6. **Gap closed:** surface-boundary rows 1–2 (pairing and device screens, owner MP-N2) had no chunk.
   They are now MP-N2-C5-T06 and MP-N2-C7-T04; MP-N2 `chunks.md` should list them.

## Contract owner

- **CR-N2-2 (§4.1 lockout alert).** The gateway is a lean node without the instance alert ledger
  (`Aiur.Alerts` depends on workflow config and the event exchange, `src/lib/aiur/alerts.ex:9-13,103-106`).
  Replace "write a needs-attention alert through the existing alert ledger" with "record a
  `claim_lockout` journal entry and show it in `aiur mobile status`" (MP-N2-C5-T02). A fan-out to
  instance alert feeds can be a later ticket.
- **CR-N2-4 (§4.4 WebView bootstrap) — APPLIED by the contract owner on 2026-10-06.** §4.4 says the device session uses "the same proof marker
  `FinancialDataAccess` stores today". It cannot: that marker is derived from the Basic-Auth
  username and password (`src/lib/aiur_web/financial_data_access/proof.ex:18-38,79-124`) and cannot
  be created or verified when no Basic-Auth pair exists. Rewrite §4.4 to: `POST /api/v1/device-session`
  (bearer) → `{bootstrap_path, expires_in: 30}`; the WebView navigates to `GET /device-session/<code>`
  (single use, 30 s), which sets a **device-kind** session marker and redirects to a same-origin path.
  The device marker is re-validated against the machine store on every `authorize`. This also removes
  any dependence on WebView cookie-injection or custom-header APIs (RQ-N2-5). Specified in MP-N2-C6-T02.
- **CR-N2-5 (§4.2 nonce use).** State that a nonce is consumed on the first `/v1/token` attempt,
  success or failure, and that at most 4 nonces are live per device (MP-N2-C5-T03).
- **CR-N2-6 (§4.3 relink).** State that the relink body is `{machine_id, device_id, secret_proof}`,
  that the proof uses the §4.0 rule over that body, and that relink never changes the device auth key
  (a lost key means revoke and pair again) (MP-N2-C5-T04).
- **CR-N2-7 (§4.1 body numbers).** Pairing bodies contain no non-integer numbers; the gateway rejects
  them with `invalid_body`, avoiding RFC 8785 float formatting differences across languages
  (MP-N2-C5-T02).
- **CR-N2-8 (§4.4 write rule).** Add: a request authenticated by a device bearer skips the
  `:api_write` Origin check (the bearer is not an ambient credential) but still needs
  `X-Aiur-Request: 1` and `:require_writable` (MP-N2-C6-T03).
- Applied already by the owner during Phase C (no action): §4.0 signed bytes (RFC 8785 JCS,
  `nonce.device_id.machine_id`), §4.4 per-instance cookie `_aiur_key_<instance_key>` and the one-time device-session code (CR-N2-4), §6.3 reason
  list, §8.1 transport.

## Status of contract-owner items (parent, 2026-10-06)

All of CR-N2-2, CR-N2-4, CR-N2-5, CR-N2-6, CR-N2-7 and CR-N2-8 were **applied** to
`contracts/pairing-and-instance-registry.md` (§4.0, §4.1, §4.2, §4.3, §4.4).

## Requests from the C1–C4 tickets (fork C), applied by the contract owner

- §6.1 advert: `contract: "aiur.advert/v1"`, `instance_id`, `dashboard.device_url`, `dashboard.transport`.
- §5: `known_instances.json`, `store.lock/`, `gateway.pid`, `gateway.log`, `recently_revoked`.
- §4.0: signed responses cover `contract`, `machine_id`, `observed_at`; vectors from MP-N2-C4-T03 and MP-N2-C5-T05.
- §8: `gateway.port: 0` rejected.

## Coordinator items from C1–C4 (open)

- Machine-settings keys are documented with a `machine:` prefix and checked by the MP-N2-C3-T05
  extension of `scripts/check-config-docs.py`. AGENTS.md "Docs ship with the change" says only one
  row is machine-checked; that sentence needs a coordinator edit when C3-T05 lands.
- MP-N2 plan F3 omits the real `AIUR_RECORD_` key prefix of `.instance` records (corrected in C2-T03).
