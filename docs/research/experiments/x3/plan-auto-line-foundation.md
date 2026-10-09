---
title: EXP-X3-1 Auto-line foundation and deploy ledger - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
origin: docs/research/experiments/x3/brainstorm.md
epic: aiur-team/aiur#3774
---

# EXP-X3-1 Auto-line foundation and deploy ledger - Plan

## Summary

Build the shared part of automatic experiments:

- the `experiments.auto` config;
- the `Aiur.Experiments.Auto` supervisor;
- the `Line` value and the `LineSource` behaviour;
- the idempotent `Creator`, which turns a line into an X2 experiment and
  freezes its baseline;
- the per-repository **deploy ledger**, which records every daemon boot.

The version, release and feature tickets (EXP-X3-2, -3) and the window manager
(EXP-X3-4) plug into this. Product Contract unchanged (see origin).

## Problem frame

No line exists today, and no record shows which version or build ran when.
`Aiur.Identity.instance_section/0` (`src/lib/aiur/identity.ex:41`) knows only
the live vsn. `scripts/aiurdev` writes `AIUR_BUILD_STAMP` (`source_sha`,
`dirty`, `built_at`) into the release dir, but no Elixir code reads it. Every
line source needs the same creation path: an idempotency key, the
telemetry-off skip, the baseline freeze, and cross-annotation of concurrent
lines. Keeping that path in one place stops three copies from drifting.

## Requirements

R1, R8, R9 of origin, plus the creation half of R2 to R5.

## Key technical decisions

- **Component placement.** The code lives in the `experiments` component that
  X2 adds to `components.json` (L3, optional), under
  `src/lib/aiur/experiments/auto/**`.
  - Required dependencies: kernel (`Aiur.Git`, `Aiur.JsonStore`,
    `Aiur.Jsonl`), config, event-bus, identity, and workspace (for
    `Aiur.RepoBase` state paths).
  - Optional dependencies: github (EXP-X3-3), orchestration
    (`RecentMergeStore`), and telemetry.
  - `Aiur.Experiments.Auto` is the only facade. Every other module is
    private.
  - Child specs are owned by the component and returned by
    `Aiur.Experiments.Auto.child_specs/1`. The composition root
    (`src/lib/aiur.ex`, near the `recording?` children at line 512) adds them
    only when `recording?` holds and `experiments.auto.enabled` is true.
- **The deploy ledger is append-only NDJSON.** Its path is
  `<state node>/experiments/deploys.ndjson`, through a new
  `RepoBase.experiments_path/1` if X2 has not already added one.
  - Each row holds `boot_id`, `at`, `aiur_version`, `base_version`,
    `source_sha|null`, `dirty|null`, `launcher` (`dev|release`), and
    `instance_id`.
  - It is written once per boot, before any line source runs.
  - Rows are capped at 5,000; the oldest are dropped first. One row per boot
    is small.
- **The build stamp reader is a pure function.** It reads
  `$AIUR_RELEASE_DIR/AIUR_BUILD_STAMP`. A missing or unreadable stamp gives
  `nil` values, never a fabricated SHA. Mirror the `dev_launcher?` detection
  in `src/lib/aiur/upgrade.ex`.
- **Base semver** is parsed with `Version.parse/1`, after which the `pre` and
  `build` parts are dropped. An unparseable vsn gives `:unknown`, and no
  version line fires.
- **The Creator is the only writer of auto experiments.** For a `%Line{}` it:
  1. checks `observability.telemetry_enabled`;
  2. builds the spec (key, source, windows from config, metric packs,
     `min_samples` default from X2);
  3. calls `Aiur.Experiments.create/1`, which is idempotent on key;
  4. calls `freeze_baseline/2` on the before window;
  5. annotates every other open experiment whose windows contain `line.at`
     ("concurrent change: <source> <ref>").

  A key that already exists returns `{:ok, :exists}` and changes nothing.
- **Config.** Add `Aiur.Config.Schema.Experiments.Auto`, embedded under X2's
  `experiments` schema. If X2 lands later, this ticket adds a minimal
  `experiments` embed in `src/lib/aiur/config/schema.ex` next to the existing
  `embeds_one` list (lines 53-73). The fields and defaults are in the origin
  "Lifecycle" and "Noise rules" sections:
  - `enabled`, `version_line`, `release_line`
  - `release_tag_pattern`, `release_include_prereleases`,
    `release_min_interval_days`
  - `feature_label`, `feature_live_signal`, `feature_quiet_hours`,
    `live_signal_max_wait_hours`
  - `before_days`, `after_days`, `after_step_days`, `after_max_days`
  - `metric_packs`

## Implementation units

### U1. Config schema

**Files:** `src/lib/aiur/config/schema/experiments_auto.ex` (new),
`src/lib/aiur/config/schema.ex`, `.aiur/examples/config.example`,
`src/test/aiur/config/schema/experiments_auto_test.exs` (new).

**Approach:** Use an embedded Ecto schema with validations: positive day
counts; `after_max_days >= after_days`; `feature_live_signal` in
`auto|merge|release|daemon_boot`; a non-empty label; a tag pattern without
whitespace.

**Test scenarios:**
- An empty config gives every default, all sources on.
- `after_max_days: 7` with `after_days: 14` is rejected with a field error.
- `feature_live_signal: deploy` is rejected.
- `enabled: false` parses.

### U2. Line value, LineSource behaviour, build stamp, deploy ledger

**Files:** `src/lib/aiur/experiments/auto/line.ex`,
`src/lib/aiur/experiments/auto/line_source.ex`,
`src/lib/aiur/experiments/auto/build_stamp.ex`,
`src/lib/aiur/experiments/auto/deploy_ledger.ex` (all new);
`src/lib/aiur/repo_base.ex` (`experiments_path/1`, and `experiments` added to
`@state_entries`); tests under `src/test/aiur/experiments/auto/`.

**Approach:**
- `%Line{}` carries `source`, `key`, `at`, `evidence` (a map), and
  `before_floor` (the previous line of the same source, or nil).
- `LineSource` callbacks are `child_spec/1` and `describe/0` (for the page).
- `DeployLedger.record_boot/1` appends one row per boot.
  `DeployLedger.previous/1` returns the last row from an earlier boot.
  `DeployLedger.list/2` gives a time range to X6.

**Test scenarios:**
- A stamp with `source_sha=abc` and `dirty=no` gives `%{source_sha: "abc",
  dirty: false}`.
- No `AIUR_RELEASE_DIR` gives nil values.
- A garbage stamp gives nil values, not a crash.
- `"0.0.10-nightly.1a2b"` has base `0.0.10`; `"weird"` gives `:unknown`.
- Two boots write two rows in order. `previous/1` returns the first.
- A truncated last line (crash mid-write) is skipped when read, and the next
  append still succeeds.
- The 5,001st row drops the oldest.

### U3. Creator

**Files:** `src/lib/aiur/experiments/auto/creator.ex` (new),
`src/test/aiur/experiments/auto/creator_test.exs` (new).

**Approach:** Implement `create(line, opts)` as described in the key
decisions. Window math comes from config:

- before = `[max(at - before_days, before_floor), at)`;
- after = `[at, at + after_days)`;
- feature lines pass an explicit before window and an `excluded` rollout
  window (EXP-X3-3).

A function opt injects the X2 facade, so tests use a fake store.

**Test scenarios:**
- A new key calls create, then `freeze_baseline` with the computed before
  window, in that order.
- The same line twice calls create once and freeze once.
- With telemetry disabled, nothing is created; one log line is written per
  key, not per call.
- `before_floor` 5 days before `at` clips the before window to 5 days.
- An open experiment whose after window contains `at` receives one
  concurrent-change annotation. A closed (`reported`) one receives none.
- If X2 `create` returns an error, no baseline freeze is attempted and the
  error is returned. The caller retries on its next tick.

### U4. Supervisor and composition-root wiring

**Files:** `src/lib/aiur/experiments/auto.ex` (facade and `child_specs/1`),
`src/lib/aiur.ex`, `components.json` (paths and dependencies under the
`experiments` entry), `src/test/aiur/experiments/auto_test.exs`.

**Approach:** The supervisor starts `DeployLedger.record_boot` as a one-shot
task, then the enabled sources. Disabled config starts no children. The
facade exposes `status/0` (a source list with last-seen evidence) for X5 and
the CLI.

**Test scenarios:**
- `enabled: false` returns no child specs.
- `recording?` false adds no children; this is a test of the composition-root
  helper.
- The facade `status/0` lists the configured sources.
- The component checker passes. A private-module reference from outside
  fails, which is a fixture check in `scripts/components`.

## Verification contract

- `mix test src/test/aiur/experiments/auto src/test/aiur/config/schema/experiments_auto_test.exs`
  passes.
- After a dev daemon boot, the state node `experiments/deploys.ndjson` gains
  exactly one row, with the stamp's SHA.
- The `components.json` checker passes.

## Documentation

- `website/docs-app/reference/configuration.md`: an `experiments.auto` table.
- `website/docs-app/concepts/build-orders.md`: add `experiments/` to the
  repository state node table.
- The experiments concept page (X5/X2) gains an "Automatic experiments"
  section (origin "What counts as a line").

## Risks

- **X2's facade may land later.** The Creator takes the store as an injected
  module. The ticket is mergeable with a fake in tests and a no-op adapter
  that logs at runtime, until X2 lands.
- **Ledger growth.** One row per boot, capped at 5,000.

## Definition of done

U1 to U4 are merged with tests. Config docs are shipped. The deploy ledger is
populated on the runtime daemon after a restart.
