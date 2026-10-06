---
ticket_id: MP-N2-C5-T06
feature_id: MP-N2
chunk_id: MP-N2-C5
bucket: 3-mobile-watch
title: "Phone app: first-run, add-machine, QR scan, pin confirmation and relink screens (native)"
status: blocked
blocked_by: [DESIGN-N2, DESIGN-N1, DESIGN-N4, MP-N2-C5-T02, MP-N2-C5-T03, MP-N2-C5-T04, MP-N2-C5-T05, MP-N1-C2-T05, MP-N1-C3-T01, MP-N1-C4-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N1, MP-N4]
prior_findings: []
size_owner: n/a (new package packages/aiur-mobile)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C5-T06 — App pairing screens

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C5. Surface rows 1 of
  `bucket-3-mobile-watch/MP-N1/surface-boundary.md` (owner MP-N2, native).
- **User value:** a new user opens the app, is told where to find the QR, scans it, sees the
  machine's name and key fingerprint, and lands on the meta-dashboard. A second machine is added
  the same way; a known machine is re-linked, not duplicated.
- **Deliverable (PROPOSED paths in `packages/aiur-mobile/src/screens/pairing/`):** Welcome,
  Guidance ("run `aiur mobile qr` or open Settings → Mobile"), Camera permission, Scanner, Confirm
  (machine label + `k` fingerprint as 4 groups of 4 hex), Result, and the Relink path. Logic in
  `src/pairing/flow.ts` as a pure state machine; native calls through `AiurNative.pair(qrPayload)`
  (MP-N1-C2-T05), which verifies `sig`, generates the hardware key and performs claim or relink.
- **Non-goals:** device list and revoke screens (MP-N2-C7-T04); push permission prompt placement
  is DESIGN-N4's (this flow calls the hook it provides, or skips it if absent).

## Dependencies and blockers

DESIGN-N2 (screens, copy, states table), DESIGN-N1 (app frame), DESIGN-N4 (where push permission
is asked). MP-N2-C5-T02..T05 (protocol and vectors). MP-N1-C2-T05 (`AiurNative`), MP-N1-C3-T01
(capability cache seeded after pairing), MP-N1-C4-T01 (navigation skeleton). This screen does not
load a WebView, so RQ-TRANSPORT applies only through the endpoints the QR lists (already filtered by
MP-N2-C10-T02).

## Verified starting point (base `45a290e3`)

No mobile app exists (MP-N1 plan §1). Protocol: contract §3, §4.1, §4.3. Error codes: MP-N2-C5-T02.

## Chosen design

State machine (`flow.ts`):

```text
idle → guidance → camera_permission{granted|denied} → scanning
scanning --qr parsed--> verifying --sig bad--> error{qr_invalid}
verifying --machine_id known & device valid--> relinking --ok--> done{relinked}
verifying --unknown machine--> confirm --accept--> claiming --201--> token --ok--> done{paired}
claiming --pair_secret_expired|used|unknown|device_limit|pair_locked|pairing_disabled--> error{code}
relinking --device_revoked--> confirm (fresh claim with the same QR)
any --network error--> error{unreachable, endpoints tried}
```

- The QR payload never enters JS beyond the opaque string passed to `AiurNative.pair`; JS receives
  `{machine_id, machine_label, fingerprint, endpoints_count}` for display (R-secret, MP-N1 §3.2).
- A `machine_id` already paired with a **different pinned `k`** is a hard error ("this is not the
  machine you paired"), with "Remove the old machine first" as the only action (contract §3: never
  silently re-pin).
- iOS camera usage string and Android `CAMERA` permission; denied → `needs_permission` with a
  Settings link (client capability model §3).

## Implementation steps

1. `flow.ts` + unit tests. 2. Screens per DESIGN-N2. 3. Wire `AiurNative.pair`. 4. After `done`,
   trigger instance discovery (MP-N3-C4) and push registration hook (MP-N4).

About 350 production lines (TS).

## Non-happy paths

Expired, used or unknown QR; lockout (`retry_after` shown as a countdown); device limit; mobile
disabled on the machine; no endpoint reachable (list each with its error class from MP-N1-C5);
pin mismatch; camera denied; app killed mid-claim (on relaunch, a stored half-completed claim is
discarded; the user re-scans; the server-side row exists without a device key holder → shows in the
device list as "never seen" and can be revoked).

## Compatibility and rollout

New app code only.

## Verification

`packages/aiur-mobile/src/pairing/flow.test.ts`:

1. `"known machine with valid device relinks instead of claiming"`. *Fails without:* the relink
   branch (mutation: always claim → test fails).
2. `"pin mismatch for a known machine is a hard error"`. *Fails without:* the pin check.
3. One test per claim error code mapping to its state.
4. `"device_revoked during relink falls back to a fresh claim"`.
5. `"JS never receives the secret"` — the `AiurNative.pair` mock records arguments; the flow passes
   only the raw scanned string and stores nothing else.

```bash
npm --prefix packages/aiur-mobile test -- src/pairing/flow.test.ts
```

Device (slots per MP-N2-C9-T02: iPhone on iOS 17.x and 26.x, Android 13+ Pixel-class): pair from a
terminal QR, pair from the settings page, re-scan the same machine (relink), scan an expired QR.

## Completion and handoff

- [ ] Unit tests pass with mutation checks recorded; device rows P1–P3 of MP-N2-C9-T02 pass.
- [ ] Docs: pairing guide (MP-N2-C9-T01) screenshots once DESIGN-N2 is approved.
- [ ] Dependents: MP-N3-C4 (first list load), MP-N2-C7-T04.
