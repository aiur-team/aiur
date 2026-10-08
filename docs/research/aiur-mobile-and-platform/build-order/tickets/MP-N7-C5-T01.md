---
ticket_id: MP-N7-C5-T01
feature_id: MP-N7
chunk_id: MP-N7-C5
bucket: 3-mobile-watch
title: watchOS WidgetKit complication with total blocking count and oldest blocker age (conditional on OQ-N7-4)
status: blocked
blocked_by: [DESIGN-N7, OQ-N7-4, MP-N7-C2-T02, MP-N7-C1-T05]
prior_units: []
prior_boundaries: []
prior_features: [MP-N3]
prior_findings: ["plan §6 glanceables"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C5-T01 — watchOS complication

## Identity and outcome

- Bucket 3, MP-N7, chunk C5. **Conditional:** executed only if DESIGN-N7 D-N7-5 / OQ-N7-4
  says yes (recommended: yes, count + oldest age).
- **User value:** see from the watch face whether anything is blocked, and for how long,
  without opening the app.
- **Deliverable:** a WidgetKit widget extension target `targets/watch-widget/` (the Apple
  targets plugin type `watch-widget`, S22) with accessory families (circular, rectangular,
  inline) showing the sum of available `awaiting_blocking` Facts across live instances and
  the age of the oldest blocking open Command, plus snapshot age. Tap opens the watch app list.
- **Non-goals:** a combined inbox (it is a count only, brief §3), per-instance complications.

## Dependencies and blockers

DESIGN-N7 (D-N7-5, glanceable design), OQ-N7-4; MP-N7-C2-T02 (snapshot store);
MP-N7-C1-T05 (snapshots).

## Verified starting point

- WidgetKit: "Support accessory widgets that appear on the Lock Screen and as complications
  on Apple Watch"; ClockKit complications are the watchOS 8-and-earlier path
  (<https://developer.apple.com/documentation/widgetkit/creating-accessory-widgets-and-watch-complications>,
  accessed 2026-10-06). The app's watchOS minimum is 10 (MP-N7-C2-T01), so WidgetKit only.
- `expo-apple-targets` lists a `watch-widget` target type (S22, community).

## Chosen design

- Data: the watch app writes a compact `GlanceState{as_of, blocking_total: Fact,
  oldest_blocking_created_at?, any_unavailable: Bool}` to the shared app-group container
  whenever a snapshot is stored, then calls `WidgetCenter.shared.reloadTimelines(ofKind:
  "AiurBlocking")`.
- Aggregation: sum only `available` Facts from `live`/`stale` rows; if any row is
  `unreachable`/`unknown` or any Fact unavailable, show the sum with a "+?" marker
  (never present a partial sum as complete); if no Fact is available, show "—", never 0.
- Timeline: one entry now, plus entries every 15 min for the age text (ages computed
  from `as_of`; no data fetch in the extension).

## Implementation steps

1. Target config + extension sources; app-group entitlement shared with the watch app.
2. `GlanceAggregator` (pure) in the watch app + tests.
3. Views per family.

## Non-happy paths

Phone unreachable for long → the age grows and is shown; > 1 h shows "stale" styling.
Unpaired machine → its rows are already purged from the snapshot.

## Compatibility and rollout

Separate target; removable without affecting the app.

## Verification

```text
xcodebuild test ... -scheme AiurWatch -only-testing:AiurWatchTests/GlanceAggregatorTests
```

| Test | Expected | Must fail without |
|---|---|---|
| `partialSumShowsMarker` | one unreachable row → "3+?" | marker rule |
| `noAvailableFactsShowsDash` | all unavailable → "—" | dash rule (replace with 0 → fails) |
| `oldestAgeFromBlockingOnly` | non-blocking older Command ignored | filter |

Device: DV-W13 (complication updates within one snapshot after phone data changes; advisory).

## Completion and handoff

- [ ] Complication on device in the three families approved by DESIGN-N7.
- Dependents: none.
