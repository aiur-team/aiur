# `ui-29` dashboard component reachability at `main@b4bc11f`

Two independent read-only source reviews checked the frozen `ui-29`
conditional removal scenario against detached
`b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f`. The seven candidate files
still exist and have no production render path from the dashboard or Build
Order routes. Their current **gross** footprint is 771 physical lines, up
from the frozen 768 because `fleet_table.ex` grew by three lines. None is
over 500 lines, so this cut removes no current size-gate debt.

| Component under `src/lib/aiur_web/components/operator_control_center/` | Lines | Remaining static edges |
| --- | ---: | --- |
| `build_order_icon.ex` | 58 | Component test; active Build Order views use `BuildOrderEpicIcon`. |
| `capacity_control.ex` | 144 | Coverage exclusion in `src/mix.exs`; no render call. |
| `decision_latency.ex` | 102 | Component tests only. |
| `fleet_filters.ex` | 85 | Dormant `FleetTable`, `Overview.fleet_overview/1`, and test fixture. |
| `fleet_table.ex` | 194 | Component and `fleet_context_test.exs` tests; active dashboard renders `UnitsTable`. |
| `lifecycle_components.ex` | 102 | Component test only. |
| `recent_outcomes.ex` | 86 | Coverage exclusion; active current-run outcomes view is separate. |

`DashboardLive.render` (`dashboard_live.ex:892-995`) uses current Units and
summary components, none of these seven. The live route is in
`router.ex:140-148`; no dynamic module selection for these candidates was
found. `FleetFilters` remains a compile-time dependency of the unused
`Overview.fleet_overview/1` (`overview.ex:96-104`), so that function and its
alias must be removed with the component. Remove or update the named
component, fleet-context and dashboard test fixtures, and remove the two
coverage exclusions in `src/mix.exs:124-125`.

Keep `SortableTable`: the active Units, Tickets and Build Order tables share
its browser hook. Keep CSS used by the active current-run outcomes view,
including `.recent-subtitle-actions`. Dashboard capacity event handlers and
presenter assigns still exist; unrendered `CapacityControl` does not prove
the whole capacity feature is unused. Historical Build Order documents cite
old components but are not current render edges.

Before implementing, repeat whole-repository static and dynamic reference
searches on the actual implementation SHA, then run focused dashboard and
component tests, lint, coverage, and `aiurdev build`. A user-visible claim
requires the real foreground `aiurdev --test` render path. Record removed and
added physical lines after the change; 771 is a candidate deletion footprint,
not a measured net saving.
