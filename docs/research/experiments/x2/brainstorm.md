---
title: Experiments X2 - spec and store - Plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
date: 2026-10-09
epic: aiur-team/aiur#3774
area: EXP-X2
---

# Experiments X2 - spec and store - Plan

Requirements for the whole epic: [../requirements.md](../requirements.md) (the operator brief, committed verbatim).
Implementation plans for this area:

| Ticket | Plan |
|---|---|
| EXP-X2-1 component, spec v1, store, `list/show/create` | [plan-store.md](plan-store.md) |
| EXP-X2-2 metric-pack model and consumer packs | [plan-metric-packs.md](plan-metric-packs.md) |
| EXP-X2-3 built-in `delivery-speed` pack | [plan-delivery-speed-pack.md](plan-delivery-speed-pack.md) |
| EXP-X2-4 arms, frozen snapshots, checkpoints, `freeze` | [plan-baseline-freeze.md](plan-baseline-freeze.md) |

Base: `origin/main` at `1c4409e43` (2026-10-09); research branch `research/refactor-findings` at `6523d0f74`.

## Goal capsule

- **Objective.** One repo-agnostic contract that every other Experiments area builds on: what an experiment *is* (spec), where its metrics *come from* (metric packs), how its "before" data *survives* telemetry retention (frozen snapshots), where it *lives* (repo state node) and how a human or agent *drives* it (`aiur experiments list/show/create/freeze`).
- **Product authority.** Operator brainstorm of 2026-10-09 (requirements.md). Every product decision below marked `session-settled` comes from it and is not re-opened.
- **Open blockers.** None for planning. Cross-area: X1 must deliver the cohort attributes and the correct `pr_opened` timing before the `delivery-speed` metrics that need them can report `captured` (they report `not_captured` until then; see R12).

## Problem frame

Aiur records rich run telemetry, but nothing can say "this change made delivery faster" with evidence.
Today:

- No marker of version, experiment or cohort exists in telemetry or run summaries; only `aiur_version` in `src/lib/aiur/identity.ex:41` (the brief cites it; `Aiur.Identity` builds it from `Application.spec(:aiur, :vsn)`).
- Raw telemetry is pruned at 30 days or 64 MB (`src/lib/aiur/config/schema/observability.ex:18-19`). A before/after experiment whose "before" window ages out can never be re-analysed.
- Run summaries under `~/.aiur/repo/<o>/<r>/analytics/runs/` are a regenerable cache, "never a source of truth" (`src/lib/aiur/run_telemetry/summaries.ex:13`), are not produced for every boot, and some on this host are not valid JSON (grounding dossier).
- Every metric that exists is hard-coded to Aiur's own ticket lifecycle. A consumer repository (a repo Aiur works *on*) has no way to measure its own application stats.

## Actors

- **Operator** (human): reads experiments on the page (X5), creates one by hand from the CLI.
- **Experiment analyst agent** (X6): creates and amends specs, freezes windows, writes the report. Drives everything through the CLI, never through files.
- **Automatic trigger** (X3): creates before/after experiments on a release or a tagged-epic merge.
- **Stats engine** (X4): a pure consumer of arms and observations.
- **Consumer repository maintainer**: declares metrics for their own application, with no Aiur code change.

## Product Contract

### Key decisions

- **KD1 (session-settled: operator).** Two experiment kinds, one spec: a *before/after line* `{type, ref, time}` and *A/B cohorts* (predicates over the cohort attributes X1 records). No third kind in v1.
- **KD2 (session-settled: operator).** PR and implementation speed metrics ship as a built-in pack, not as hard-coded behaviour. A consumer repo adds metrics without an Aiur change.
- **KD3 (session-settled: Executor call-out).** Each experiment's baseline is frozen when the experiment is created, so retention cannot delete the "before" window.
- **KD4 (session-settled: operator).** Experiments is a standalone component on the MP-R1 map (`components.json`, declared facades, component-owned child specs).
- **KD5 (decided here).** The state node is the source of truth: `~/.aiur/repo/<owner>/<repo>/experiments/`, beside `analytics/` and `builds/` (`RepoBase.repo_path/1`, `src/lib/aiur/repo_base.ex`). Not a git-tracked file: experiments are per-installation evidence, and the analyst agent must not need a PR to record a spec. A spec can be imported from or exported to a JSON file (`create --from`, `show --json`) for review or sharing.
- **KD6 (decided here).** Consumer metric packs are git-tracked files in the consumer repo (`.aiur/experiments/packs/*.json`), read from the default-branch base checkout (`RepoBase.base_path/1`), never from an agent workspace. Reason: a metric definition is code-like and reviewable; reading only the base checkout means an agent's unmerged branch cannot change what is measured.
- **KD7 (decided here).** A frozen snapshot holds the **raw per-unit observations** plus a summary, not only a summary. Reason: X4 needs samples for Mann-Whitney U and bootstrap CIs; a summary-only freeze would make the frozen window un-testable. Ticket-level data is small (hundreds of rows); a hard cap (R10) bounds the worst case.
- **KD8 (decided here).** The "after" window is protected too: a checkpoint worker appends observations for every active experiment as they arrive, so a long after-window cannot be pruned either. The after window is frozen when it closes.
- **KD9 (decided here).** Pre-registration is recorded, not enforced. After the baseline is frozen, a change to metrics, direction, min samples or windows is accepted but journaled as a post-registration amendment, which the report must show (X6). Reason: refusing edits would push people to abandon and recreate, which hides the history.
- **KD10 (decided here).** Unit-to-arm assignment belongs to X2, not X4. X2 owns the spec semantics (which window, which cohort, which units straddle the change); X4 receives already-assigned arms and stays a pure statistics library.
- **KD11 (decided here).** All writes go through the daemon (one writer process); the CLI is a control-RPC client like `aiur analytics`. No second writer, no file locking.

### Requirements

Spec

- **R1.** A spec names: id, title, hypothesis, owner, status, origin (manual / release / epic_merge / analyst), design (kind + kind fields), metrics (each with expected direction and optional per-metric min samples), default min samples per arm, windows, unit filters, stratification keys, tags, notes.
- **R2.** A before/after design names the change line: `type` (release, tag, commit, epic_merge, merge, config, manual), `ref`, `time`. For `tag` and `commit`, a missing `time` is resolved from the base checkout's git history; for other types `time` is required.
- **R3.** An A/B design names two or more cohorts, each with an id, label and a predicate over cohort attributes, plus one control cohort. Predicates use a closed operator set (`eq`, `neq`, `in`, `prefix`, `exists`, `all`, `any`, `not`). A unit that matches more than one cohort is excluded and counted as `ambiguous`.
- **R4.** Windows: before/after has `before` and `after`; A/B has `observation`. Defaults: before = 14 days ending at the change; after = open-ended from the change until concluded. A window longer than telemetry retention is allowed; its coverage is reported (R11).
- **R5.** Units that start before the change and finish after it (straddlers) are excluded by default and counted; a spec may opt in to `assign_by: finish`.
- **R6.** Default stratification for ticket-unit metrics is `complexity`, so like is compared with like.
- **R7.** Status is one of `draft`, `active`, `concluded`, `abandoned`. A derived phase (`awaiting_change`, `collecting`, `window_closed`) is computed from time and never stored.

Store

- **R8.** Every stored file carries `schema_version`. A reader accepts the current and the previous version and upgrades on read; a file with a newer version is read-only, and writes are refused with a message naming the version.
- **R9.** Every mutation appends to a per-experiment journal (created, amended with field diff, status change, frozen with sha256). The journal is append-only.
- **R10.** A frozen snapshot is immutable: written once, sha256 recorded in the journal, file mode read-only. Re-freezing a window writes a new revision and journals the reason; the old revision stays. A snapshot above 50,000 observations is refused with a clear error rather than truncated silently.

Metric packs

- **R11.** Every metric reports coverage for the requested window: `captured`, `partial` (data starts after the window start, e.g. pruned), `not_captured` (the source does not record it yet) or `unavailable` (pack source missing). A metric never reports zero for missing data.
- **R12.** Built-in pack `delivery-speed` carries the operator's four groups (flow, review/rework, throughput/capacity, cost/quality), all enabled by default. Metrics whose capture X1 has not landed report `not_captured`.
- **R13.** A consumer pack is declarative JSON with four source kinds: `event_interval` (time between two topic matches per unit), `event_count` (matches per unit or per period), `ndjson` (a file of observations the consumer's tooling appends) and `script` (an argv command, no shell, that prints observations for a window). No Aiur code change is needed.
- **R14.** Topic-based consumer metrics see only events published after the pack is registered; Aiur journals the declared topics (unit key, time, declared attributes only) so they outlive the in-memory bus.

CLI

- **R15.** `aiur experiments list [--status s] [--json]`, `show <id> [--json]`, `create --from <file|->` or the quick line form `create --title t --line <type>:<ref>[@<time>] --metric <pack>/<metric>[:<direction>]...`, `freeze <id> [--window before|after|observation] [--reason r]`. Exit codes follow the existing CLI (`0` ok, `1` refused, `64` usage).
- **R16.** `create` of a before/after experiment freezes the before window in the same call (KD3) unless `--no-freeze` is given; output says what was frozen and its coverage.

Cross-area contract (aligned with the X3, X4 and X5 drafts on the same branch)

- **R19.** A spec may carry a `key`; `create` with an existing key returns the existing experiment (X3 creates automatically and must be idempotent).
- **R20.** Annotations (deploys, confounders, unit exclusions, notes) are an append-only list per experiment, written by X3 and X6 and read by X4.
- **R21.** Each metric declares a `kind` (`duration`, `count`, `binary`, `rate`, `bucketed`); duration units still open at freeze are kept as censored rows, so slow tickets are not dropped from the baseline.
- **R22.** X4 receives one flat, hashed input file per analysis (`report/analysis-input.json`), never the internal snapshots.

Component

- **R17.** One `components.json` entry `experiments` (layer 3, optional) with declared facades; required dependencies only at its own layer or lower; telemetry is an optional dependency.
- **R18.** A capability `experiments` (and `experiments.metric_packs`) reports available / degraded / unavailable through the existing provider registry.

### Success criteria

- An analyst agent can create the #3755 experiment, freeze its baseline, and `show --json` it, with no hand-edited file.
- After the raw telemetry for the before window is pruned, `show` still reports the same baseline medians and sample counts, byte-identical to the day it was frozen.
- A fixture consumer repo with one `.aiur/experiments/packs/app.json` (an `event_interval` metric and a `script` metric) produces observations, with zero Aiur code change.
- `scripts/check-components.py` passes with the new `experiments` entry; no allowlist growth.
- X3, X4, X5 and X6 can each name the facade function they call (see the facade in [plan-store.md](plan-store.md) §4).

### Scope boundaries

In scope: spec, store, metric-pack model, built-in pack, snapshots, checkpoints, CLI verbs above, component entry, docs.

Out of scope (owned elsewhere):

- Capture of cohort attributes and fixing `pr_opened` (X1).
- Creating experiments on release / epic merge (X3); X2 only provides `create/1` with an `origin`.
- Statistics, verdict labels, power (X4).
- The page (X5); X2 only publishes a PubSub topic and read functions.
- The report text and the analyst skill (X6); X2 reserves `report/` in the layout.

Deferred (YAGNI): multi-repo experiments, more than one change line per experiment, sequential/Bayesian designs, a GUI spec editor, remote/hosted storage.

### Assumptions

- **A1.** X1 adds a `cohort` map to each ticket record in the reduced dataset and run summary (`aiur_version`, `backend`, `model`, `epic`, `feature_tags`, `config_hash`, `tags`), plus a correct `pr_opened` timestamp. X2's telemetry adapter is the only place that reads these field names.
- **A2.** Experiment volume is small: tens of experiments, hundreds to low thousands of observations each.
- **A3.** The daemon is running whenever experiments are created or frozen (same as `aiur analytics`).

## Approaches considered

1. **Spec + store in the state node, packs as behaviours plus declarative JSON (chosen).** Built-in packs are Elixir modules behind one behaviour; consumer packs are JSON interpreted by four generic source adapters.
2. **Everything in Python next to `analytics/reduce`.** Reuses the reducer and its run-summary schema. Rejected: the page, the CLI and the daemon checkpointer are Elixir; a Python store would need a second writer and the component checker does not cover `analytics/`.
3. **Specs committed in git (like Build Order packs in `.aiur/build_orders/*.json`).** Reviewable and shareable. Rejected as the source of truth: the analyst agent would need a PR per amendment, frozen baselines (megabytes of observations) would bloat the repo, and consumer repos would get Aiur evidence in their history. Kept as import/export (KD5).
4. **Challenger: snapshot raw telemetry segments instead of observations.** Maximum fidelity, any future metric recomputable. Rejected for v1: boot groups are 18-258 MB on this host; a frozen copy per experiment would exceed the 64 MB retention budget it is meant to escape. Recorded as an open question.

## Open questions for Kevin

- **Q1.** Should a frozen baseline also keep the raw telemetry segments it came from (tens to hundreds of MB each), so a metric invented later can be computed retroactively? Recommendation: no for v1; observations of all enabled metrics are frozen, which covers every metric that exists at creation.
- **Q2.** Should consumer `script` metrics run automatically in the daemon (checkpointer), or only on an explicit `freeze`/`show`? Recommendation: automatic, with the same trust as `hooks.*` (repo config the operator already trusts), run only from the base checkout with a timeout.
