---
title: EXP-X3-2 Version-bump and release lines - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
origin: docs/research/experiments/x3/brainstorm.md
epic: aiur-team/aiur#3774
---

# EXP-X3-2 Version-bump and release lines - Plan

## Summary

Add two line sources on the EXP-X3-1 foundation:

- **`AiurVersionLine`** fires once per base-semver change of the running
  daemon.
- **`RepoReleaseLine`** fires on new semver tags of the managed repository,
  read with git from the warm clone at no GitHub API cost.

The two sources dedupe against each other, so aiur-on-aiur gets one experiment
per release. Product Contract unchanged.

## Problem frame

Aiur's version lives in `src/mix.exs:7` (`0.0.9`), mirrored by
`packaging/npm/aiur-cli/package.json:3`. The release skill bumps `mix.exs`,
tags `vX.Y.Z`, then publishes. `release-npm.yml` publishes stable builds on
`v*` tags and nightlies as `<vsn>-nightly.<sha>`.

The aiur-on-aiur daemon runs from `main` and restarts often on the same vsn.
npm users can sit on the nightly channel. A consumer repository has its own
tags, which are a line for its own metric packs.

## Requirements

R2, R3, and AE1 to AE3, AE6 of origin.

## Key technical decisions

- **The version line is evaluated once, at boot.** It runs after
  `DeployLedger.record_boot`. It compares the current row's `base_version`
  with the previous row's:
  - higher: create the line;
  - lower: record a rollback;
  - equal, or `:unknown`: do nothing.

  The line time is the boot time, which is when the version went live.
  `before_floor` is the boot time of the most recent earlier base-version
  change, from the ledger.
- **A rollback** (lower base version) creates no experiment. It truncates the
  after window of the open `auto:version:*` experiment at the boot time,
  through EXP-X3-4's `truncate/3` (or `Experiments.update` until X3-4 lands),
  and annotates it with `rollback to <v>`.
- **The release source polls tags with git only.** It runs
  `git ls-remote --tags --refs origin` in the warm clone (`RepoBase.base_path`)
  every 60 minutes, and once at boot.
  - New refs that match `release_tag_pattern` and parse as semver are fetched
    by name with `git fetch origin tag <t> --no-tags`.
  - The line time is the tag's tagger date, or the commit date for
    lightweight tags.
  - Seen tags are kept in `<state node>/experiments/auto-release-seen.json`.
  - First run: every existing tag is marked seen and no line fires. This
    avoids creating history on install.
- **Filters, in order:**
  1. Prereleases are skipped unless `release_include_prereleases` is set.
  2. A tag older than 14 days at detection is marked seen with no line.
     This covers late fetches and bulk imports.
  3. A tag within `release_min_interval_days` of the previous release line
     becomes a concurrent-change annotation on that experiment.
  4. A tag whose base semver equals the semver of an `auto:version:*`
     experiment created within 14 days is attached as evidence to that
     experiment. No new experiment is created (AE3).
- **Dedupe works in both directions.** If the tag is seen first and the daemon
  boots the same version later, the version line finds
  `auto:release:<tag>` with the same semver and attaches instead. The Creator
  gains a `merge_into` lookup by semver.
- **Metric packs.** Version lines use `metric_packs` from config (default
  `delivery`). Release lines use the same list plus consumer packs that X2
  marks `auto: true`.

## Implementation units

### U1. AiurVersionLine

**Files:** `src/lib/aiur/experiments/auto/aiur_version_line.ex` (new), its
test.

**Test scenarios:**
- Covers AE1: five boots on 0.0.9 create no experiment.
- Covers AE2: a 0.0.9 boot then a 0.0.10 boot creates
  `auto:version:0.0.10`. Its `before_floor` is the 0.0.9 line, and its line
  `at` is the second boot.
- `0.0.10-nightly.a` to `0.0.10-nightly.b` creates nothing.
- `0.0.10-nightly.b` to `0.0.10` (stable) creates nothing, because the base
  is equal.
- `0.0.10` to `0.0.9` truncates and annotates the open `auto:version:0.0.10`
  experiment. No new experiment is created.
- The first-ever boot (an empty ledger) creates nothing.
- An `:unknown` vsn creates nothing.

### U2. RepoReleaseLine

**Files:** `src/lib/aiur/experiments/auto/repo_release_line.ex`,
`src/lib/aiur/experiments/auto/tag_reader.ex` (git calls behind a function
opt), tests.

**Test scenarios:**
- On first run, three existing tags are marked seen and no line fires.
- A new `v1.4.0` creates `auto:release:v1.4.0` at the tagger date.
- `v1.4.1-rc.1` is ignored by default.
- `v1.4.1` three days after `v1.4.0` annotates `auto:release:v1.4.0`
  (covers AE6).
- `release-2026` does not match `v*` and is ignored.
- A tag older than 14 days on detection is marked seen and creates nothing.
- If `ls-remote` fails (offline), the seen-state stays unchanged, a warning
  is logged once, and the next tick retries.
- If the warm clone is missing, the source reports `:unavailable` in
  `status/0` and does not crash.

### U3. Version and release dedupe

**Files:** `src/lib/aiur/experiments/auto/creator.ex` (the `merge_into`
semver lookup), tests in `creator_test.exs`.

**Test scenarios:**
- Covers AE3: version line 0.0.10, then tag v0.0.10 the next day, gives one
  experiment with both kinds of evidence.
- Tag v0.0.10 first, then boot 0.0.10, gives one experiment.
- Version line 0.0.10, then tag v0.0.10 20 days later, gives two experiments.
  The window is outside 14 days.

## Verification contract

- The unit tests above pass.
- On the runtime daemon, restarting on 0.0.9 adds a ledger row and no
  experiment.
- In a scratch repo, pushing a test tag creates exactly one experiment within
  one poll interval.

## Documentation

- Experiments concept page, section "Version and release lines": the base
  semver rule, nightlies, rollback, tag rules, min interval, and dedupe.
- `.claude/skills/release/SKILL.md`: one line saying a release creates an
  experiment automatically and that the baseline is frozen at the line.

## Risks

- **A consumer that tags very often.** The min interval prevents an
  experiment flood. `release_line: false` turns the source off.
- **Git credentials for `ls-remote`** on a private repo. These are the same
  credentials the warm clone's fetch already uses.
- **The version line depends on boot order.** It must run after
  `record_boot`. The supervisor runs the ledger task first; a test asserts
  this.

## Dependencies

EXP-X3-1 (in area). X2 facade (cross-area).

## Definition of done

U1 to U3 are merged with tests. Docs are shipped. The runtime daemon is
verified as in the verification contract.
