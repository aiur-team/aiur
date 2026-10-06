---
ticket_id: MP-E7-C1-T05
feature_id: MP-E7
chunk_id: MP-E7-C1
bucket: 2-platform
title: "Khala: add backlog_on_leave_async and the emulated_interrupt steer carrier to spec v1 before its first release"
status: blocked
repo: khala (cross-repo)
khala_ref: origin/main 99e72a43
wave: 3
blocked_by: [DESIGN-E7, E7-D1, MP-E7-C1-T02]
prior_units: [U3]
prior_boundaries: [MSG (16)]
prior_features: [integrations-43]
prior_findings: []
size_owner: n/a (Khala repository)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C1-T05 — aiur-needed fields in spec v1 (before first publish)

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E7 / C1. **Cross-repo: Khala**
  (the chunk listed it as "both"; the aiur half is only re-vendoring, which
  MP-E7-C1-T04 does).
- **User value:** aiur can describe its two divergences from Khala
  (contract §4 `emulated_interrupt`, §6 `backlog_on_leave_async`) in the shared
  spec, so a consumer never silently misreads them.
- **Deliverable:** spec v1 (still unpublished) gains:
  - `backlog_on_leave_async: "skip" | "notice"` — an optional property of the
    control-record projection; Khala's value is `"skip"`
    (`packages/agent/src/mode.ts:11-22` advances the cursor past the backlog).
  - `steer_carrier: "native" | "emulated_interrupt"` — an optional property of
    the `steer` entry in the support map, instead of a new support-status
    literal (see Chosen design).
  - scheduler and schema goldens for both.
- **Non-goals:** Khala does not adopt `notice` or `emulated_interrupt`; its
  runtime is unchanged.

## Dependencies and blockers

- DESIGN-E7, E7-D1, MP-E7-C1-T02. **Must merge before MP-E7-C1-T03** cuts the
  first `listener-v1.0.0` tag, so v1 ships with the fields and no v2 is needed.
- The aiur default for `backlog_on_leave_async` is owner item E7-D4; this
  ticket only makes both values expressible, so it is not blocked on E7-D4.

## Verified starting point

- Khala decoders reject unknown keys (`messaging/decode.ts:94-101`;
  `delivery/decode.ts:70-80`; `decodeListeningModeView` lists exact keys,
  `delivery/listening-mode.ts:152-185`). **Resolves the contract §11 question:**
  an additive field after release is *not* safe for Khala's strict decoders; it
  must be present in v1 from the first release or ship as `v: 2`.
- Contract §11 also says adding a support status is a major change because old
  decoders map unknowns to `sync`. `MODE_SUPPORT_STATUSES` is a closed literal
  list (`delivery/listening-mode.ts:7-9`) used by `readModeSupportMap` (:252).

## Chosen design

- **`emulated_interrupt` is a carrier, not a status.** Adding a sixth literal
  to `MODE_SUPPORT_STATUSES` would make every Khala `readModeSupportMap` caller
  reject aiur-produced maps. Instead the `steer` support entry keeps a standard
  status (`experimental` when the owner accepts E7-D2) and adds
  `steer_carrier: "emulated_interrupt"`. The UI rule in contract §4 ("always
  shown as 'steer (interrupts current turn)'") keys on the carrier.
  This requires the contract §4 wording change reported to the parent.
- Both properties are **optional** in the JSON Schema; Khala's TS types gain
  them as optional, but Khala's strict *wire* decoders for Matrix events are
  not changed (those events never carry them).

## Implementation steps

1. Extend `packages/listener/src/modes.ts` types with the two optional properties.
2. Extend `generate-spec.mjs` schema output; add golden `support-map-emulated-steer.json` and `control-record-notice.json` (valid) plus `invalid-carrier.json` (invalid value).
3. Regenerate; update `MANIFEST.json`.

## Non-happy paths

- A v1 consumer that ignores `steer_carrier` would display "steer" for an
  interrupting delivery; the schema description and README state that a
  renderer must read the carrier. aiur is the only producer of the value.

## Compatibility and rollout

- Lands before the first publish; no released consumer exists. Rollback:
  revert before tagging.

## Verification

```sh
pnpm --filter @khala/listener test
node packages/listener/scripts/generate-spec.mjs --check
```

- `spec: support map with steer_carrier emulated_interrupt validates`.
- `spec: control record with backlog_on_leave_async notice validates`.
- `spec: steer_carrier "cancel" is rejected`.
- `contracts: readModeSupportMap still rejects an unknown status literal` (guard; already passes).

Mutation check: drop `emulated_interrupt` from the carrier enum; the first
test must fail.

## Completion and handoff

- [ ] Both optional fields in schema v1 and the TS reference types.
- [ ] Goldens and manifest regenerated.
- Dependents: MP-E7-C1-T03 (release), MP-E7-C1-T04 (vendor), MP-E7-C2-T02 (aiur `Effective` emits the carrier), MP-E7-C5-T03 (transition behaviour per E7-D4).
- Docs: `packages/listener/README.md` field table (Khala).
