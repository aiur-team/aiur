# Newsletter metric contract

`metrics.compute(today, yesterday_or_none)` consumes collector schema v1 and
returns a JSON-serializable dictionary without I/O, mutation or wall-clock reads.
Import it with `scripts/newsletter` on Python's module search path. No network,
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
- `allocation`: instantaneous running feature agents / all running agents,
  trend against yesterday, held slots by lifecycle/class, optional agent-hours.
  It is distinct from merge outcomes and is not a rolling work-time score.
  Aggregated `allocation.units` must already deduplicate agents by issue number,
  as the collector does. Class names, including tooling, are preserved.
- `program`: now/yesterday done and total, changes in those counts, `scope`
  including completions, added, removed, reopened, paused and shelved, plus lanes.
  Completions require open yesterday and completed today, never new membership.
  Removed includes disappeared tickets and newly not-planned tickets. Shelved
  is the current paused mobile/watch population (unavailable without yesterday).
  Lanes count completed tickets with `closed_at` in the window; `finished` needs
  a previously incomplete lane, now complete, with at least one window completion.
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

Run `python3 scripts/test-newsletter-metrics.py` for fixture-only contract tests.
