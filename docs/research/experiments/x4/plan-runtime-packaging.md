---
title: EXP-X4-6 Ship the stats engine with the release and run it from the daemon - Plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
origin: docs/research/experiments/x4/brainstorm.md
ticket: EXP-X4-6
complexity: 2
---

# EXP-X4-6 Ship the stats engine with the release and run it from the daemon - Plan

## Summary

Make `analytics/` (reducer and stats engine) available in every Aiur release so consumer
repos can run experiments, add a fail-open Elixir runner port that recomputes an
experiment's `result.json`, and register the `experiment-stats` component in
`components.json`.

## Problem Frame

The daemon finds `analytics/` only in the tracked repo's base checkout or the current
directory (`src/lib/aiur/run_telemetry/summaries.ex:183-190`). For a consumer repo that
directory does not exist, so the reducer — and the stats engine — silently do not run.
The release steps are `[:assemble, &Aiur.MixProject.copy_cli_launcher/1]`
(`src/mix.exs:202`); nothing copies `analytics/`. The operator requires the feature to
work for "a user of aiur that's working with it to develop another repo".

## Requirements

Brainstorm R14, KD1 (daemon never computes statistics), KD7 (MP-R1 fit).

## Key Technical Decisions

- **KTD1. Release copy step.** Add `copy_analytics/1` to the release steps: copies
  `../analytics/{lib,schema,reduce,run-summary,build-report,experiment-stats}` into
  `<release>/analytics/`. Tests and fixtures are not copied.
- **KTD2. Resolution order** in `Summaries.reduce_dir/1`: explicit override, tracked repo
  checkout (lets Aiur developers test unreleased changes), then the release copy, then
  cwd. The resolved directory is logged once at boot.
- **KTD3. Runner port** `Aiur.Experiments.StatsRunner.recompute(experiment_dir, opts)`
  runs `nice -n 10 <analytics>/experiment-stats --experiment-dir DIR` with a timeout
  (default 120 s), serialised by one process so two recomputes never overlap, fail-open
  (returns `{:error, reason}`, logs, never raises). Exit codes map to
  `:ok | {:error, :invalid_input} | {:error, :timeout} | {:error, :unavailable}`.
  X2/X5 decide *when* to call it (on experiment creation, on annotation change, on
  telemetry segment boundary for open experiments).
- **KTD4. Runner location.** `src/lib/aiur/experiments/stats_runner.ex`, inside the
  `experiments` component X2 creates. If X2's component entry does not exist yet, this
  ticket adds the path to it when it lands; the runner has no dependency outside
  `config` and `telemetry` (for `Summaries.reduce_dir/1`).
- **KTD5. Manifest.** Add component `experiment-stats` to `components.json`:
  `kind: package`, `status: experimental`, `paths: ["analytics/lib/analytics/stats/**",
  "analytics/experiment-stats", "analytics/schema/experiment-result.v1.json"]`,
  `requires: []`, facade = the CLI and `analytics.stats.analyze`. `scripts/check-components.py`
  only enforces ownership under `src/lib`, `packages`, `packaging` (`ROOTS`, line 17), so
  the entry is declarative plus glob-exists checked.
- **KTD6. python3 absent** → runner returns `{:error, :unavailable}`; the page (X5) shows
  "statistics unavailable: python3 not found", mirroring the GitHub budget broker message
  (`src/lib/aiur/github/budget.ex:80-82`).

## Implementation Units

### U1. Release copy step and resolution order

**Files:** `src/mix.exs`, `src/lib/aiur/run_telemetry/summaries.ex`,
`src/test/aiur/run_telemetry/summaries_test.exs` (extend or create).
**Test scenarios:**
- `reduce_dir(nil)` with no repo checkout and a fake release dir containing `analytics/`
  returns the release dir.
- With both present, the repo checkout wins.
- With neither, returns `{:error, :reduce_dir_not_found}` (unchanged behaviour).
**Verification:** after `aiurdev build`, the release tree contains
`analytics/experiment-stats` and `analytics/lib/analytics/stats/__init__.py`.

### U2. Runner port

**Files:** `src/lib/aiur/experiments/stats_runner.ex`, `src/test/aiur/experiments/stats_runner_test.exs`.
**Test scenarios:**
- Fixture experiment dir → `:ok` and `result.json` exists and parses.
- Fake tool that sleeps past the timeout → `{:error, :timeout}`, process killed (no orphan).
- Fake tool exiting 2 → `{:error, :invalid_input}` with stderr captured in the log.
- Two concurrent `recompute` calls on the same dir → second waits; tool invoked twice
  sequentially, never in parallel.
- `python3` not on PATH (override) → `{:error, :unavailable}`.

### U3. Component manifest and docs

**Files:** `components.json`, `website/docs-app/reference/experiment-statistics.md`
("Running it yourself" section: CLI, `--check`, where results live).
**Test scenarios:**
- `scripts/check-components.py` passes with the new entry (CI lint job).
- A glob that matches no file would fail (existing rule; no new test needed).

## Verification Contract

ExUnit tests for U1 and U2 pass; component check passes; a release built from the branch
runs `analytics/experiment-stats --check` on the fixture from a directory with no Aiur
checkout.

## Risks

- **Release size.** `analytics/lib` is small (under 300 KB); fixtures excluded.
- **Version skew.** A developer checkout of a newer `analytics/` beats the release copy
  (KTD2); the result records the engine version, so a skew is visible.

## Definition of Done

A consumer-repo daemon can recompute an experiment result; the component is in the
manifest; the methods page explains how to run it by hand.
