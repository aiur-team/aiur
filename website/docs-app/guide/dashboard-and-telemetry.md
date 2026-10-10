# Dashboard and run telemetry

When `server.port` (or CLI `--port`) is set, Aiur exposes:

- LiveView dashboard at `/` — active agents, logs, read-only per-agent log modal
  plus append-only Decision history and the 50 newest recent repository merges
- JSON API under `/api/v1/*` for operational debugging (read endpoints; agent-write
  endpoints are disabled unless `observability.dashboard_writable` is set)
- Read-only telemetry analytics at `/analytics` when the current run has a
  `telemetry.ndjson` input; this route uses the same dashboard basic auth,
  reducer, and self-contained renderer as the CLI artifact and is served with
  `Cache-Control: no-store`. Drag across any time chart to zoom the five
  time-series charts together; use Reset to return to the full selected range.

The endpoint serves packaged dashboard hooks, styles, fonts, logos, and provider icons from `priv/static` before router dispatch. Explicit allowlists keep the dashboard Basic Auth boundary intact: runtime assets revalidate, stable logo and font files use long-lived caching, and provider icons derive from the coding-agent registry.

Content-addressed layout vendor files remain on their verified router paths; vendor manifests, provenance, sources, and licenses are not exposed.

The Units catalog reconciles retained current-run membership with the latest fresh orchestrator snapshot. After a daemon generation change, current agents remain visible while membership catches up; counts are marked partial if that membership source is unavailable.

A periodic reconciliation also recovers agents that existed without a dispatch notification, so an unknown catalog is never presented as an exact zero.

The Units summary keeps progress useful while member weight facts catch up. If
some members have current facts, it shows the percentage derived from those
members and labels how many inputs are current. Expected post-restart catch-up
is marked as still settling; an unhealthy refresh is marked as degraded.

### Shared GitHub quota

GitHub-backed runs meter the shared agent credential's core and GraphQL budgets in the dashboard, including remaining units, reset times, rolling read/write attribution, and the top ticket consumer. Aiur raises an Executor alert at 10% remaining and pauses new dispatch until the affected window resets.

At zero, daemon requests are rejected locally and agent-launched `gh` commands wait on the recorded reset instead of retrying into the exhausted budget. Quota state that has not yet been observed fails open so startup is not blocked by a meter.

Aiur also coordinates request *shape* across all local instances that share a credential. A host-local SQLite broker at `~/.aiur/github-budget/` keys state by SHA-256 fingerprints, never the token or consumer identity itself. It enforces a shared requests-per-minute ceiling, total and endpoint-family in-flight ceilings, and jittered admission starts.

A primary exhaustion holds its resource globally; a secondary-limit response or `Retry-After` holds every consumer of that token, including separately started daemons and agent `gh` commands.

The broker is an optimization, not a dependency: on a box without `python3` the
broker cannot run, so metering fails open to unmetered requests (announced once
at boot) rather than failing every GitHub request.

The defaults are deliberately conservative and can be tuned per workflow:

```yaml
tracker:
  github:
    max_inflight: 4
    max_inflight_per_endpoint: 2
    requests_per_minute: 120
    stagger_ms: 75
```

When active consumers of the same token disagree, the broker uses the most
restrictive ceilings and the widest stagger observed in the preceding two
minutes. This prevents a permissive second instance from raising the shared
limit above another instance's configured safety boundary.

At startup Aiur installs an optional Executor-shell wrapper at `~/.aiur/bin/gh`. Put that directory ahead of the system `gh` in an Executor shell's `PATH` to share the same budget for direct CLI calls.

The wrapper fingerprints the `GH_TOKEN`, `GITHUB_TOKEN`, or `gh auth` credential it actually uses, so distinct daemon and Executor credentials never share a budget. Agent workspaces receive the wrapper automatically.

### Supervisor Decision API

The machine Decision API under `/api/v1/decisions` uses a dedicated bearer credential, not dashboard Basic Auth. Set `AIUR_SUPERVISOR_TOKEN` to at least 32 random bearer-safe bytes.

Generate one with `openssl rand -base64 32`, then put `AIUR_SUPERVISOR_TOKEN=<generated-token>` in `~/.aiur/.env` (global) or the repository `.env` (project-local); an already-exported value wins, followed by the global file and then the repository file.

A present non-empty short, whitespace-surrounded, or non-bearer-safe value aborts startup, while an absent or empty value leaves the API disabled. Keep the dashboard on loopback/private tunneling or terminate HTTPS before using the credential remotely.

Supervisor answers and revisions are disabled until their Decision kinds are
explicitly delegated:

```yaml
decisions:
  supervisor_allowed_kinds: [architecture]
  supervisor_allow_non_reversible: false
```

`human_required` remains absolute. Mutating enrich/decide/revise requests also require `observability.dashboard_writable: true`, an exact dashboard/loopback `Origin`, and `X-Aiur-Request: 1`.

See the [OCC-7 supervisor Decision API contract](https://github.com/aiur-team/aiur/blob/main/docs/operator-control-center/06-occ-7-supervisor-decision-api-contract.md) for routes, payloads, retry semantics, and audit guarantees.

## Run telemetry

Aiur records daemon-owned run telemetry by default. The daemon continuously records resource samples for itself, locally attributable ticket process trees, and the Executor process when it can be identified.

It also records sanitized ticket lifecycle boundaries such as dispatch, workspace setup, implementation, build/test, PR/review, pause/resume, and rework. Prompt text, command text, and output are never included.

To opt out, set `observability.telemetry_enabled: false` in your config; the
telemetry writer and sampler will not start and no file will be created. The
setting is read once at daemon startup — a restart is required to apply a change.

`--debug` (or config-level `debug: true`) controls **log verbosity and evidence
capture**, not whether telemetry is recorded.

The append-only schema-versioned stream is written beside `aiur.log` as
`telemetry.ndjson`. A default run therefore writes to:

```text
~/.aiur/logs/<session-id>/log/telemetry.ndjson
```

Each daemon start appends a restart marker with a new boot identity. Schema 1
readers keep valid records from every selected stream and report malformed lines,
unknown record kinds, unsupported future schemas, attribution gaps, and unavailable
platform metrics as warnings instead of discarding the rest of the run.

Before a new writer starts, Aiur prunes old **whole boots** from the stream.

The default retention window is 30 days and 64 MiB (`observability.telemetry_retention_max_age_days` and `observability.telemetry_retention_max_bytes`); these defaults retain useful cross-session Build Order history without allowing a long-running operator stream to grow indefinitely.

During a long-running daemon boot, the writer closes a telemetry segment and prunes at `observability.telemetry_retention_prune_interval_bytes`; it defaults to `max(max_bytes / 8, 1 MiB)` (8 MiB with the default cap).

Size is a whole-boot-segment target: if one segment alone exceeds it, Aiur keeps that segment intact rather than truncating lifecycle intervals mid-session.

From the repository root, generate the canonical analytics artifact from one file,
one session directory, or several session roots:

```bash
scripts/aiur-telemetry-dashboard \
  --input ~/.aiur/logs/20260711T120000Z-1234 \
  --input ~/.aiur/logs/20260711T160000Z-5678 \
  --output ./aiur-run.html
```

Passing the common `~/.aiur/logs` root recursively discovers every canonical telemetry stream beneath it.

Add `--repo owner/repo` to recover missing PR-open, trusted-comment, and merge anchors from GitHub at generation time; this optional enrichment reads `GITHUB_TOKEN`, and auth or network failures become visible report warnings rather than blocking local analytics.

Use `--review-resume-grace-seconds N` to tune when a trusted review comment with no observed rework/resume sequence is classified as broken.

The output is one self-contained HTML file with all normalized data, CSS, and
JavaScript inlined. It can be opened directly or served locally by any backend and
makes no view-time network requests. Run
`scripts/aiur-telemetry-dashboard --help` for the complete option list.

While Aiur is running with its browser dashboard enabled, `/analytics` renders the current canonical `telemetry.ndjson` through that same reducer and renderer. The Operations Dashboard links to it only when the input exists; debug-off runs instead show an explicit analytics-unavailable state.

The route accepts no input path parameter and is never browser-cacheable.

The daemon aggregate also records whole-host fleet and build-gate pressure on the normal sampling cadence: occupied agents, configured/max/effective capacity, active and queued builds, and the oldest live queue wait.

Fleet and build observations keep independent state and observation timestamps, so stale or degraded sources render as gaps instead of false zeroes.

The binding admission signal (which host-pressure gate is holding dispatch) and diagnostic load measurements ride along. Status names the CPU PSI threshold, or the load fallback where PSI is unavailable. A growing build queue alone does not hold dispatch.

Because reading the build gate scans its lock files, that probe runs on a reduced cadence and carries the last observation forward, so telemetry never disturbs a real build acquisition. `/analytics`, `aiurdev analytics` (including `--json`), and the self-contained HTML report expose the same pressure evidence.

This telemetry is measurement-only; it does not adapt `max_concurrent_agents` automatically.