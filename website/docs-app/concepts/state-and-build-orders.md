# State nodes and Build Orders

Aiur separates the repository's tracked code from daemon-owned state. The per-repository state node is:

```text
~/.aiur/repo/<owner>/<repo>/
```

| Path | Owner and purpose |
| --- | --- |
| `latest/` | Aiur-managed warm clone of the configured base branch. |
| `builds/` | State-node Build Order packs, daemon status projections, and cross-boot build summaries. |
| `analytics/` | Telemetry summaries, including `runs/<boot-id>/run-summary.json`. |
| `meta/` | Executor findings at `findings.ndjson` and narrative retrospectives at `retros/<boot-id>.md`. |

These paths are machine-local. Do not commit them, and do not expect copying a repository to copy its run state.

`aiur init` and the first run create this state as needed. Aiur does not create `executor/handoff.md`: the durable narrative is `meta/retros/<boot-id>.md`, and the shareable artifact is the generated `docs/executor/open-findings.md` digest.

## Build Orders

A Build Order is a planning pack discovered first from the active workspace and then from the state node. Put a workspace copy at `.aiur/build_orders/<slug>.json`; its state-node files live under:

```text
~/.aiur/repo/<owner>/<repo>/builds/<slug>/
  build-order.json
  status.json
  tickets/<ID>.md
```

`build-order.json` supplies members, lanes, phases, dependencies, complexity, and optional icons. The Build Order page shows the catalog, phases, and lanes. Draft members use their `tickets/<ID>.md`; after promotion, the tracker owns the ticket state and labels.

A pack left only in `docs/` is invisible. A pack on another branch is also invisible until that branch is the daemon's active workspace or the publisher writes its state-node copy. A completed planning handoff includes confirming the Build Order page renders the pack, phases, lanes, and members.

## Executor handoff and findings

The `aiur-run` skill requires a durable handoff containing the accepted boundary, run identity, decisions, and remaining evidence. The hourly filing writes the narrative retrospective under `meta/retros/`; deferred findings go through `aiur findings --record` into `meta/findings.ndjson`. Do not treat Git history or a stale dashboard view as current state.

At least hourly, the Executor records a retrospective filing step: name the largest current wall-clock bottleneck, classify repeated failure patterns, make at most the evidence-supported systemic follow-ups, and preserve non-blocking findings in the ledger. This is operational state, not a ticket replacement.
