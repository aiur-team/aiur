# MP-N1 contract requests (Phase C, 2026-10-06)

Requests from the MP-N1 ticket research for contracts or features that MP-N1 does not own.
The coordinator (or the contract owner) applies them; ticket text assumes the outcome stated.

## From MP-N1-C5..C10 (fork B)

| # | To | Request | Why | Tickets affected |
|---|---|---|---|---|
| B1 | MP-N2 (`pairing-and-instance-registry.md` §3, §8.1; MP-N2-C10-T02 endpoint selection) | When `transport.allow_cleartext_overlay` is used, advertise **DNS names** (MagicDNS `*.ts.net`) rather than `100.x` IP literals, and say so in §8.1 rule 2. | iOS ATS exceptions are static build-time keys; iOS 17+ ATS refuses IP literals by default; the only build-time-knowable overlay host suffix is `ts.net`. | MP-N1-C5-T02 |
| B2 | Owner (DESIGN-N2 §transport) | Record that the HTTP-degraded mode, if kept, is **Tailscale-specific** on the phone (build-time `ts.net` exception), while HTTPS (T-A) works with any network. | Honest scope of D-N1-6; keeps Tailscale optional for the product. | MP-N1-C5-T02 |
| B3 | MP-E5 (RC-16) | MP-E5 chunks at Phase B have no ticket for the **device-authenticated voice path** that RC-16 assigns to MP-E5 (consumed by N6/N7 and MP-N1 A5). Add a chunk/ticket ID so dependents can cite it. | N1/N6/N7 native mic tickets cannot name a predecessor. | MP-N1 native mic rows (via MP-N6-C4), MP-N7-C4 |
| B4 | MP-N4 | Confirm MP-N4-C4-T05 / MP-N4-C5-T05 consume `AiurNative.pushToken()` from MP-N1-C6-T01 **inside native code** (token never passed to JS beyond an 8-char fingerprint), and that the NSE/service put the decrypted destination in `userInfo` / intent extras under one agreed key (`aiur.destination`). | One hand-off point between N1 plumbing, N4 decrypt and N6 routing. | MP-N1-C6-T01, MP-N6-C2-T02 |
| B5 | MP-N6 | MP-N6-C2-T02 owns notification-tap routing (cold/warm start); MP-N1 candidate N1-C6-T03 is retired in its favour. | Avoid two owners for the same behaviour. | MP-N1-C6-T01 |
| B6 | Owner (DESIGN-N1) | Add `OWNER-AUTH-N1-PROTO` (authorization of the throwaway prototype, incl. Apple Developer Program cost) as an explicit decision line. | Brief §2: prototypes are proposed separately, never implicit. | MP-N1-C9-T01, MP-N2-C10-T04, MP-N1-C5-T02/T04 |
| B7 | `client-capability-model.md` (MP-N1-owned; parent applies) | Add reason codes `insecure_context` (WebView mic on HTTP) and `tls_websocket_untrusted` (iOS WebView mic under T-B) to the affordance reasons in §5. | Distinct, non-collapsed causes for the mic affordance. | MP-N1-C5-T02, MP-N1-C5-T04 |

## Requests from the C1–C4 tickets (fork A), with status

| # | To | Request | Status (parent, 2026-10-06) |
|---|---|---|---|
| A1 | MP-N2 (pairing contract §4.0–§4.2) | Fix the exact signed bytes. | **Applied**: contract §4.0 (RFC 8785, Ed25519, DER ECDSA over `nonce.device_id.machine_id`). |
| A2 | MP-N2-C6 | Per-instance session cookie name (cookies ignore ports, RFC 6265 §8.5). | **Applied**: contract §4.4 `_aiur_key_<instance_key>`; MP-N2-C6-T02. |
| A3 | MP-N2, MP-N3, MP-E2 → `packages/aiur-contracts` | Publish JSON Schemas for InstanceEntry, InstanceSummary and Commands so MP-N1-C2-T04 can generate Swift and Kotlin models. | Open (coordinator / MP-R1-C3-T06 owner). |
| A4 | MP-R1-C3 | Confirm `boot_id` lives in MP-R1-C3-T05. | Open (MP-R1). |

## Applied by the contract owner from this file

- B1 (overlay endpoints by DNS name): contract `pairing-and-instance-registry.md` §8.1 rule 2; MP-N2-C10-T02 rejects `http://` IP literals.
- B7 (`insecure_context`, `tls_websocket_untrusted`): `client-capability-model.md` §5.
