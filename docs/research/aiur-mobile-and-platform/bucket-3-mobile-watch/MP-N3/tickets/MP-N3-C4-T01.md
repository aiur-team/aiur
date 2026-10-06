---
ticket_id: MP-N3-C4-T01
feature_id: MP-N3
chunk_id: MP-N3-C4
bucket: 3-mobile-watch
title: "Meta-dashboard screen frame: machine sections, loading, empty and machine-level states"
status: blocked
blocked_by: [DESIGN-N3, DESIGN-N1, DESIGN-N2, MP-N1-C4-T01, MP-N1-C2-T05, MP-N3-C3-T01, MP-N3-C5-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N1, MP-N2]
prior_findings: []
size_owner: n/a (new package code)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C4-T01 — Screen frame and machine-level states

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C4 "App meta-dashboard screen".
- **User value:** the app opens on a list of every paired machine and its instances, and says
  plainly when there is nothing paired, when a machine has no instances, when a machine cannot be
  reached, and when this phone was removed.
- **Deliverable:** native screen `MetaDashboardScreen` (PROPOSED
  `packages/aiur-mobile/src/screens/meta/`) as the root route of the MP-N1 navigation stack;
  data loading through `AiurNative.signedFetch` per machine (`GET /v1/instances?include=summary`);
  machine sections and the states in DESIGN-N3 "States to cover" rows: loading, empty (no
  machines → pairing flow), empty (no instances), offline, gateway offline, removed. Rows render
  through a placeholder `InstanceRow` that C4-T02 replaces.
- **Non-goals:** row content (T02), navigation into an instance (T03), polling (T04), the cache (T05).

## Dependencies and blockers

- DESIGN-N3 (layout and copy for each state), DESIGN-N1 (frame), DESIGN-N2 (route to first run).
- MP-N1-C4-T01 (navigation and route table), MP-N1-C2-T05 (`AiurNative.signedFetch`),
  MP-N3-C3-T01 (MetaRow), MP-N3-C5-T01 (fixture gateway for tests).
- Concurrent with: MP-N3-C4-T05 (cache).

## Verified starting point (base `45a290e3`)

No app exists (MP-N1 plan §1). Surface boundary row 3: meta-dashboard is **native** (R-multi,
R-offline) (`bucket-3-mobile-watch/MP-N1/surface-boundary.md`).

## Chosen design

- Fetch per machine in parallel (cap 4, client-capability-model.md §8), each request with a 5 s
  timeout. Errors are classified by MP-N1's probe classes (`unreachable`, `transport_error.kind`,
  `device_revoked`, `device_auth_disabled`) and fed to `toMetaRows`.
- Section order: the order machines were paired (stable); DESIGN-N3 Q1 may switch to urgency
  sorting using `urgencyKey` without a model change.
- `device_revoked`: show the DESIGN-N2 "removed" notice once, call `AiurNative.revokeLocal(machineId)`
  (wipes credentials and cache), then drop the section.
- No combined inbox: this screen renders no Command content (AC6 in MP-N3 plan).

## Implementation steps

1. Screen, section header component, state components (keys from DESIGN-N3 copy table).
2. Data hook `useMachines()` → `MachineState[]`.
3. Register as the stack root in the MP-N1 route table. About 220 lines.

## Non-happy paths

Every machine unreachable at launch (cached rows from T05 with ages; never zeros); one machine
slow (others render first); revoked during fetch (notice, wipe); fixture key in a release build
refused.

## Compatibility and rollout

App-internal. Gated by the app's release, not a server flag.

## Verification

Component tests with the fixture gateway (`packages/aiur-mobile/src/screens/meta/__tests__/`):

1. `"no machines shows the pairing empty state"`.
2. `"machine with zero instances shows the empty-instances state, not an error"`.
3. `"unreachable machine shows last seen age and no numbers"`. Mutation: render cached counts
   without the age → fails.
4. `"device_revoked shows the notice once and removes the machine and its cache"`. *Fails without:*
   the `revokeLocal` call.
5. `"two machines load in parallel; the slow one does not block the fast one"`.
6. `"screen contains no Command text"` (fixture with Command questions in a decoy field; assert absent).

```bash
npm --prefix packages/aiur-mobile test -- src/screens/meta
```

Device (slots: iPhone on iOS 17.x and on current iOS 26.x; Android 13+ Pixel-class phone):
run DV-P5 (`MP-N1/device-validation.md`) steps 1–3 against two real machines.

## Completion and handoff

- [ ] Tests pass with mutation checks; DV-P5 rows recorded.
- [ ] Docs: `website/docs-app/guide/` mobile page section "The instance list" (MP-N1-C1 docs page).
- [ ] Dependents: MP-N3-C4-T02..T05.
