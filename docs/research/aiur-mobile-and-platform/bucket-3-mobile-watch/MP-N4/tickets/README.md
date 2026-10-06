# MP-N4 tickets — encrypted push and relay

Base `45a290e3`, researched 2026-10-06. Plan: [../plan.md](../plan.md); chunks:
[../chunks.md](../chunks.md); contract (owned):
[notification-destination-and-payload.md](../../../contracts/notification-destination-and-payload.md) v2.

## Status semantics

- `blocked_by` always lists **DESIGN-N4**. DESIGN-N4's own text releases C1–C3 (crypto,
  relay, daemon client) before approval except the setup copy; those tickets list it as
  `DESIGN-N4 (no-UI release)`.
- `ready` = the specification is complete; implementation still waits for everything in
  `blocked_by` (predecessors, refactor, design gate).
- `blocked` = an unresolved owner decision, research question, device result or design
  **content** changes what the ticket builds. The ticket names which part.

## Tickets

Wave numbers are inside MP-N4 (all of MP-N4 is delivery wave 5, after MP-R1/R2, MP-E2,
MP-N2 core).

| ID | Title | Status | Blocked by (beyond DESIGN-N4) | Wave |
| --- | --- | --- | --- | --- |
| [MP-N4-C3-T00](MP-N4-C3-T00.md) | Post-refactor path refresh | ready | MP-R1 (R1-C1), MP-R2-C5/C6 | 0 |
| [MP-N4-C1-T01](MP-N4-C1-T01.md) | Crypto primitives on OTP 28 + runtime guard (E-C4 resolved) | ready | C3-T00 | 1 |
| [MP-N4-C1-T02](MP-N4-C1-T02.md) | HPKE seal/open, RFC 9180 vectors | ready | C1-T01 | 2 |
| [MP-N4-C1-T03](MP-N4-C1-T03.md) | Payload encoder, size budget, frame, detached signature | ready | C1-T02, MP-N2-C1-T01 | 3 |
| [MP-N4-C1-T04](MP-N4-C1-T04.md) | nid/collapse derivation + golden vectors | ready | C1-T03, MP-R1-C3 | 4 |
| [MP-N4-C2-T01](MP-N4-C2-T01.md) | Relay skeleton: handles, send, idempotency, storage | ready | — | 1 |
| [MP-N4-C2-T02](MP-N4-C2-T02.md) | Relay APNs adapter | ready | C2-T01 | 2 |
| [MP-N4-C2-T03](MP-N4-C2-T03.md) | Relay FCM HTTP v1 adapter | ready | C2-T01 | 2 |
| [MP-N4-C2-T04](MP-N4-C2-T04.md) | Relay abuse controls | ready | C2-T01 | 2 |
| [MP-N4-C2-T05](MP-N4-C2-T05.md) | Relay packaging, CI, operator guide | ready | C2-T02..T04 | 3 |
| [MP-N4-C2-T06](MP-N4-C2-T06.md) | Default relay deployment | **blocked** | **OQ-N4-1**, RQ-N4-7, OQ-N1-1, C2-T05 | 6 |
| [MP-N4-C2-T07](MP-N4-C2-T07.md) | (Optional) Cloudflare Workers port | **blocked** | **RQ-N4-8**, OQ-N4-1, C2-T06 | 7 |
| [MP-N4-C3-T01](MP-N4-C3-T01.md) | `push:` settings in `~/.aiur/machine` + docs | ready | C3-T00, MP-N2-C3-T01, MP-N2-C3-T05 | 1 |
| [MP-N4-C3-T02](MP-N4-C3-T02.md) | Durable outbox | ready | C3-T01 | 2 |
| [MP-N4-C3-T03](MP-N4-C3-T03.md) | Fan-out and relay client | ready | C3-T02, C1-T03, C1-T04, MP-N2-C1-T01/T02 | 5 |
| [MP-N4-C3-T04](MP-N4-C3-T04.md) | Supervision + `push` capability | ready | C3-T03, C1-T01, MP-R1 capability registry | 6 |
| [MP-N4-C3-T05](MP-N4-C3-T05.md) | Deregistration hook + purge | ready | C3-T03, MP-N2-C7-T03 | 6 |
| [MP-N4-C3-T06](MP-N4-C3-T06.md) | Privacy guard tests | ready | C3-T03 | 6 |
| [MP-N4-C3-T07](MP-N4-C3-T07.md) | Push status line + setup copy | **blocked** | **DESIGN-N4 content**, DESIGN-N2, C3-T04, MP-N2-C3-T03 | 7 |
| [MP-N4-C4-T01](MP-N4-C4-T01.md) | iOS per-machine push keys | ready | DESIGN-N1, N1-C2-T01, N1-C6-T01, MP-N2-C5-T05 | 5 |
| [MP-N4-C4-T02](MP-N4-C4-T02.md) | iOS acceptance pipeline | ready | C4-T01, C1-T04, N1-C2-T03, N1-C6-T01 | 6 |
| [MP-N4-C4-T03](MP-N4-C4-T03.md) | iOS presentation mapping | **blocked** | **DESIGN-N4 D-1/D-2/D-3/D-5**, DESIGN-E2 §4.1, OQ-N4-3, C4-T02 | 7 |
| [MP-N4-C4-T04](MP-N4-C4-T04.md) | iOS retraction | **blocked** | **RQ-N4-5**, OQ-N4-3, DESIGN-N4 D-4, C4-T03 | 8 |
| [MP-N4-C4-T05](MP-N4-C4-T05.md) | iOS registration (APNs token, relay handle) | ready | C4-T01, C2-T01, N1-C6-T01, MP-N2-C5-T02 (CR-N4-3) | 6 |
| [MP-N4-C5-T01](MP-N4-C5-T01.md) | Android per-machine Tink keysets | ready | DESIGN-N1, N1-C2-T02, MP-N2-C5-T05 | 5 |
| [MP-N4-C5-T02](MP-N4-C5-T02.md) | Android acceptance pipeline | ready | C5-T01, C1-T04, N1-C2-T03, N1-C6-T01 | 6 |
| [MP-N4-C5-T03](MP-N4-C5-T03.md) | Android channels, permission, force-stop warning | **blocked** | **DESIGN-N4 D-1/D-2/D-5/§4**, DESIGN-E2 §4.1, **RQ-N4-9**, C5-T02 | 7 |
| [MP-N4-C5-T04](MP-N4-C5-T04.md) | Android retraction | **blocked** | **DESIGN-N4 D-4**, C5-T03 | 8 |
| [MP-N4-C5-T05](MP-N4-C5-T05.md) | Android registration (FCM token, relay handle) | ready | C5-T01, C2-T01, N1-C6-T01, MP-N2-C5-T02 (CR-N4-3) | 6 |
| [MP-N4-C6-T01](MP-N4-C6-T01.md) | Apple Watch delivery decision (V-W1) | **blocked** | **RQ-N4-2** (device), DESIGN-N7, OQ-N4-1, C4-T02/T03 | 8 |
| [MP-N4-C6-T02](MP-N4-C6-T02.md) | Wear OS bridging + dismissal ids | **blocked** | **DESIGN-N7** content, C5-T03/T04 | 9 |
| [MP-N4-C6-T03](MP-N4-C6-T03.md) | Watch as direct-push child device | **blocked** | **C6-T01 decision**, DESIGN-N7, C3-T03 | 9 |
| [MP-N4-C7-T01](MP-N4-C7-T01.md) | Validation harness + report template | ready | C2-T05, C3-T03 | 6 |
| [MP-N4-C7-T02](MP-N4-C7-T02.md) | Physical-device validation run (AC-N4-9) | **blocked** | **OQ-N4-1**, owner authorization, C2-T06, all C4–C6, MP-N5-C3-T03, MP-N6-C3-T02 | 10 |

Totals: 34 tickets — C1 4, C2 7, C3 8, C4 5, C5 5, C6 3, C7 2. **Ready 23, blocked 11.**

## What OQ-N4-1 (publisher / relay operator) blocks — and what it does not

Blocks: C2-T06 (default deployment), C2-T07 (Workers), C6-T01 and C7-T02 (need real
APNs/FCM credentials or a self-built app). **Not** blocked: the crypto library (C1), the
relay code and packaging (C2-T01..T05), the daemon outbox/fan-out/capability (C3-T00..T06),
the native key stores, acceptance pipelines and registration (C4-T01/T02/T05,
C5-T01/T02/T05). They are researchable and specified now; their only waits are
predecessors and the design gate's release.

## Order inside the feature

```text
C3-T00 ─► C1-T01 ─► C1-T02 ─► C1-T03 ─► C1-T04 ─┐
C3-T01 ─► C3-T02 ───────────────────────────────┴─► C3-T03 ─► {C3-T04, C3-T05, C3-T06} ─► C3-T07
C2-T01 ─► {C2-T02, C2-T03, C2-T04} ─► C2-T05 ─► C2-T06 ─► C2-T07
C1-T04 + N1-C2 ─► {C4-T01 ─► C4-T02 ─► C4-T03 ─► C4-T04 ; C4-T05}
C1-T04 + N1-C2 ─► {C5-T01 ─► C5-T02 ─► C5-T03 ─► C5-T04 ; C5-T05}
C4-T03 ─► C6-T01 ─► C6-T03 ; C5-T04 ─► C6-T02
C2-T05 + C3-T03 ─► C7-T01 ─► C7-T02 (after everything)
```

## May run concurrently

- C1 chain, C2-T01..T05 and C3-T01/T02 are independent tracks.
- C2-T02, C2-T03, C2-T04 in parallel after C2-T01.
- C3-T04, C3-T05, C3-T06 in parallel after C3-T03.
- iOS (C4) and Android (C5) tracks in parallel; C4-T05 ∥ C4-T02, C5-T05 ∥ C5-T02.

## Boundary with MP-N1

MP-N1 owns the NSE target, the `FirebaseMessagingService` class, entitlements, the
keychain/Keystore wrappers, the raw HPKE open helper (N1-C2-T03) and the hand-off of the
registration (MP-N1-C6-T01 `pushToken()`; candidate N1-C6-T04 folded into it). MP-N4-C4/C5 own: which keys exist and their storage class, the
acceptance pipeline (frame, signature, kid→machine, expiry, seen-`nid`, stream), the
presentation mapping, retraction and relay-handle registration. CR-N4-6 asks MP-N1 to
record this split.

## Contract requests

See [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md) (CR-N4-1..CR-N4-6).
