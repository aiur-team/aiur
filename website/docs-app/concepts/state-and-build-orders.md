# State nodes and Build Orders

Aiur separates the repository's tracked code from daemon-owned state. The per-repository state node is:

```text
~/.aiur/repo/<owner>/<repo>/
```

| Path | Owner and purpose |
| --- | --- |
| `latest/` | Aiur-managed warm clone of the configured base branch. |
| `builds/` | Runtime Build Order packs and their status projections. |
| `meta/findings.ndjson` | Executor-written deferred-findings ledger. Create `meta/` when filing it. |
| `base-record.json` | Provenance for the warm base checkout. |
| `.aiur-hex/`, `.aiur-mix/`, `.aiur-npm-cache/` | Repository-scoped package, compiler, and build-cache sidecars used while preparing workspaces. |

These paths are machine-local. Do not commit them, and do not expect copying a repository to copy its run state.

The current release does not create `analytics/` or `executor/` beneath this node. Analytics writes `telemetry.ndjson` beside the configured daemon log. `meta/findings.ndjson` is the narrow exception: until [#1464](https://github.com/aiur-team/aiur/issues/1464) lands, the Executor writes that ledger directly and `aiur findings --unfiled` is unavailable. In particular, `~/.aiur/repo/<owner>/<repo>/executor/handoff.md` is not a current storage contract. [#1495](https://github.com/aiur-team/aiur/issues/1495) tracks that proposed layout.

## Build Orders

A Build Order is a planning pack that the dashboard discovers from the state node. A canonical pack lives under:

```text
~/.aiur/repo/<owner>/<repo>/builds/<slug>/
  build-order.json
  status.json
  tickets/<ID>.md
```

`build-order.json` supplies members, lanes, phases, dependencies, complexity, and optional icons. The Build Order page renders the discovered catalog, then shows phases and lanes as derived views. Draft members use their `tickets/<ID>.md`; after promotion, the tracker owns the ticket state and labels.

The daemon reads only the state-node copy. A pack left in `docs/`, or committed only on a branch, is invisible to the dashboard until an Executor places it under `builds/` in the configured state node. A completed planning handoff includes confirming that the Build Order page renders the pack and its members.

## Executor handoff and findings

The `aiur-run` skill requires a durable handoff containing the accepted boundary, run identity, decisions, and remaining evidence. It currently uses the run's research or handoff branch for that material, not a state-node `executor/handoff.md` file. Deferred findings are filed separately in `meta/findings.ndjson`. Do not treat Git history or a stale dashboard view as current state.

At least hourly, the Executor records a retrospective filing step: name the largest current wall-clock bottleneck, classify repeated failure patterns, make at most the evidence-supported systemic follow-ups, and preserve non-blocking findings in the ledger. This is operational state, not a ticket replacement.
