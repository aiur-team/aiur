# Build Orders

A Build Order is a planning pack that describes a large feature as typed work. It supplies members, lanes, phases, dependencies, complexity, and optional icons. Aiur discovers it first from the active workspace and then from the state node.

## How a pack becomes a Build Order

A publisher writes the workspace mirror at `.aiur/build_orders/<slug>.json`. The daemon's canonical projection lives under the repository state node:

```text
~/.aiur/repo/<owner>/<repo>/builds/<slug>/
  build-order.json
  status.json
  tickets/<ID>.md
```

`build-order.json` supplies the members, lanes, phases, dependencies, complexity, and icons. The Build Order page renders the discovered catalog, then derives phases and lanes as views. Draft members use their `tickets/<ID>.md`; after promotion, the tracker owns the ticket state and labels.

A pack left only in `docs/` is invisible. A pack on another branch is also invisible until that branch is the daemon's active workspace or the publisher writes its state-node copy. A completed planning handoff includes confirming the Build Order page renders the pack, phases, lanes, and members.

## The Build Order page

The dashboard shows the catalog at `/build-orders`, and one root's execution detail at `/build-orders/:root_number`. `aiur build-orders [<root>]` reads the same projection from the terminal, with `--json` for machine-readable rows. Each Build Order carries its own execution, usage, and analytics scope, so an Executor can read progress against a plan instead of scanning the whole fleet.

<img src="/images/dashboard/build-orders-dark.png" alt="Desktop Build Order graph with synthetic example member tickets">

## Executor handoff and findings

The `aiur-run` skill requires a durable handoff containing the accepted boundary, run identity, decisions, and remaining evidence. The hourly filing writes the narrative retrospective under `meta/retros/`; deferred findings go through `aiur findings --record` into `meta/findings.ndjson`. Do not treat Git history or a stale dashboard view as current state.

At least hourly, the Executor records a retrospective filing step: name the largest current wall-clock bottleneck, classify repeated failure patterns, make at most the evidence-supported systemic follow-ups, and preserve non-blocking findings in the ledger. This is operational state, not a ticket replacement.
