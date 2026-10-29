# Newsletter metric contract

`metrics.compute(today, yesterday_or_none)` consumes collector schema v1 and
returns a JSON-serializable dictionary without I/O, mutation or wall-clock reads.
Import it with `packages/newsletter` on Python's module search path. No network,
git process, local daemon, or dependency is required.

The report separates `outcomes`, `allocation`, `program`, `bottlenecks`, `actions`
and `meta_patterns`. Every calculated value is `{ "value": ..., "sources": [...] }`;
source paths are fields in today's snapshot unless prefixed `yesterday.`. Missing
or stale evidence produces the literal string `unavailable`. Zero means a known
empty population. Percentages use 0–100; trends use percentage points.

- `outcomes`: merged and live counts, finished/verified feature count, feature
  share and prior share, mobile/watch feature count and shares excluding those
  merges from both numerator and denominator. Windows are `(start, end]`; the
  prior window is the preceding 24 hours from today's 48-hour merge list.
  A zero denominator yields `unavailable`. All deltas/trends remain unavailable
  without yesterday, even when today's merge list contains the prior window.
- `allocation.headline`: **primary score**, separate PC/NUC rolling-seven-day
  feature turn-hours and feature tickets worked percentages against the fixed
  95% target. Each machine also has a 24-hour view. There is no combined-machine
  percentage. The target's source, `policy.feature_allocation_target_percent`,
  names the approved newsletter policy, not an observed counter.
- `allocation.instant_context`: current running agents, instantaneous feature
  share, its daily trend, held slots and optional agent-hours. These provide
  context and never substitute for the rolling headline.
- `allocation.non_feature_intake`: per-machine 24-hour counts and percentages of
  new non-feature tickets filed straight to todo, split by source. The first
  dispatch state is historical evidence; current todo labels do not establish it.
- `allocation.feature_supply`: per-machine observed feature-starved slot-minutes,
  non-feature-during-starvation minutes, and observed minutes, using PR #6936's
  native telemetry field names. Intervals are clipped proportionally to the
  24-hour window. No observed intervals means unavailable, not zero starvation.
- `program`: now/yesterday done and total, changes in those counts, `scope`
  including completions, added, removed, reopened, paused and shelved, plus lanes.
  Completions require open yesterday and completed today, never new membership.
  Removed includes disappeared tickets and newly not-planned tickets. Closed
  not-planned tickets leave the total, including lane totals. Shelved
  is the current paused mobile/watch population (unavailable without yesterday).
  Lanes count completed tickets with `closed_at` in the window; `finished` needs
  a previously incomplete lane, now complete. Scope removal can finish a lane
  while its window completion count stays zero.
- `meta_patterns`: window log count, recurring exact themes (falling back to
  exact bottleneck text), empty-window status, newest known log timestamp.
  Similar prose is not guessed to be the same theme.

Issue/PR lists deduplicate by number, ignoring machine annotations. Conflicting
observations raise `ValueError`; they cannot safely be added or arbitrarily chosen.
Yesterday must name the same repository and previous UTC capture date. It may
have a different capture time. The current window must be exactly 24 hours.

## Optional evidence extensions

The collector currently lacks historical ancestry, verification, structured action
links and the newest out-of-window meta timestamp. Until these sources exist,
the affected report fields stay unavailable; a build timestamp is not ancestry.
Producers can supply these additive fields without changing `compute`:

- `running_build.<instance>.ancestor_shas`: **complete** list of all ancestor
  commit SHAs of that running build. Equality also proves live. Membership in
  any available running build proves live; absence proves not live only when all
  available builds have complete lists. A SHA after the build is never inferred
  live from merge time. Source state `running_build_<instance>` must be available.
- `features`: list of `{id, members: [issue_number], merges_complete: true}`.
  `merges_complete` certifies that `merges` includes **all** merges of these
  members, including those older than 48 hours. At least one merge per member
  is required. All members must be closed as completed and all merges live.
- `verification`: list of `{feature: feature_id, executor: actor,
  verified_at: UTC_timestamp}`. Records after capture are ignored. An absent
  verification source is unavailable; an available empty list means zero verified.
- `allocation.agent_hours`: map of class to observed hours covering the window,
  with `sources.agent_hours.state: available`. No extrapolation from agent counts.
- `meta_latest_at`: newest known log timestamp when `meta` only contains the
  collector's window logs. Alternatively, supply older logs in `meta`; only
  window logs contribute to patterns. If neither exists, the newest time is
  `unavailable` alongside `no logs in window`.
- `meta[].id` and optional `theme`; `executor_actions[].id` and `bottleneck_id`;
  `measures[]` with `action_id`, `at` and result fields. Only explicit links join
  actions to bottlenecks and measures to actions. Actions must follow the log;
  measures must follow the action and precede window end. Otherwise the report
  says `no action recorded` or `impact not measured`. Original evidence records
  retain their source fields for inspection.

## Allocation evidence extension

The collector currently does not export paired seven-day implement turns,
first-dispatch history or per-machine feature-supply intervals. These lines are
always present, with `unavailable` for **each** machine when its evidence is
missing. Supplying one machine never fills the other. Instant counts, current
labels and a daily source cannot establish a seven-day score.

Add `allocation_evidence` to the snapshot, keyed by logical machine `pc` / `nuc`.
Each machine may independently supply `turns`, `intake` and `feature_supply`.
Each section is an evidence block with these required fields:

| Field | Meaning |
| --- | --- |
| `state` | `available`; stale/partial/unavailable blocks cannot produce a score |
| `complete` | `true` certifies all records and capture-gap checks for the covered period |
| `window_start`, `window_end` | UTC coverage bounds, enclosing the requested 7 days or 24 hours |
| `records` | Full observed records; absent records are unavailable |

`turns.records` contains `attempt_id`, `number`, `phase`, `started_at`, `ended_at`,
`labels` and `title`. Attempt IDs uniquely identify an interval across daemon boots.
Implement intervals close at their end event, the next restart/run context, or the
snapshot end; intervals that serialize to zero length are omitted. Remaining
intervals are clipped to each report window and summed as hours. Deduplicate by
attempt ID **within each machine**;
conflicting duplicates fail loudly. Count distinct ticket numbers with at least
one overlapping implement interval; a ticket is in the feature numerator when
at least one such interval has feature labels. PC/NUC can work the same ticket:
it counts once in each machine's view, never in a summed fleet total.

The feature rule is the daemon's rule: exact `build-order`, or labels beginning
`feature:` / `build-lane:`. Tests, reviews and rework on those tickets remain
feature work. Titles only distinguish `test_ci`, `tooling` and `other` among
non-feature tickets. An `MP-*` title or title text mentioning a feature marker
never grants feature credit. Merge shares are reclassified from retained issue
labels/title; old snapshots lacking that evidence remain unavailable.

`main_fix_hours` and `unlabelled_product_hours` / `unlabelled_product_tickets`
are explicit separate lines in each work window. Non-feature turns bearing
`main-fix` / `main-fix:*`, or `incident_kind: main-red` / `merge-blocking`, go
into the exclusive `main_fix` hours bucket. They count against the non-feature
5%, instead of being hidden in `test_ci` / `other`. Non-feature product work
requires `product_directive` with its operator evidence reference; a title alone
cannot establish it. These turns go into the exclusive `unlabelled_product`
bucket and receive no feature credit. Feature labels remain authoritative.

`intake.records` contains `number`, `created_at`, `first_dispatch_state`, `labels`,
`title` and `source`. Include **all** new issues, not just non-feature issues,
for the percentage denominator. Select creation timestamps in the 24-hour
window whose first dispatch state was `todo`; deduplicate by issue number.
Sources are `flake_recorder`, `agent`, `executor`; absent/unrecognized sources
are counted visibly as `unknown`. An available empty capture yields zero counts
and an unavailable percentage, because its denominator is zero.

`feature_supply.records` contains a stable `event_id` plus the native telemetry
`kind: feature_supply`, `attributes.event: interval`, `interval_start_ms`,
`interval_end_ms`, `feature_starved_slot_minutes`,
`non_feature_during_starvation_minutes` and `observed_minutes` inside `attributes`.
Metric names are imported from `analytics/lib/analytics/feature_supply.py`'s
`METRICS`; they match `Aiur.Orchestrator.FeatureSupply`. Deduplicate event IDs per
machine. Missing metric fields remain unavailable. A recorded interval with zero
starvation is a real zero; no recorded interval cannot prove that zero.

Run `python3 scripts/test-newsletter-metrics.py`,
`python3 scripts/test-newsletter-allocation.py` and
`python3 scripts/test-newsletter-collect.py` for fixture-only contract tests.

## Rendering fields

`program.done_in_window` counts completed tickets whose closing timestamp is in
the report window. `program.states` partitions deduplicated tickets into done,
active, todo, paused, shelved and removed. Not-planned tickets are removed;
paused mobile/watch tickets are shelved. Active means a running/allocated/
waiting/retrying lifecycle or an in-progress/CI/review/rework/merging label.
Other unfinished tickets are todo. Removed tickets remain outside program total.
Lane `paused` is true only when every member is paused.
`allocation.instant_context.running_by_class` carries the existing observed
running counts by class, with source paths. None of these fields substitutes a
baseline or changes the seven-day allocation headline.
