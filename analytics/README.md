# analytics — code and schema, not data

This directory holds the **code and schema** for Aiur's consolidated analytics.
It contains **no materialized outputs** — those live in the per-repo state
node (see "Outputs"). Telemetry is host- and boot-scoped and carries PIDs and
machine-local paths; committing derived datasets would produce huge,
conflict-prone, machine-specific diffs that rot as soon as retention prunes the
source.

## Contract — one reducer, one schema, two readers

- **One reducer.** `analytics/lib/analytics/reduce.py` is the canonical,
  pure, offline reducer: raw telemetry NDJSON → one schema'd per-boot summary.
  No network. (`--enrich` / `--github-events` is an explicit opt-in recorded in
  provenance.)
- **One schema.** `schema/run-summary.v1.json`. Every summary carries
  `{schema_version, boot_id, generated_at, source_files, source_bytes}` so a
  stale or partial summary is detectable and regenerable. Materialization is a
  **cache, not a source of truth** — `reduce` is idempotent and safe to re-run.
- **Two readers.** The dashboard (Elixir `Analytics.Presenter`, prior-boot
  reads) and Executors (`analytics/run-summary`, `analytics/build-report`) read
  the same JSON. An Executor never needs to know NDJSON record shapes or which
  of the four instance dirs is live.

## Outputs — per-repo state node

Materialized outputs live in the per-repo state node (`RepoBase.repo_path/1`,
`~/.aiur/repo/<owner>/<name>`), beside `builds/`:

```
~/.aiur/repo/<owner>/<name>/
├── analytics/
│   ├── runs/<boot-id>/run-summary.json     # one reduced dataset per boot
│   └── flakes.ndjson                       # reserved (flake-report; blocked)
└── builds/<slug>/build-summary.json        # rollup across every boot touching a member
```

`builds/<slug>/` is `RepoBase.builds_path/1` — this ticket lands its first real
application writer (`reduce --build <slug>` / the daemon's summary writer).
Build-order packs still load from the in-repo `.aiur/build_orders/*.json`
(`planning_source.ex`); the state-node `builds/<slug>/build-order.json` remains
Executor-placed.

## Tools

All tools are dependency-free (Python 3 stdlib only) and can be run from any
host with a checkout of this repository.

| Tool | Purpose |
|------|---------|
| `analytics/reduce` | Materialize run-summaries (and optional build rollups). Idempotent, cron/post-run safe. |
| `analytics/run-summary [<boot-id>|--current]` | One boot: dispatched/merged/open, CPU-hours, peak concurrency vs cap, wasted slot-hours, top-5 by cost (CPU-seconds). `--json` for machines. |
| `analytics/build-report <slug>` | **The retrospective number-fetcher.** Members merged/closed/open, wall-clock and active time across every boot touching a member, CI cycles, rework count, spend. Replaces hand-counting. |
| `analytics/cost-report` | Spend by model, agent family, ticket — pure wiring over `UsageAggregate` + `PriceTable` (offline mix task). Needs no new recording. |
| `analytics/flake-report` | **BLOCKED.** Not shipped: there is no durable flake database. Exits with an explicit explanation rather than a silent empty report. Ship after CI outcomes are recorded durably. |

## Running the tools

```sh
# Materialize every boot's summary into the state node, plus a build rollup.
analytics/reduce --build analytics-optimizations

# One boot, cheap (reads the materialized summary when present).
analytics/run-summary --current
analytics/run-summary <boot-id> --json

# Build retrospective numbers.
analytics/build-report analytics-optimizations
analytics/build-report analytics-optimizations --json
```

The daemon materializes summaries automatically on telemetry segment boundary
and on shutdown (best-effort, fail-open). Manual `reduce` runs are always safe
and regenerate any summary.

## Design notes

- **Cost means CPU-seconds** unless the report explicitly says otherwise
  (dollar spend is `cost-report`'s job). This matches the analytics design:
  "Cost per ticket" is CPU-seconds; adding money is an intentional extension.
- **Guarantees.** Parsing is line-isolated: a malformed line becomes a warning
  and never discards its neighbours. `reduce` is deterministic given the same
  inputs and `--now`; summaries are regenerable and provenance-identified.
- **Schema discipline.** `run-summary.v1.json` and `flake-report.v1.json` are
  the contracts. Bump a schema file (new version) rather than mutating a
  released one in place.
