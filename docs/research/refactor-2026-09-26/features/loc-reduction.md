# Physical LOC reduction scenarios

This is a frozen `3339b887` planning baseline, not an implemented saving.
The [reproduction tool](../tooling/feature_loc_scenarios.py) counts LF-separated
physical lines in explicitly named whole-file candidates in the complete
snapshot. It includes blank/comment lines and an unterminated final line.
[The machine-readable ledger](loc-scenarios.json) lists every path, line
count and contributing feature ID. Shared feature labels use one file set:
RTK, PR watch and Linear are each counted once. Files requiring partial edits
in shared modules, tests, docs and replacement code are excluded.

| Conditional removal scenario | Feature IDs | Files | Gross file lines | Files >500 |
| --- | --- | ---: | ---: | ---: |
| Linear | config-10, integrations-03 | 4 | 981 | 1 |
| RTK | config-24, integrations-52, subsystems-41 | 1 | 241 | 0 |
| PR watch | config-32, integrations-31 | 4 | 918 | 0 |
| Claude OTLP intake | integrations-16 | 4 | 853 | 0 |
| Usage compaction | subsystems-07 | 6 | 1,297 | 0 |
| Operator wait log | subsystems-14 | 1 | 116 | 0 |
| Saturation sentinel | subsystems-20 | 1 | 245 | 0 |
| Agent process log | subsystems-26 | 1 | 576 | 1 |
| PlanningSource | ui-12 | 1 | 926 | 1 |
| Offline telemetry HTML report | ui-26 | 4 | 1,114 | 1 |
| Unreachable dashboard components | ui-29 | 7 | 768 | 0 |
| DOM-SVG/ELK layout | ui-30 | 17 | 9,909 | 3 |
| **Unique conditional footprint** | **12 scenarios** | **51** | **17,944** | **7** |

These 51 paths are distinct in the ledger; 21 exceed the 200-line preference.
The gross 17,944 lines are a *conditional file-deletion footprint*, not a
forecast of net project LOC. The DOM-SVG/ELK scenario alone accounts for
9,909 lines, including the 6,312-line vendored worker. Recheck dynamic hook
registration, packaged browser behavior and Build Order flow before deciding
that this asset chain can disappear. If any scenario is retained, its lines
are not saved. Replacement code, migrations, tests and docs may lower or
reverse the net reduction. Externalizing skills or developer tasks moves
lines; it does not remove them. The raw per-feature `lib_loc`, `test_loc` and
`loc_saving_estimate` fields overlap extensively and must never be summed.

The remaining working cuts—config-14/23/27/28/35, integrations-09,
ui-19 and ui-33—need sub-file edits, guarded scope or documentation-only
correction; no full-file line credit is assigned here. Some whole-file
scenarios also need shared caller edits. A future implementation should
publish a before/after tracked-text census on its actual base and show
`removed + added` lines by path, including tests, generated assets and docs.
Until that diff exists, **measured net saving is zero**.

The local PR deletion guard (PR #2840) and GitHub cache dashboard (PR #2841)
were removed from main; publication in 0.0.7 remains pending. They have no rows in this conditional
gross-file ledger. After publication, exclude their removed lines
from any *future refactor* saving claim; do not add them to 17,944 or treat
the frozen cache-inspector `keep` verdict as current release direction.

Current-main checks at `b4bc11f` put the seven `ui-29` files at 771 gross
lines and retain a [companion-edit gate](../synthesis/ui29-current-main-2026-09-30.md).
The `subsystems-07` six-file footprint remains 1,297 lines, but
[retired-ledger compatibility](../synthesis/usage-compaction-current-main-2026-09-30.md)
must be proved before removal. The table above stays the frozen baseline.

## Hard 500-line acceptance and preferred 200-line target

The complete frozen [file-size census](../synthesis/file-size-census.json)
contains 3,378 tracked paths: 3,293 UTF-8 text, 47 binary and 38 symlinks.
Of the text paths, 359 exceed 500 physical lines and 1,192 exceed 200. Even
deleting every conditional scenario above would remove at most seven of the
359 hard-limit violators, leaving at least 352 before new/replacement files.
Deletion is therefore a small part of the file-size program; each remaining
large component needs a cohesive owner and interface-based decomposition.

The implementation gate must use the census convention for every tracked
UTF-8 text path. **500 passes; 501 fails.** Generated and vendored text count
while tracked, including the ELK worker; there is no permanent exception.
Binary paths are classified, and symlink targets are not counted twice. At
**201 lines**, a reviewer asks for a cohesion reason; 200 does not trigger
that prompt. The preference is not a mechanical failure or an invitation to
split arbitrary line ranges.

During migration, record all current >500 files, owner and baseline count in
a visible debt ledger. New or changed text paths above 500 fail; untouched
baseline debt can remain only while counted and must not grow. Refresh the
baseline after Muse and on the implementation branch. The universal hard
gate replaces the transitional rule only when the >500 population is zero.
Gate tests must cover 500/501, 200/201, blank lines and unterminated final
lines, generated/vendor paths, binary and symlink treatment, and an edited
baseline file. See [file-size analysis](../synthesis/file-size-analysis.md)
for the area distribution and largest seams. The
[cross-report contradiction audit](../synthesis/report-wide-contradictions.md)
lists ownership decisions needed to ensure decomposition removes competing
paths instead of adding adapters above them.
