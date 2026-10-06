---
ticket_id: MP-N3-C4-T05
feature_id: MP-N3
chunk_id: MP-N3-C4
bucket: 3-mobile-watch
title: "Offline cache of the last list, encrypted at rest, labelled stale, wiped on revoke"
status: blocked
blocked_by: [DESIGN-N3, MP-N1-C2-T01, MP-N1-C2-T02, MP-N1-C2-T05, MP-N3-C3-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N1, MP-N2]
prior_findings: []
size_owner: n/a (new package code)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C4-T05 — Last-known list cache

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C4.
- **User value:** opening the app with no connection still shows the last-known state of every
  instance, clearly marked with its age; a lost or unpaired phone keeps nothing for a machine it no
  longer belongs to.
- **Deliverable:** `metaCache` (PROPOSED) storing the last successful registry response per
  machine, encrypted with a key held by the native core (Keychain / Keystore), read on launch,
  rendered only through the `machine_unreachable` / `stale` row states, and deleted by
  `AiurNative.revokeLocal(machineId)`.
- **Non-goals:** caching Command content (the summary contains none, contract §7).

## Dependencies and blockers

DESIGN-N3; MP-N1-C2-T01/T02 (key storage), MP-N1-C2-T05 (`AiurNative` exposes
`cachePut/cacheGet/cacheWipe` without returning the key); MP-N3-C3-T01.

## Verified starting point (base `45a290e3`)

No app. Contract §4.5: a revoked device "wipes its stored tokens, endpoints and cached summaries
for that machine". MP-N3 plan §5 privacy: cache reveals repository names and counts only.

## Chosen design

- Storage: one file per `machine_id` in the app sandbox, AES-GCM with a per-install key generated
  and held by the native core (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on iOS; Android
  Keystore AES key). JS passes plaintext JSON in and gets it back; never the key.
- Each entry stores `fetched_at`; on read the model treats it as `stale` (or `machine_unreachable`
  if the live fetch failed) — never `live`.
- Size cap 64 KiB per machine; older entries replaced.

## Implementation steps

`src/screens/meta/metaCache.ts` + native module methods (in MP-N1-C2-T05's module). About 80 TS
lines + native glue in the C2 module.

## Non-happy paths

Device locked since reboot (key unavailable → no cache shown, loading state); corrupt file
(deleted, no cache); app reinstall (key gone → cache unreadable → deleted).

## Compatibility and rollout

Cache format version 1 in the file header; an unknown version is deleted.

## Verification

1. `metaCache.test.ts`: `"cached list renders as stale with its age, never live"`. Mutation: return
   cached rows as `live` → fails.
2. `"revokeLocal deletes the machine cache"`. *Fails without:* the wipe call.
3. `"corrupt cache is discarded"`.
4. Native tests (XCTest/JUnit in MP-N1-C2 suites): `"cache key is not exportable through the module API"`.

```bash
npm --prefix packages/aiur-mobile test -- src/screens/meta/__tests__/metaCache.test.ts
```

Device (iPhone iOS 17.x/26.x; Android 13+): DV-P9 revocation step — after revoke, inspect the app
sandbox via the debug screen: no file for that machine.

## Completion and handoff

- [ ] Tests pass with mutation checks; DV-P9 step recorded.
- [ ] Docs: mobile guide privacy note "What the phone keeps offline".
