---
title: Automatic experiments (EXP-X3) - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
epic: aiur-team/aiur#3774
area: x3
---

# Automatic experiments (EXP-X3) - Plan

Requirements for the part of the Experiments epic (#3774) that creates
before/after experiments without a person asking. The operator's decisions in
`docs/research/experiments/requirements.md` (the brief) are settled. This run
was unattended: in-the-weeds choices are decided below with reasons, and only
real operator questions are left under "Open questions for Kevin".

## Goal Capsule

- **Objective.** Three kinds of "line" create a before/after experiment
  automatically: an Aiur version bump, a release of the managed repository, and
  the merge plus go-live of a feature epic that carries a measure tag. The
  analyst agent is asked to pre-register each one, and asked again to write the
  report when enough data exists.
- **Product authority.** Kevin (operator). Brief of 2026-10-09.
- **Open blockers.** None. The interfaces this area needs from X2, X4 and X6
  are named under "Assumed interfaces". They are requests to those areas, not
  blockers for this plan.

---

## Product Contract

### Problem frame

Today a before/after comparison exists only when someone writes one by hand
(`docs/measurements/2026-07-30-ci-test-path.md` and similar). Nobody remembers
to capture the baseline before the change lands. Telemetry retention (30 days /
64 MB, `src/lib/aiur/config/schema/observability.ex:18-19`) then deletes it.
The first planned experiment (#3755 optimistic start) shows the risk: its
baseline must be frozen before #3763 merges.

Automatic lines fix this. But a line on every daemon deploy would bury the
signal. The aiur-on-aiur daemon restarts many times a day from `main`.

### Actors

- **A1 Operator** (Kevin, or a consumer-repo user): tags an epic, or cuts a
  release. Reads the experiment page.
- **A2 Daemon**: detects lines, creates experiments, freezes baselines, manages
  windows, and emits events.
- **A3 Executor**: receives the wake. Dispatches or runs the analyst agent.
- **A4 Analyst agent** (X6): pre-registers the hypothesis and writes the report.

### What counts as a line (decided)

| Line source | Fires when | Never fires on |
| --- | --- | --- |
| `aiur_version` | The daemon boots with a different **base semver** (`major.minor.patch`, prerelease and build suffix removed) than the last boot recorded for this repository state node. | A restart on the same version; a nightly within the same base (`0.0.10-nightly.abc` to `0.0.10-nightly.def`); the first boot ever (nothing to compare). A downgrade is recorded as a rollback, not as a new experiment. |
| `repo_release` | A new tag on the managed repository's remote matches `release_tag_pattern` (default `v*`, semver only). | Prerelease tags (by default); a tag within `release_min_interval_days` (default 7) of the previous release line; a tag whose semver equals an `aiur_version` line from the last 14 days. That last rule makes aiur-on-aiur produce one experiment per release, not two. |
| `feature` | An epic with the measure label (default `experiment:feature`) has all its sub-issues closed, at least one merged, nothing new added for `feature_quiet_hours` (default 6), and the merge is **live**. | An epic whose sub-issues are all closed as not-planned (the experiment is cancelled). A daemon restart alone. |

**"Live" for a feature line** (`feature_live_signal`, default `auto`):

- `daemon_boot`: the first daemon boot whose build contains the last member's
  merge commit. `auto` picks this when the daemon is built from the managed
  repository itself (aiur-on-aiur).
- `merge`: the last member merge time. `auto` picks this for every other
  repository, because Aiur cannot see a consumer's deploy.
- `release`: the first `repo_release` tag that contains the merge commit. A
  consumer picks this by hand when they deploy by release.

If the live signal does not arrive within `live_signal_max_wait_hours`
(default 72), the line falls back to the merge time. The experiment carries a
`live_signal_fallback` annotation.

### Lifecycle (decided)

```text
feature:  armed --(last member live)--> collecting --(sample guard met | max window)--> report_due --> reported (X6)
              \--(all not-planned | label removed before line)--> cancelled
version / release:  created at line --> collecting --> report_due --> reported
```

- **Arming** happens when the measure label is first seen, which is usually long
  before the line. The experiment exists from that moment. Its baseline is frozen
  at once, and the analyst is asked to pre-register the hypothesis while no
  "after" data exists yet. This is the honest order. It is also the only order
  that survives retention.
- **Before window.** Default 14 days. For version and release lines it ends at
  the line, and it is clipped at the previous line of the same source, so it
  measures only the previous version. For feature lines it ends at the **first
  member merge**. The time between the first merge and the line is a rollout
  window and is excluded from both sides.
- **After window.** Starts at the line. Default length 14 days. If the sample
  guard is not met, it extends in 7-day steps up to `after_max_days` (42). It
  is truncated by the next line of the same source or by a rollback.
- **Sample guard.** Uses the spec's `min_samples` and X4's sample status. When
  the guard is met, the experiment moves to `report_due`. When the maximum
  window ends first, it moves to `report_due` with reason `insufficient_data`,
  and the report then says "not enough data". It never says nothing.
- **Baseline freezing.** The baseline is frozen when the experiment is created
  (version or release) or armed (feature). A feature experiment freezes again
  at its first member merge, so the before window is complete. Freezing never
  depends on retention keeping the data until report time.

### Noise rules (decided)

- No experiment per daemon deploy or config change. Each boot whose source SHA
  differs from the previous boot is written to a **deploy ledger**. The
  analyst reads it as confounder evidence. The deploy ledger never creates an
  experiment.
- Lines that fall inside another experiment's windows are added to that
  experiment as **concurrent-change annotations**. They are not suppressed.
- Each auto experiment has an idempotency key (`auto:version:<semver>`,
  `auto:release:<tag>`, `auto:feature:<epic>`). Restarts, replays and
  double detection never create a duplicate.
- Every notification (pre-register, report due, cancelled) fires once per
  transition, from a durable latch, in the same way as `Aiur.BuildProgress`
  milestones.
- When capture is off (`observability.telemetry_enabled: false`), no experiment
  is created. The daemon logs the skip once per line.

### Requirements

- **R1** The daemon records every boot to a deploy ledger under the repository
  state node: time, boot id, Aiur version, base semver, source SHA (when the
  dev launcher's `AIUR_BUILD_STAMP` gives it), and the dirty flag.
- **R2** A base-semver change between consecutive ledger entries creates one
  `aiur_version` experiment. A decrease is recorded as a rollback.
- **R3** New semver tags on the managed repository's remote create
  `repo_release` experiments. The rules in "What counts as a line" apply. Tag
  detection uses git on the warm clone and costs no GitHub API budget.
- **R4** An epic carrying the measure label is armed as a `feature` experiment.
  Its baseline is frozen and pre-registration is requested at arming time.
- **R5** A feature experiment's line is set when the "What counts as a line"
  conditions hold. The line uses the configured live signal and the 72-hour
  fallback.
- **R6** After-window extension, truncation and the sample guard move each
  auto experiment to `report_due` exactly once. The move gives the reason
  `guard_met`, `insufficient_data` or `truncated`.
- **R7** The daemon publishes `system.experiment.<id>.preregister`,
  `.report_due` and `.cancelled` events. The Executor wake bindings include
  them, so the Executor or the analyst flow (X6) is woken.
- **R8** All behaviour is configured under `experiments.auto` and on by
  default. Each source can be turned off. Every field is generic: label name,
  tag pattern, windows, metric packs. Nothing is hard-coded to aiur-team/aiur.
- **R9** Auto experiments use the default metric pack (`delivery`, X2) unless
  config names others. Consumer packs flagged for auto use are added.
- **R10** The experiment page and CLI (X5) show for each auto experiment: the
  line source, the line evidence (tag, version, epic + merge SHA + live
  signal), the window bounds, and the status.

### Acceptance examples

- **AE1** Restarting the daemon five times on 0.0.9 creates no experiment.
  The deploy ledger gains five rows.
- **AE2** Upgrading from 0.0.9 to 0.0.10 creates `auto:version:0.0.10`. Its
  before window is clipped at the 0.0.9 line, and its baseline is frozen in the
  same boot.
- **AE3** Tagging v0.0.10 on aiur-team/aiur after the daemon booted 0.0.10
  creates no second experiment. The tag is added as evidence to the existing
  one.
- **AE4** Adding `experiment:feature` to #3755 before #3763 merges arms
  `auto:feature:3755` and freezes the baseline the same hour. When the last
  member merges and the next daemon boot contains it, the line is set to that
  boot.
- **AE5** A feature experiment with 9 "after" tickets after 42 days goes to
  `report_due` with reason `insufficient_data`.
- **AE6** A consumer repo that tags v2.3.0 and v2.3.1 three days apart gets one
  experiment. v2.3.1 is annotated as a concurrent change.

### Scope boundaries

- **In:** line detection, the deploy ledger, auto spec creation through X2,
  baseline freeze calls, window and status management, the sample-guard check
  (calling X4), wake events and bindings, config, and docs.
- **Out (other areas):** the experiment spec and store (X2), statistics (X4),
  the page (X5), the analyst skill and the report (X6), and metric capture (X1).
- **Out (non-goals):** cohort/A-B auto creation (cohorts are created by hand or
  by the analyst); Linear epics (the line-source behaviour allows a later
  adapter; v1 reads GitHub sub-issues only); measuring consumer production
  deploys outside git tags.

### Key decisions

- **KD1 Base semver, not vsn string or deploy.** It removes nightly and restart
  noise and needs no new release machinery.
  (session-settled: user-directed: "NOT every daemon deploy")
- **KD2 Git tags, not the GitHub Releases API, for `repo_release`.** A
  `ls-remote` on the warm clone is free, works with any tracker, and also
  covers repos that tag without publishing a Release.
- **KD3 Arm at tag time, set the line at go-live.** Pre-registration and the
  baseline happen before the change exists. Contamination and retention loss
  are both avoided.
- **KD4 Before window ends at the first member merge.** Partial rollout of a
  feature must not count as baseline.
- **KD5 A label marks a measured feature, not the Features registry.** Epics
  like #3755 are plain parent issues with sub-issues and no `build-order`
  label. A label works in any GitHub repo and is visible on the issue.
- **KD6 Events plus wake bindings, not tickets, for notification.** Filing
  issues automatically spends API budget and needs labels that differ per repo.
  X6 decides whether a wake becomes an analyst run or a ticket.
- **KD7 Deploys are annotations.** This keeps "no experiment per deploy" while
  the analyst still sees every deploy that could confound a window.

### Assumed interfaces (requests to other areas)

- **X2 (spec + store).** A facade `Aiur.Experiments` with:
  - `create(spec)`, idempotent on `spec.key`;
  - `freeze_baseline(id, window)`, callable more than once, which keeps every
    snapshot;
  - `update(id, changes)` for windows, status and line evidence;
  - `annotate(id, annotation)`;
  - `list(filter)`.

  The spec carries `kind: :line`, `line: %{source, at, evidence}`,
  `windows: %{before, after, excluded}`, `metric_packs`, `min_samples`,
  `status`, and `key`. Storage lives under the repository state node
  (assumed `experiments/`).
- **X4 (stats).** `sample_status(experiment)` returns, for each primary
  metric, `before_n`, `after_n`, `needed_n` and `guard_met?`.
- **X6 (analyst).** Consumes the `system.experiment.*` events. Owns how a wake
  becomes a pre-registration or a report.
- **X1 (capture).** Optional. An `aiur_version` attribute on each ticket record
  lets windows be checked against what actually ran.

### Open questions for Kevin

- Label name for a measured feature: `experiment:feature`. Recommendation:
  keep it. It is namespaced away from `agent:*` dispatch labels.
- Should the daemon auto-file a GitHub issue for each `report_due`, so the
  fleet can dispatch the analyst? Recommendation: no. Use events and wakes now.
  Let X6 add a ticket path only if the Executor misses wakes.
- Should `repo_release` lines be on by default for consumer repos?
  Recommendation: yes, with the 7-day minimum interval. Consumers who release
  daily can turn it off.

---

## Sources

- `src/mix.exs:7` version `0.0.9` (single source); `packaging/npm/aiur-cli/package.json:3`
  matches; tags `v0.0.1`..`v0.0.8`; `.claude/skills/release/SKILL.md` (bump, then tag,
  then release); `.github/workflows/release-npm.yml` (stable on a `v*` tag, nightly
  `<vsn>-nightly.<sha>`).
- `src/lib/aiur/identity.ex:41` reads the Application vsn; `src/lib/aiur/boot.ex` (run id per BEAM).
- `scripts/aiurdev` writes `AIUR_BUILD_STAMP` (`source_sha`, `dirty`, `built_at`) in the release dir.
  No Elixir code reads it today.
- `src/lib/aiur/build_order/catalog_store.ex:228-250` sub-issue edges in `ResourceStore`;
  webhook deposits at `src/lib/aiur/events/github_webhook/deposit.ex:334`.
- `src/lib/aiur/recent_merge.ex` (merge commit SHA and `aiur/<n>` ticket link);
  `src/lib/aiur/recent_merge_store.ex`.
- `src/lib/aiur/build_progress.ex:140-160` durable milestone latch, then `Alerts.emit_system`;
  `src/lib/aiur/executor_bindings.ex` wake allowlist.
- `src/lib/aiur/repo_base.ex:621` warm clone fetch (branch only, no tags today).
