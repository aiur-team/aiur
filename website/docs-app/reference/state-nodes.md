# State nodes

Aiur separates the repository's tracked code from daemon-owned state. Everything the daemon owns for one repository lives in that repository's **state node**:

```text
~/.aiur/repo/<owner>/<repo>/
```

| Path | Owner and purpose |
| --- | --- |
| `latest/` | Aiur-managed warm clone of the configured base branch. |
| `builds/` | State-node [Build Order](/concepts/build-orders) packs, daemon status projections, and cross-boot build summaries. |
| `analytics/` | Materialized telemetry summaries, including `runs/<boot-id>/run-summary.json`. The raw telemetry stream stays in the daemon log root. |
| `meta/` | Executor findings at `findings.ndjson` and narrative retrospectives at `retros/<boot-id>.md`. |
| `executor/<run-id>/` | Created only when the hourly-retrospective helper first runs. It holds that run's machine-local timer state and history. |
| `base-record.json` | Provenance for the warm base checkout. |
| `.aiur-hex/`, `.aiur-mix/`, `.aiur-npm-cache/` | Repository-scoped package, compiler, and build-cache sidecars used while preparing workspaces. |

These paths are machine-local. Do not commit them, and do not expect copying a repository to copy its run state.

## What creates them

`aiur init` and base preparation create the core state tree. Analytics output and the Executor retrospective helper create regenerable local state when used, not git content.

The current handoff contract does not create `executor/handoff.md`. The durable narrative is `meta/retros/<boot-id>.md`, and the cross-machine artifact is the generated `docs/executor/open-findings.md` digest.

## Findings ledger

The `aiur-run` skill requires a durable handoff containing the accepted boundary, run identity, decisions, and remaining evidence. The hourly filing writes the narrative retrospective under `meta/retros/`. Deferred findings go through `aiur findings --record` into `meta/findings.ndjson`, which validates each record before appending it.

At least hourly, the Executor records a retrospective filing step: name the largest current wall-clock bottleneck, classify repeated failure patterns, make at most the evidence-supported systemic follow-ups, and preserve non-blocking findings in the ledger. This is operational state, not a ticket replacement.

Do not treat Git history or a stale dashboard view as current state.

| Command | Reads |
| --- | --- |
| `aiur findings` | The host-local ledger. |
| `aiur findings --unfiled` | Entries with no filed ticket. |
| `aiur findings --scope repo` | One scope, `aiur` or `repo`. |
| `aiur findings --digest` | The Markdown projection. |
