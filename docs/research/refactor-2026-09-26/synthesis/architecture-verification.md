# Architecture verification checkpoint

Checked on 2026-09-26. The survey used `0972f0297`; the frozen code review uses
`3339b887196d5e9aefb273117a14bf33391ee41f`. Both revisions were checked where
counts or ownership claims depend on the difference. This is a checkpoint,
not the final problem map or a completed code review.

## What survives independent checking

The architecture has substantial coupling under the survey's proposed boundary
map: 35 of 36 boundaries form one strongly connected component, and all 12
families are mutually reachable. The central dispatch/control reducers share a
100-field State. The Tracker contract mixes issue and code-host capabilities;
64 modules across 18 non-GitHub boundaries reference GitHub modules. These facts
justify explicit ownership and contracts before package extraction.

They do not prove that every component needs another process, every GitHub call
is wrong, or no package can move until a whole-system redesign is complete.

## Corrections that change the plan

| Claim | Checked conclusion | Planning consequence |
|---|---|---|
| codebase-02 | The large SCC reproduces. Exact edge counts depend on whether alias prefixes, strings, templates and generated code count. | Inspect the actual dependency needed at each proposed boundary; do not turn a reference count into a list of required package dependencies. |
| codebase-03 | The original relocation rules reduce modeled upward references by about 62% in the independent graph. They delete dependencies without modeling replacement contracts. | This is a design hypothesis, not a measured saving or evidence that the work is mechanical. |
| codebase-04 | Central reducers share state, but SnapshotStore and PRHealthScanner already have separate workers. | Preserve existing isolation. Give each state field and side effect an owner before deciding which owners need processes. |
| codebase-05 | Cache extraction also crosses WriteThrough -> PollSnapshots, beyond the two links named originally. | Preserve mutation/webhook ordering and review-thread invalidation. A misplaced cache invalidation can falsely restore an old resolved state. |
| codebase-06 | Comment I/O is already asynchronous; the central process still owns correlation, cursor and reconciliation state. | Move ownership deliberately. A listener supervisor is an option; one process per source is not an established requirement. |
| codebase-08 | No universal ten-minute poll ceiling exists. Global pause is persisted and updates read models; other attention events may still wake an idle fleet. | Preserve deliberate pause. Design actionable-idle escalation separately and measure actual poll delay. |
| codebase-09 | Status/agents/watch already avoid the Orchestrator mailbox through SnapshotStore. Synchronous mutations can still wait behind candidate fetches. | Preserve read-model isolation and focus latency work on the blocking mutation/fetch path. |
| codebase-10 | The survey's Tracker/GitHub coupling counts reproduce at its revision. The later revision adds one Tracker user. | Consider separate issue-tracker/code-host capabilities, without claiming every adapter-specific reference is a defect. |

`codebase-07` (attention-routing completeness) still needs its complete check.
These verdicts do not establish historical hours lost to the architectural
mechanisms; that requires the gaps and recurrence evidence.

## Independent graph census

| Measure | 0972f0297 | 3339b8871 |
|---|---:|---:|
| Defined modules | 1,062 | 1,066 |
| Primary source files | 1,028 | 1,032 |
| Primary-module reference edges | 3,849 | 3,872 |
| Cross-boundary reference edges | 2,076 | 2,087 |
| Mutually dependent boundary pairs | 98 | 98 |
| Upward edges under proposed layers | 311 | 312 |
| Largest boundary SCC | 35 | 35 |
| Largest family SCC | 12 | 12 |
| Modules relocated in original simulation rules | 57 | 58 |
| Edges deleted by those rules | 70 | 70 |
| Upward edges remaining in simulation | 119 | 119 |

Artifacts: `graph-audit-0972f0297.json`, `graph-audit-3339b887.json` and the
`claims-codebase-structure.json` / `claims-codebase-control.json` files under
`verdicts/`. The old graph had 4,012 edges; all 3,849 independent baseline edges
occur in it, with 163 additional old edges (47 cross-boundary).

Examples of why totals differ: an unused parent alias can be counted alongside
its actual child-module call; `coding_agent/route_failure.ex:40` names a backend
in documentation; `claude/repl/launcher.ex:60` names HttpServer inside an error
string. Those references are not executable dependencies. Conversely, the AST
walk does not expand HEEx or other macros, so it omits some real generated
references. Registered names such as `Aiur.PubSub` remain unresolved names,
not invented calls to their longest defined module prefix.

The tool excludes docs and alias declarations, resolves grouped and renamed
aliases lexically, includes type/struct/import/behaviour/module-value references,
and collapses nested modules to the primary file as the original survey did.
It does not infer dynamic calls, event topics, runtime ownership or library
requirements. The candidate map is retained from the survey rather than treated
as an independently discovered truth. Neither parser establishes a mathematical
lower bound on runtime coupling.

## Reproduction and validation

From the research directory, with a source snapshot extracted from the stated
Git revision:

```sh
elixir --erl '+S 2:2 +SDcpu 1 +SDio 1' tooling/module_references.exs "$SNAPSHOT" > "$REFS_TSV"
python3 tooling/graph_summary.py "$REFS_TSV" tooling/boundary-map.json --relocations tooling/relocation-rules.json
```

The source is parsed, not compiled or loaded. No application, daemon, tests or
provider process is started. Output contains public source names and counts.

Validation performed: a small independent fixture checked grouped aliases,
function-local alias scope, nested-module aliases, exclusion of documentation
references, and preservation of a runtime registry name as a distinct name.
A directed graph with one two-node cycle and a one-way leaf checked SCC grouping.
Both persisted graph summaries reproduced exactly from their TSV inputs.

The six ETS allocation sites in GHR are `cycle_fetch_cache.ex:10`,
`resource_store.ex:1299`, `read_cache.ex:245-246`, `open_issue_snapshot.ex:33`,
and `read_cache/metrics.ex:60` (paths relative to `src/lib/aiur/github`). These
are allocation sites, including a private per-cycle table, not a live table
census. Seven direct GenServer definitions are likewise not proof of seven
processes running on this machine.
