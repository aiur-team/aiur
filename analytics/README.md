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

GitHub `pr.opened` anchors use `created_at`, then the event timestamp.
`pr.merged` uses `merged_at`, then `closed_at`, then the event timestamp.
Regenerate existing summaries with `analytics/reduce --all`, supplying the original
`--github-events` inputs if used, to pick up fixes.

## Outputs — per-repo state node

Materialized outputs live in the per-repo state node (`RepoBase.repo_path/1`,
`~/.aiur/repo/<owner>/<name>`), beside `builds/`:

```
~/.aiur/repo/<owner>/<name>/
├── analytics/
│   ├── runs/<boot-id>/run-summary.json     # one reduced dataset per boot
│   ├── tickets/<ticket>.json               # durable cross-launch ticket facts
│   ├── tickets/.history/                   # up to five terminal-record versions
│   ├── ledger-cursor.json                 # offsets and sanitized lifecycle evidence
│   └── flakes.ndjson                       # reserved (flake-report; blocked)
└── builds/<slug>/build-summary.json        # rollup across every boot touching a member
```

`builds/<slug>/` is `RepoBase.builds_path/1` — this ticket lands its first real
application writer (`reduce --build <slug>` / the daemon's summary writer).
Build-order packs still load from the in-repo `.aiur/build_orders/*.json`
(`planning_source.ex`); the state-node `builds/<slug>/build-order.json` remains
Executor-placed.

## Tools

The Python tools are dependency-free (Python 3 stdlib only) and can be run from
any host with a checkout of this repository. `cost-report` is the exception: it
delegates to an offline Elixir mix task over `UsageAggregate` + `PriceTable`,
so it needs the Elixir toolchain (`mise`/`mix`) and a checkout of `src/` — not
just the `analytics/` directory. It still needs no new recording: it reads the
usage-aggregate checkpoint and price table that the daemon already maintains.

| Tool | Purpose |
|------|---------|
| `analytics/reduce` | Materialize run-summaries (and optional build rollups). Idempotent, cron/post-run safe. |
| `analytics/ledger-backfill --since DATE` | Rebuild durable ticket facts from retained launches; print observed-milestone coverage. |
| `analytics/run-summary [<boot-id>|--current]` | One boot: dispatched/merged/open, CPU-hours, peak concurrency vs cap, wasted slot-hours, top-5 by cost (CPU-seconds). `--json` for machines. |
| `analytics/build-report <slug>` | **The retrospective number-fetcher.** Members merged/closed/open, wall-clock and active time across every boot touching a member, CI cycles, rework count, spend. Replaces hand-counting. |
| `analytics/cost-report` | Spend by model, agent family, ticket — pure wiring over `UsageAggregate` + `PriceTable` (offline mix task; needs the Elixir toolchain + `src/` checkout, unlike the dependency-free Python tools). Needs no new recording. |
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

## Tests

The Python suite is stdlib `unittest`. Run it from the repository root with the
package on the path:

```sh
PYTHONPATH=analytics/lib python3 -m unittest discover -s analytics/tests -t analytics
```

CI runs this same command in the `analytics` job of `.github/workflows/ci.yml`,
so a regression in the reducer fails the build rather than passing silently.


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

## Statistics core

`analytics.stats` supplies experiment primitives without a runtime dependency:
Hyndman-Fan type-7 descriptives, Mann-Whitney U, Hodges-Lehmann/Moses shift
intervals, Cliff's delta, permutation and BCa bootstrap inference, Fisher exact,
Newcombe proportion differences, and conditional exact Poisson rate ratios.
Rank shifts and Cliff's delta use B minus A; count differences and rate ratios
use group 1 versus group 2. Inference results name their method. U uses exact
integer DP without ties up to `n1*n2 = 2500`, then a tie/continuity-corrected
normal approximation. Moses intervals follow the same cutoff; normal intervals
are approximate, and insufficient samples for the requested coverage give
unbounded endpoints. `min_achievable_p` assumes untied observations.

Sampling uses our PCG32 stream; `seed_from(*strings)` hashes length-framed UTF-8
parts with SHA256 (documented byte order in `stats/rng.py`). Permutation callers
supply a null-centered contrast; two-sided p counts absolute extremeness with
`(b+1)/(m+1)`. Bootstrap draws each group independently, optionally within fixed
strata, and shares draws across all supplied statistics. Degenerate jackknives
fall back to percentile intervals. Bootstrap `mc_se` is the Monte Carlo error
of the bootstrap mean, not uncertainty in interval endpoints.

The committed reference fixture in `tests/fixtures/stats/goldens.json` was
produced independently by `generate_goldens.py` with Python 3.12, NumPy 2.1.3,
SciPy 1.14.1, statsmodels 0.14.4 and R 4.5.0. To regenerate deliberately, install
those reference tools in a separate environment and run
`python analytics/tests/fixtures/stats/generate_goldens.py`. CI reads the JSON
using only stdlib unittest; it never runs the generator. Exact p-values are
checked to `1e-9`, special functions to `1e-10` relative error, and bootstrap
endpoints to 2% of the fixture's pooled range (20,000 PCG draws versus 100,000
independent reference draws). R confidence goldens use achievable coverages;
R warns and reduces coverage when a requested small-sample interval is impossible.

## Durable ticket ledger

`analytics/reduce --ledger` also writes `analytics/tickets/<ticket>.json` in
the state node. The daemon requests this on segment materialization, shutdown,
and PR-facts appends. `--telemetry-glob 'PATH/**/telemetry.ndjson*'` adds retained
launches to the ledger without changing the run-summary input scope.

```sh
analytics/ledger-backfill --since 2026-09-15 --repo owner/name \
  --telemetry /path/to/retained/logs --state-node /path/to/state-node
```

Records follow `schema/ticket-record.v1.json`: attempts carry their dispatch-time
run context, cohort fields become `mixed` when attempts disagree, and every
milestone has an observed/derived/unavailable status and source. Pre-v3 events
are marked `pre_x1`; missing cohort attributes are `unknown`. Missing dispatch
times are never inferred from a PR. No prompts, bodies, comments or command text
are retained. Metric definitions belong to the experiment metric pack.

`ledger-cursor.json` stores byte offsets and projected lifecycle evidence so
retention or a deleted launch file cannot erase facts already materialized.
Do not delete it when clearing raw logs. Writes are atomic and serialized;
unchanged records keep their timestamps. A changed terminal record keeps its
previous version in `.history/`, capped at five per ticket. A repo-timeline
revert updates `facts.reverted_by` when `revert_of` matches the merge SHA.

Consumers use `Aiur.RunTelemetry.Ledger.get(ticket)` and
`list(window: {from, to}, cohort: %{backend: "claude"})`. Windows select the
record's last event, inclusively; the facade returns decoded string-keyed JSON
without deriving facts. Disabled capture returns `{:error, :disabled}`.
Corrupt records are logged and skipped when listing.
