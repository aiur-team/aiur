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

<img src="/images/dashboard/build-orders-dark.png" alt="Desktop Build Order graph with synthetic example member tickets">

## Executor handoff and findings

| Durable record | Location or command |
| --- | --- |
| Accepted boundary, run identity, decisions, evidence | Executor handoff. |
| Hourly retrospective | `meta/retros/` under the repository state node. |
| Deferred finding | `aiur findings --record` into `meta/findings.ndjson`. |
| Current bottleneck | Named in the hourly filing with evidence-supported follow-up. |

Git history and an old Dashboard capture are not substitutes for current Build Order state.
