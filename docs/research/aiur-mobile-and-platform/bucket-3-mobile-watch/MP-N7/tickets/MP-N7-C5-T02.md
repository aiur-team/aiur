---
ticket_id: MP-N7-C5-T02
feature_id: MP-N7
chunk_id: MP-N7-C5
bucket: 3-mobile-watch
title: Wear OS Tile with total blocking count and oldest blocker age (conditional on OQ-N7-4)
status: blocked
blocked_by: [DESIGN-N7, OQ-N7-4, MP-N7-C3-T02, MP-N7-C5-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N3]
prior_findings: ["plan §6 glanceables"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C5-T02 — Wear OS Tile

## Identity and outcome

- Bucket 3, MP-N7, chunk C5. **Conditional** as C5-T01.
- **Deliverable:** a `TileService` (androidx `wear-tiles` + `protolayout`) rendering the same
  `GlanceState` as C5-T01 using a Kotlin port of `GlanceAggregator` driven by the shared
  fixture `fixtures/watch-link/glance-cases.json` (added here; the Swift test switches to it
  in the same PR). Tap opens the Wear app list.
- **Non-goals:** a combined inbox; per-instance tiles.

## Dependencies and blockers

DESIGN-N7, OQ-N7-4, MP-N7-C3-T02, MP-N7-C5-T01 (aggregation rules).

## Verified starting point

Tiles "are defined declaratively and rendered in a separate, remote environment"; use
`protolayout` and `tiles` libraries; request refresh with
`TileService.getUpdater(context).requestUpdate(YourTileService.class)`; "Display when the
tile information was last refreshed"
(<https://developer.android.com/training/wearables/tiles>, accessed 2026-10-06).

## Chosen design

- `SnapshotRepository` change → write `GlanceState` (DataStore) → `requestUpdate`.
- `onTileRequest` reads only the stored `GlanceState` (no network, per the doc's guidance).
- Freshness interval: 15 min (age text), plus explicit updates on snapshot change.
- Render rules identical to C5-T01 ("+?" partial marker, "—" when nothing available).

## Implementation steps

1. Tile service + manifest entry + preview image.
2. Kotlin aggregator + shared fixture.
3. Tests.

## Non-happy paths

As C5-T01.

## Compatibility and rollout

Separate service; removable.

## Verification

```text
packages/aiur-mobile/wear/gradlew -p packages/aiur-mobile/wear :app:testDebugUnitTest --tests '*GlanceAggregatorTest' --tests '*AiurTileServiceTest'
```

| Test | Expected | Must fail without |
|---|---|---|
| `GlanceAggregatorTest` (fixture table) | every case | each rule; replace "—" with 0 → fails |
| `tileReadsStoredStateOnly` | no repository network call in `onTileRequest` | — (guard; commented) |
| `snapshotChangeRequestsUpdate` | updater called | the hook |

Device: DV-W13 (Wear column, advisory).

## Completion and handoff

- [ ] Tile approved in DESIGN-N7 and verified on a Wear OS 5+ device.
- Dependents: none.
