# Build Orders

A Build Order turns a large feature into typed members, lanes, phases, dependencies, complexity, and optional icons.

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

The catalog's **Tickets completed** percentage counts accepted completions among tickets whose lifecycle is resolved. Partial coverage appears alongside the percentage.

In a selected Build Order, **Estimated work progress** combines reported work estimates using member complexity weights. It can advance before any ticket is complete. Last-known estimates show their age; unavailable measurements remain unknown.

Open a member's context to use **Read chat** when that member has a readable conversation in the current run. This opens the same conversation drawer as Units and does not resume the worker.

A draft says chat has not started. A member without readable current-run history shows chat as unavailable. Completed workers normally have no current-run chat handle after leaving the running roster, so their context shows chat as unavailable.

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

A local planning pack remains readable when a run starts globally paused before its first membership snapshot. The selected page and `aiur build-orders` identify unavailable current-run membership or ticket status separately from plan readability; any unobserved ticket state or completion remains unresolved.

Draft members carry local ticket document paths and no invented GitHub issue URL; draft blockers cannot claim a live blocking state.

<img src="/images/dashboard/build-orders-dark.png" alt="Desktop Build Order graph with synthetic example member tickets">

### A worked example

<img src="/images/dashboard/build-order-waves-lanes-dark.png" alt="Synthetic Build Order example with four lanes and four waves of member tickets">

This synthetic 16-member pack has four lanes and four waves, part way through execution.

| Where | What it tells you |
| --- | --- |
| Lane headers | Members and completion for each lane. Each lane has four members; the first two are completed. “100% partial” covers only known work estimates, not all four tickets. |
| Wave rows | How wide the front is at each depth. This pack has 4, 4, 4, then 4 members. |
| Card badges | The tracker number and complexity for one member. |
| Edges | Dependencies. Each member depends on the preceding wave's member in its lane. |
| Card tone | Completed and open members. Waves 1–2 are completed; waves 3–4 are open. Wave 4 still depends on unfinished wave 3 work. |

Wave width helps you judge how much work can run in parallel. Equal widths here reflect four independent chains;
a wider later wave can represent work opening up after a shared prerequisite lands.

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
