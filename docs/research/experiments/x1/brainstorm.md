---
title: Experiments X1 capture - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
epic: aiur-team/aiur#3774
area: EXP-X1 (capture)
grounded_on: origin/main 1c4409e43
---

# Experiments X1 capture - Plan

## Goal Capsule

- **Objective.** Every core metric of the Experiments brief can be computed from captured data, for every ticket, across daemon restarts and launches, sliced by generic cohort attributes, without re-deriving anything from logs or GitHub at report time.
- **Product authority.** Operator brainstorm 2026-10-09 (`docs/research/experiments/requirements.md`, area X2 commits it). The brief's decisions are carried forward here; they are not re-opened.
- **Open blockers.** None for X1. The open questions for Kevin (end of this document) have recommended defaults. Work can start on those defaults.

## Problem Frame

The analytics stack records lifecycle events (`src/lib/aiur/run_telemetry/lifecycle.ex:15-19`), but it was built to draw one run's timeline. It was not built to compare populations of tickets. Five gaps block experiments:

1. **Wrong or unread PR-open data.** The live presenter reads `work_ms` and `pr_merged` but never `pr_opened` (`src/lib/aiur_web/operator_control_center/analytics/presenter.ex:741-764`). The Python reducer stamps a GitHub `pr.opened` record with `merged_at` first (`analytics/lib/analytics/reduce.py:366-368`), so start→PR-open comes out equal to start→merge for every enriched merged PR. The Elixir path (`lifecycle.ex:533-535`) takes `created_at` correctly, so the two reducers disagree.
2. **Missing events.** No capture exists for PR ready-for-review, first review or approval, review rounds outside comment-driven rework, CI wait, blocker clearance, reverts, main-red, per-ticket tokens or spend, or the binding capacity gate (details in the coverage matrix).
3. **No cohort markers.** Dispatch records carry only complexity, worker host and retry attempt (`src/lib/aiur/orchestrator/dispatcher.ex:2667-2675`). No backend, model, effort, version, build SHA, config identity, epic or consumer tag exists in telemetry or run summaries. `aiur_version` exists only in `identity.ex:41`, and it is the mix version `0.0.9`, which does not identify a build.
4. **Cross-launch fragmentation.** Telemetry is written beside the launch log (`run_telemetry.ex:61-69`), and each background launch has its own root under `~/.aiur/logs/<launch-id>/`. The reducer reads one file (`summaries.ex:166-168`). Measured on 2026-10-09 (`20261009T121316Z-1381646`): 36 tickets merged in that launch's file, but only 20 have a `dispatch` record and only 26 a `pr_opened` record in the same file. The others started in earlier launches. Retention (30 days or 64 MB per file) then deletes the rest.
5. **The capture switch needs a clear framing.** `observability.telemetry_enabled` exists and defaults to true (`config/schema/observability.ex:17`, `config.ex:1025-1033`). `--debug` gates no capture: it gates debug log level and chat-pane recording only (`website/docs-app/reference/cli.md:50,63`). Two strings still describe telemetry as debug-only: `writer.ex:20` ("this debug-only path") and the eyebrow "Aiur / debug telemetry" in `run_telemetry/dashboard.ex:154`. The new GitHub fact reads cost API budget and have no switch yet.

## Actors

- **Operator (Kevin, or any consumer-repo user).** Wants to compare cohorts and before/after lines on the Experiments page.
- **Experiment analyst agent (X6).** Reads the ticket ledger and the repo timeline to write reports and annotate confounders.
- **Stats engine and spec store (X2, X4).** Read the ticket ledger as their only per-ticket input.

## Key Decisions

- **KD1 (session-settled: operator, brief).** Capture is on by default and the user can turn it off. `observability.telemetry_enabled` stays the master switch. No capture depends on `--debug`.
- **KD2 (session-settled: operator, brief).** Capture must be generic. Cohort attributes are generic keys (backend, model, effort, version, config identity, epic, feature, consumer tags). Delivery-speed milestones are recorded as generic, timestamped ticket facts. Metric definitions belong to X2's metric packs, not to capture.
- **KD3 (decided here).** The interface to every other area is a **durable per-ticket ledger** in the repo state node. It has one record per ticket, written by the reducer, stitched across all retained launch files and GitHub facts, and versioned by schema. Reason: per-boot run summaries cannot hold a ticket that crosses launches (gap 4), and retention deletes raw events. A ledger record is small, outlives retention, and is the natural unit for X2's frozen baselines.
- **KD4 (decided here).** GitHub is the source of truth for PR and repo facts: ready time, reviews, approvals, merge, size, epic parent, reverts, main CI state. We fetch these once, at a terminal event or on a periodic repo-timeline sync. We do not reconstruct them from live webhook and poll events, because the live normalizer drops approvals by design (`events/github_webhook/normalizer.ex:828-836`) and live events are lost while the daemon is down.
- **KD5 (decided here).** Daemon-only facts stay live lifecycle events: dispatch, cohort, state transitions, blocker clearance, CI results, usage, capacity binding. GitHub cannot see them.
- **KD6 (decided here).** Cohort attributes are recorded once per boot (a `run_context` record: version, build SHA, config hash, static tags) and once per attempt (the dispatch record: backend, model, effort, epic, feature, label tags, blockers). They are not copied onto every event. The ledger joins them. A ticket with attempts in different cohorts is marked `mixed`. It is never silently assigned to one cohort.
- **KD7 (decided here).** Historical backfill is in scope. The ledger can be rebuilt from every retained launch file plus GitHub, so experiment #3755's baseline can use tickets merged before X1 ships. Cohort fields that were never recorded read `unknown`. They are never guessed.
- **KD8 (decided here).** A separate sub-switch, `observability.capture_github_facts` (default true), gates only the GitHub fact reads, because they spend API budget. Turning it off leaves daemon-only capture running.

## Core metric coverage matrix

Status on `origin/main` 1c4409e43. "Ticket" names the EXP-X1 ticket that closes the gap.

| Metric (brief) | Captured today | Gap | Ticket |
|---|---|---|---|
| start→PR open | `dispatch` point; `pr_opened` live (`lifecycle.ex:489`) and enriched | presenter ignores `pr_opened`; Python reducer uses `merged_at` (`reduce.py:368`); cross-launch loss | X1-1, X1-5 |
| PR open→merge, start→merge | `pr_opened`, `pr_merged` | cross-launch loss | X1-1, X1-5 |
| blocker merge→dependent start | none (blockers absent from dispatch) | need dispatch-time blocker list and a `dependency_cleared` point; blocker merge times come from the ledger | X1-3, X1-5 |
| gaps between PRs | derivable from merge times | none after the ledger exists | X1-5 |
| PR ready→first review | none (`pr.ready_for_review` exists on the Exchange, `events/github_firehose.ex:421`, but the Writer does not subscribe; approvals are dropped) | GitHub PR facts | X1-4 |
| review rounds | `rework_start` only for comment-driven rework (`orchestrator/comment_wake.ex:1379-1385`) | observed state transitions (all writers) plus GitHub review counts | X1-3, X1-4 |
| rework time | partial (`rework_start`) | state transitions out of `rework` | X1-3 |
| CI wait | none (`ci-wait` is a state, `orchestrator/ci_lifecycle.ex:30`) | state transitions plus `ci_result` points from `ticket.*.ci.{passed,failed}` | X1-3 |
| merged/hour | `pr_merged` | cross-launch loss | X1-5 |
| agents vs cap, idle slot-hours | sampler `fleet_agents_*` (`analytics/lib/analytics/reduce.py:41-44`) | none | — |
| binding gate | only the host-pressure signal (`sampler.ex:349-367`) | sample `CapacityBinding.binding/2` kind (`orchestrator/capacity_binding.ex:59`) | X1-3 |
| spend and tokens per merged ticket | usage envelopes carry `tracker_identity` (`usage_aggregate/key.ex:66`); not in telemetry | `ticket_usage` point at terminal plus ledger join | X1-3 |
| main-red events | none | repo-timeline sync of base-branch status rollup | X1-4 |
| reverts | none | repo-timeline sync (revert commits and PRs mapped to the reverted ticket) | X1-4 |
| cohort: version | `identity.ex:41` mix vsn only | `run_context` with vsn, npm package version and `AIUR_BUILD_STAMP` `source_sha` | X1-2 |
| cohort: backend, model, effort | not recorded | dispatch attributes from `CodingAgent.backend_for/model_for/effort_for` | X1-2 |
| cohort: epic and feature tags | not recorded | `BuildOrder.Features.owner/1` at dispatch; GitHub issue parent in facts | X1-2, X1-4 |
| cohort: config hash | not recorded | `run_context` at boot and on `workflow_store:configuration` change | X1-2 |
| cohort: consumer tags | not recorded | static `observability.capture_tags` plus label prefixes | X1-2 |
| PR size (stratification covariate for X4) | none | GitHub PR facts (additions, deletions, files, commits) | X1-4 |

## Requirements

- **R1.** Every core metric in the matrix can be computed from ledger records alone. Each record says, per milestone, whether the value is `observed`, `derived` or `unavailable`, and why.
- **R2.** Start→PR-open uses the PR `created_at`, never `merged_at`. The presenter shows PR-open on the ticket timeline. The Python and Elixir reducers agree on a shared fixture.
- **R3.** Each ticket record carries its cohort: aiur vsn, build source SHA, config hash, backend, model, effort, complexity, epic, feature, consumer tags and start mode, for each attempt. A ticket-level cohort is set only when all attempts agree. Otherwise the ticket is `mixed`.
- **R4.** A repo timeline lists base-branch events in the window: non-ticket merges, reverts (with the reverted ticket when it can be resolved), main-red intervals, version or build changes, and config-hash changes. X6 uses it to annotate confounders. X3 uses it to detect version lines.
- **R5.** Capture is on by default. `observability.telemetry_enabled: false` stops all capture. `observability.capture_github_facts: false` stops only the GitHub reads. `--debug` changes no capture. Docs and UI never call telemetry "debug".
- **R6.** Capture is fail-open: a GitHub or ledger failure never blocks dispatch or merge. It is visible as a ledger warning and as `unavailable` fields.
- **R7.** Capture keeps the privacy contract in `lifecycle.ex:2-8`: no prompts, bodies, command text or comment text. Labels are captured only when they match the configured prefixes.
- **R8.** The ledger can be rebuilt (backfilled) from all retained launch telemetry files plus GitHub, for a given since-date.

## Scope boundaries

- **In:** event capture, cohort attributes, GitHub facts, repo timeline, ticket ledger, the capture setting, and fixing the pr_opened gaps.
- **Out:** metric definitions and packs (X2), experiment specs and frozen baselines (X2), automatic experiment creation (X3), statistics (X4), the page (X5), the analyst skill (X6), the #3755 baseline itself (X7). The `start_mode` attribute is reserved here; #3755 fills it.
- **Out:** sending telemetry anywhere off-host. Capture stays local to the state node.

## Component boundary (MP-R1)

All capture code stays inside the `telemetry` component (`component-map.md` row `telemetry`, paths `run_telemetry/**`). Its public facade is `Aiur.RunTelemetry` plus the on-disk ledger contract (`analytics/schema/ticket-record.v1.json`, `repo-timeline.v1.json`). Callers in the orchestrator call only `Aiur.RunTelemetry.Lifecycle.record/6` (the future `signal` port). The event-name registry stays in one module, so the MP-R1 move to `:telemetry` events is mechanical. The Experiments component (X2) depends on the ledger files and on the `Aiur.RunTelemetry.Ledger` read facade. It never reads raw NDJSON.

## Success criteria

- On a replay of the live launch files from 2026-10-05 to 2026-10-09, at least 95% of merged ticket records have start, PR-open and merge milestones `observed`. Today the figure is 20 of 36 for dispatch in one launch file.
- On the same window, the median start→PR-open differs from start→merge (the `reduce.py:368` bug is gone).
- A cohort split by backend (claude vs codex) needs no code beyond a filter on ledger fields.

## Approaches considered

1. **Enrich live events only.** Subscribe the Writer to more Exchange topics. This is cheap, but approvals are dropped upstream, events are lost while the daemon is down, and the work does nothing for cross-launch tickets. Rejected as the only mechanism.
2. **Reconstruct everything at report time from GitHub.** This is accurate for PR facts but blind to daemon facts (dispatch, cohort, CI wait, usage) and spends budget on every report. Rejected.
3. **Hybrid: live daemon facts, terminal-time GitHub facts, and a durable ledger (chosen).** Each fact comes from the source that sees it. A fact is fetched once per ticket. The ledger is the one stable interface for X2 to X7.

## Open questions for Kevin

- **Q1.** Should the ledger live under the repo state node (`~/.aiur/repo/<owner>/<name>/analytics/tickets/`) beside run summaries? *Recommendation: yes. This puts it in one place per repo, the same place X2 puts experiments.*
- **Q2.** Should reverts and main-red count all base-branch commits, including human and non-ticket ones? *Recommendation: yes, attributed where possible. Unattributed events go only into the repo timeline, as confounders.*
- **Q3.** Is a GraphQL budget of about one query per merged ticket, plus one repo-timeline query per hour, acceptable? *Recommendation: yes. `observability.capture_github_facts` turns it off.*

## Ticket map

| Ticket | Plan | Complexity | Blocked by (in area) |
|---|---|---|---|
| EXP-X1-1 PR-open fidelity | [plan-pr-opened-fidelity.md](plan-pr-opened-fidelity.md) | 1 | none |
| EXP-X1-2 Cohort attributes | [plan-cohort-attributes.md](plan-cohort-attributes.md) | 2 | none |
| EXP-X1-3 Daemon metric events | [plan-daemon-events.md](plan-daemon-events.md) | 2 | EXP-X1-2 (both change the lifecycle whitelist, the reducers and the schema version) |
| EXP-X1-4 GitHub facts and repo timeline | [plan-github-facts.md](plan-github-facts.md) | 3 | EXP-X1-6 (the sub-switch) |
| EXP-X1-5 Durable ticket ledger | [plan-ticket-ledger.md](plan-ticket-ledger.md) | 3 | EXP-X1-1 (both edit `reduce.py`); the ledger reads optional fields from X1-2, X1-3 and X1-4 and marks them `unavailable` until those land |
| EXP-X1-6 Capture setting | [plan-capture-setting.md](plan-capture-setting.md) | 1 | none |

Cross-area: X2 (store and frozen baselines) consumes the EXP-X1-5 ledger contract. X3 consumes `run_context` (EXP-X1-2) and the repo-timeline tags (EXP-X1-4). X4 consumes the ledger milestones and the PR-size covariates. X6 consumes the repo timeline and capture gaps. X7 (#3755 baseline) needs only EXP-X1-1 and EXP-X1-5 backfill. #3755 sets `start_mode`.
