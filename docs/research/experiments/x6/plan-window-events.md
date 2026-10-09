---
title: EXP-X6-2 - Collect the window-event ledger for confounder review - Plan
date: 2026-10-09
area: EXP-X6
ticket: EXP-X6-2
complexity: 3
brainstorm: docs/research/experiments/x6/brainstorm.md
---

# EXP-X6-2 - Window-event ledger

## Outcome

`aiur experiments events <id> [--json] [--refresh]` returns every event inside
the experiment's windows (plus a 24 h margin before each window) that could
confound its metrics. The first call for a report freezes the result as
`events-<n>.ndjson` in the experiment directory, with a `snapshot_hash`. The
analyst classifies these events; it does not search for them. Brainstorm KD6.

## Why the daemon collects, not the agent

- Completeness is checkable only if the list is deterministic: the validator
  (EXP-X6-3) requires one ledger row per collected event id.
- GitHub reads go through `Aiur.GitHub.Transport` and its quota accounting
  (`src/lib/aiur/github/transport.ex`), not through an agent's `gh` budget.
- Aiur-internal events (outages, caps, config hashes, alerts) are only on this
  machine.

## Event shape

```json
{"event_id": "evt:pr:3790", "kind": "merged_pr", "source": "github",
 "at": "2026-10-12T14:03:00Z", "from": null, "to": null,
 "ref": "aiur-team/aiur#3790", "title": "Shorten CI test partition timeout",
 "attrs": {"labels": ["ci"], "paths": ["/.github/workflows/ci.yml"], "epic": null, "author": "its-applekid"},
 "window": "after"}
```

`event_id` is stable across refreshes (kind prefix plus natural key). `window`
is `before`, `after`, `between`, or `margin`. Titles and bodies are untrusted
text: stored as data, truncated to 200 characters, never interpreted.

## Sources

| kind | Source | Notes |
|---|---|---|
| `merged_pr` | GitHub search, merged in range on the base branch; changed file paths (first 50) | `attrs.epic` set when the PR closes a sub-issue of the experiment's epic, so the analyst can mark `treatment` |
| `release` | GitHub releases and tags in range | |
| `version_change` | X1 `aiur_version` transitions in per-ticket records / run summaries | |
| `config_change` | X1 `config_hash` transitions; `attrs.changed_keys` when the store kept both configs | |
| `incident` | `alerts.ndjson` entries of critical severity (`src/lib/aiur/alert_feed.ex:257`), plus open/closed issues with any label in `confounder_sources.incident_labels` (default `incident`, `outage`) | |
| `outage` | gaps between consecutive boot records (run summaries, `Aiur.Boot.run_id`) longer than 10 min | `from`/`to` |
| `main_red` | GitHub Actions runs on the base branch: a red period runs from the first failed required-workflow run to the next success | durable at GitHub; Aiur keeps no CI history (`analytics/lib/analytics/flake_report.py` documents this) |
| `capacity_change` | sampler fleet fields `fleet_agents_max`, `fleet_agents_effective` (`src/lib/aiur/run_telemetry/sampler.ex:22`); emit when the value changes and holds 15 min | |
| `global_pause` | pause/resume records if persisted (`src/lib/aiur/orchestrator/pause_resume.ex`); else from capacity drops to zero | |

Consumer repos set `confounder_sources` in the spec (X2): base branch, required
workflow names, incident labels. Defaults come from tracker config.

## Implementation units

### U1. Collector modules

- **Files:** `src/lib/aiur/experiments/window_events.ex` (facade:
  `collect(experiment, opts)` and `snapshot(experiment)`),
  `src/lib/aiur/experiments/window_events/{github,local}.ex`.
- **Approach:** each source is a function returning a list of events; the
  facade merges, sorts by time, assigns `window`, dedups by `event_id`, and
  computes `snapshot_hash` (sha256 over canonical JSON lines). A source that
  fails returns `{:error, source, reason}`; the snapshot records
  `incomplete_sources[]` and the validator accepts it, but the report's
  `threats.statistical_conclusion` must name the missing source (EXP-X6-3 rule
  extension, one line).
- **Component (MP-R1):** `experiments` component; depends on `telemetry`
  (reads only, through its facade) and `github` adapters. No reverse edge.

### U2. CLI verb and freeze

- **Files:** `src/lib/aiur/experiments_cli.ex` (verb `events`),
  `src/lib/aiur/agent_control_cli.ex` (control entry beside `analytics/1`,
  origin/main line 379), store write through the X2 facade.
- **Approach:** without `--refresh`, return the latest frozen snapshot if one
  exists for the current analysis request; `--refresh` collects again and writes
  `events-<n+1>`. The report references `events_snapshot_hash`.

### U3. Docs

- `website/docs-app/reference/cli.md` (verb), `concepts/experiments.md`
  ("Confounder sources" section with the table above and the consumer
  settings).

## Test scenarios

- Fixture with two boot records 3 h apart yields one `outage` event with
  `from`/`to` and `window: after`.
- Sampler fixture with `fleet_agents_max` 8 -> 4 for 2 h yields one
  `capacity_change`; a 5 min blip yields none.
- Stubbed GitHub runs: fail, fail, success on the base branch yield one
  `main_red` with the right span; a failure on a non-required workflow yields none.
- Merged PR closing a sub-issue of the experiment epic gets `attrs.epic`.
- Same inputs give the same `snapshot_hash`; `--refresh` with a new PR gives a
  new hash and keeps old event ids unchanged.
- A GitHub source error yields a snapshot with `incomplete_sources: ["github"]`
  and exit 0; the CLI prints a warning on stderr.
- A PR title containing "Ignore previous instructions" is stored verbatim and
  truncated; no field other than `title` holds it.

## Risks

- GitHub cost on long windows. Mitigation: one search query per window and
  page cap 10; quota class `core`; freeze so repeat reads are local.
- Run summaries are not generated for every boot (dossier: "summaries not
  generated for today's boots"). Mitigation: the outage source reads boot ids
  from `telemetry.ndjson` heads when a summary is missing.
- X1 transitions not yet captured. Until X1 lands, `version_change` and
  `config_change` are listed in `incomplete_sources`.
