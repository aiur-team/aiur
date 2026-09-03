# Build Orders

A Build Order turns a large feature into typed members, lanes, phases, dependencies, complexity, and optional icons.

<img src="/images/dashboard/build-orders-dark.png" alt="Build Order graph of a 42-member pack: four lane columns across the top with per-lane completion, four wave rows down the left, and dependency edges drawn between member cards in done, active and blocked states">

A real 42-member pack, four lanes wide and four waves deep, part way through execution. A graph this dense
is easy to look at and hard to read, so:

| Where | What it tells you |
| --- | --- |
| Lane headers | Members and completion for each lane. Lanes progress independently, so an uneven spread across them is normal rather than a fault. |
| Wave rows | How wide the front is at each depth. This pack is 5, 8, 10, then 19 — the shape of a dependency graph that opens up once its keystone lands. |
| Card badges | The tracker number, complexity, and percent complete for one member. |
| Edges | Dependencies. A member with many inbound edges is a bottleneck worth dispatching early. |
| Card tone | Done, active, and blocked. Most of wave 4 reads blocked here because its dependencies have not landed yet, which is the graph working, not a stall. |

The wave counts are the useful part when you are judging a pack before you run it. A first wave far wider
than the second usually means members were grouped by topic rather than by dependency, and the fan-out
will not survive contact with the scheduler.

## Pack contents

| File or field | Purpose |
| --- | --- |
| `.aiur/build_orders/<slug>.json` | Writable workspace mirror discovered by the daemon. |
| `build-order.json` | Members, lanes, phases, dependencies, complexity, and icons. |
| `status.json` | Current execution state. |
| `tickets/<ID>.md` | Draft member contract before tracker promotion. |

The canonical state-node copy lives at `~/.aiur/repo/<owner>/<repo>/builds/<slug>/`.

| Pack location | Visible to Aiur? |
| --- | --- |
| Active workspace mirror | Yes. |
| Repository state node | Yes. |
| `docs/` only | No. |
| Another inactive branch only | No. |

## The Build Order page

| Surface | Shows |
| --- | --- |
| `/build-orders` | Discovered catalog. |
| `/build-orders/:root_number` | One root's phases, lanes, graph, members, usage, and analytics. |
| `aiur build-orders [<root>]` | The same projection in a terminal. |
| `--json` | Machine-readable Build Order rows. |

On the catalog, ticket, epic and wave counts remain numeric when resolution succeeds, including a real `0`. A count that could not be resolved never renders as `0` or as a bare dash—it names its cause instead:

| Cell | Meaning | What to do |
| --- | --- | --- |
| `Budget exhausted` | The planning query budget or a local GraphQL hold blocked the read. Shows the reset time when the hold reports one. | Wait for the reset, or raise `tracker.github.planning_page_budget` / `planning_call_budget`. |
| `Rate limited` | The tracker rate limited the read. Shows the reset time when reported. | Wait for the reset; reduce concurrent agents if it repeats. |
| `Timed out` | The request exceeded its deadline. | Usually transient; it retries on the next labelled read. |
| `Unreachable` | The connection was refused or dropped. | Check network reachability to the tracker—not latency. |
| `Not authorized` | The credential was missing or rejected. | Check the configured GitHub token. |
| `Unreadable response` | The response did not match the expected shape. | Likely an Aiur or tracker schema change; report it. |
| `Partial read` | The read succeeded but hit Aiur's own planning page limit before every member. This is an Aiur bound, not a tracker fault. | Raise `planning_page_budget`. |
| `Unresolved` | The failure could not be classified. | No cause is claimed on purpose—a wrong reason is worse than none. |

These states are intentionally not estimates. `aiur build-orders --json` reports the same cause as `count_resolution_failure`, with `count_resolution_reset_at` when a reset horizon is known.

## The repository state node

Aiur separates the repository's tracked code from daemon-owned state under `~/.aiur/repo/<owner>/<repo>/`.

| Path | Holds |
| --- | --- |
| `latest/` | Aiur-managed warm clone of the configured base branch. |
| `builds/` | State-node Build Order packs, daemon status projections, and cross-boot build summaries. |
| `analytics/` | Telemetry summaries, including `runs/<boot-id>/run-summary.json`. |
| `meta/` | Executor findings at `findings.ndjson` and narrative retrospectives at `retros/<boot-id>.md`. |

These paths are machine-local. Do not commit them, and do not expect copying a repository to copy its run state.

`aiur init` and the first run create this state as needed. Aiur does not create `executor/handoff.md`: the durable narrative is `meta/retros/<boot-id>.md`, and the shareable artifact is the generated `docs/executor/open-findings.md` digest.

## Executor handoff and findings

| Durable record | Location or command |
| --- | --- |
| Accepted boundary, run identity, decisions, evidence | Executor handoff. |
| Hourly retrospective | `meta/retros/` under the repository state node. |
| Deferred finding | `aiur findings --record` into `meta/findings.ndjson`. |
| Current bottleneck | Named in the hourly filing with evidence-supported follow-up. |

Git history and an old Dashboard capture are not substitutes for current Build Order state.
