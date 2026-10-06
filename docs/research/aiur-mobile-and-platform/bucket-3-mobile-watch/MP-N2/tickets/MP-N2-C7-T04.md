---
ticket_id: MP-N2-C7-T04
feature_id: MP-N2
chunk_id: MP-N2-C7
bucket: 3-mobile-watch
title: "Phone app: paired machines and devices list, rename, revoke, unpair-all and the 'removed from this machine' state"
status: blocked
blocked_by: [DESIGN-N2, DESIGN-N1, MP-N2-C7-T01, MP-N2-C7-T02, MP-N2-C5-T06, MP-N1-C2-T05, MP-N1-C3-T02, MP-N1-C4-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N1, MP-N7]
prior_findings: []
size_owner: n/a (packages/aiur-mobile)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C7-T04 — App device management screens

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C7. Surface row 2 of
  `bucket-3-mobile-watch/MP-N1/surface-boundary.md` (native, R-secret, R-multi).
- **User value:** from the phone, the operator sees each paired machine and its devices (watches
  nested under their phone), removes a lost device, or unpairs everything; a phone that was removed
  says so once and forgets that machine.
- **Deliverable (PROPOSED `packages/aiur-mobile/src/screens/machines/`):** Machines list; Machine
  detail (label, fingerprint, endpoints with their status, transport mode); Devices list; Rename;
  Revoke confirm; Unpair-all (type the machine name); Result (access removed vs notifications
  pending/complete); and the one-time "This device was removed from <machine>" notice.
- **Non-goals:** the meta-dashboard (MP-N3-C4); watch pairing UX (MP-N7).

## Dependencies and blockers

DESIGN-N2 items 5–7, DESIGN-N1 frame; MP-N2-C7-T01/T02 endpoints; MP-N2-C5-T06 (machines exist);
MP-N1-C2-T05 (`AiurNative.revokeLocal(machineId)`, `signedFetch`), MP-N1-C3-T02 (typed
`device_revoked` mapping), MP-N1-C4-T01 (navigation). No WebView.

## Verified starting point (base `45a290e3`)

No app exists. Contract §4.5; client capability model §3 state `revoked` ("removed from the UI after
one notice").

## Chosen design

- On any `401 device_revoked` for a machine: `AiurNative.revokeLocal(machineId)` wipes keys, tokens,
  endpoints, cached summaries and WebView cookies for that machine's origins; the UI shows the notice
  once (persisted flag), then removes the machine. Copy states that data already shown on the phone
  is not recalled (contract §2 rule 3; DESIGN-N2 acceptance).
- Unpair-all result screen renders `control` and `push` separately; `pending` shows with an age.
- Revoking this device itself is allowed and goes through the same wipe.

## Implementation steps

Screens, a `machines` store (TS) fed by `GET /v1/devices` and `/v1/machine`, and the revoke wipe
hook. About 300 production lines.

## Non-happy paths

Machine unreachable (list shows last-known devices with age; revoke disabled with reason
`unreachable`); `404 device_unknown` on revoke treated as success; confirm-name mismatch; gateway
offline.

## Compatibility and rollout

App-only.

## Verification

`packages/aiur-mobile/src/screens/machines/*.test.tsx` and `src/machines/store.test.ts`:

1. `"device_revoked wipes the machine and shows the notice exactly once"`. *Fails without:* the wipe
   hook (mutation: skip `revokeLocal` → the stored token is still present, test fails).
2. `"device_unknown on revoke is treated as success"`.
3. `"unpair-all result shows control and push separately"`.
4. `"watches are nested under their parent phone"`.
5. `"revoke is disabled while the machine is unreachable"`.

```bash
npm --prefix packages/aiur-mobile test -- src/screens/machines src/machines
```

Device rows R1–R3 of MP-N2-C9-T02 (iPhone iOS 17.x and 26.x, Android 13+ Pixel-class).

## Completion and handoff

- [ ] Tests pass with mutation checks; device rows pass.
- [ ] Docs: pairing guide "Removing a device" with screenshots after DESIGN-N2 approval.
