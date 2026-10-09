---
title: EXP-X1-5 Durable ticket ledger - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
origin: docs/research/experiments/x1/brainstorm.md
ticket: EXP-X1-5
complexity: 3
---

# EXP-X1-5 Durable ticket ledger - Plan

## Summary

The reducer writes one durable, versioned record per ticket under the repo state node. It stitches the record across every retained launch telemetry file plus the GitHub facts, and joins in the cohort, milestones, quality flags and usage. A backfill command rebuilds the ledger for a since-date. This ledger is the single per-ticket input for X2 (spec and frozen baselines), X4 (stats), X5 (page) and X6 (analyst).

## Problem Frame

- Telemetry is written per launch, beside the launch log (`src/lib/aiur/run_telemetry.ex:59-69`). Background launches each get `~/.aiur/logs/<launch-id>/`.
- Materialization reduces one file (`src/lib/aiur/run_telemetry/summaries.ex:160-170`, `--telemetry <one file>`) into per-boot run summaries.
- Measured 2026-10-09 in launch `20261009T121316Z-1381646`: 36 merged tickets, 20 with `dispatch`, 26 with `pr_opened`. The rest started in earlier launches.
- Retention removes raw records after 30 days or 64 MB (`src/lib/aiur/config/schema/observability.ex:18-19`). Log roots can also be cleared (`scripts/aiurdev --clear`).
- An experiment's "before" window must survive all of this.

Requirements: R1, R3, R6, R8. Decisions KD3 and KD7.

## Key Technical Decisions

- **KTD1. Location and shape** (KD3). One file per ticket, `<state-node>/analytics/tickets/<ticket>.json`, written atomically (`reduce.py` already has `_atomic_write`). It validates against `analytics/schema/ticket-record.v1.json`. Reason: per-ticket files are small, diffable and cheap to rewrite, and they let X2 freeze a baseline by copying records.
- **KTD2. Record contents.**

  | Group | Fields |
  |---|---|
  | Identity | `ticket`, `repo`, `schema_version`, `generated_at`, `sources` (launch files, byte ranges, facts versions) |
  | `cohort` | Ticket-level: set only when all attempts agree on a key; otherwise `mixed: [keys]` |
  | `attempts[]` | `attempt_id`, `boot_id`, `dispatched_at`, `retry_attempt`, `backend`, `model`, `effort`, `complexity`, `tags`, `start_mode`, `blockers`; plus `run_context` (`aiur_vsn`, `build_sha`, `config_hash`, `capture_tags`) |
  | `milestones` | Each is `{at, status: observed\|derived\|unavailable, source}`: `first_dispatch`, `first_work`, `pr_opened`, `pr_ready`, `first_review`, `first_approval`, `merged`, `closed`, `blockers_cleared` (the latest blocker merge or `dependency_cleared`) |
  | `durations_ms` | Convenience only, computed from milestones: `ci_wait_total`, `rework_total`, `paused_total` |
  | `counts` | `rework_rounds` (`state_change` into `rework` after `pr_opened`), `changes_requested`, `ci_failures`, `dispatches`, `retries` |
  | `facts` | PR size, `merge_commit_sha`, `epic`, `reverted_by` (from the repo timeline) |
  | `usage` | Tokens and cost with `coverage` |
  | `quality` | `capture_partial` (attempts or events missing), `mixed_cohort`, `pre_x1` (before the schema-v3 capture), `warnings[]` |

  Metric *definitions* (which milestone pair makes "start→PR open") belong to X2's metric pack. The ledger only records facts with provenance (KD2).
- **KTD3. Input set.**
  - `analytics/reduce --ledger` takes `--telemetry-glob` (default: every `telemetry.ndjson*` under the configured logs root's launch dirs plus the current one), the state node, and the facts already present in those files.
  - The Elixir side passes the glob from `Aiur.LogFile` roots. Implementation detail deferred: the exact glob helper.
  - Records dedupe across files by `record_id` and `event_key` (`reduce.py:298-323`).
- **KTD4. When it runs.** The ledger is rebuilt for tickets touched since the last run, on the existing segment and shutdown materialization (`summaries.ex:100-170`, `Writer.terminate/2`), and on every `pr_facts` append. A full rebuild runs on demand. Reason: it reuses the existing trigger and needs no new scheduler.
- **KTD5. Immutability rule.** A record is rewritten while the ticket is open. After `merged` or `closed` it is rewritten only when new sources add facts. The old version moves to `tickets/.history/<ticket>.<generated_at>.json`, at most 5 kept. Reason: X2's frozen baselines can cite a version, and late facts (a revert) still land.
- **KTD5b. One canonical deriver: Python.** The live dashboard does not read the ledger in this ticket. X5 reads the ledger through `Aiur.RunTelemetry.Ledger` (an Elixir read facade: `get/1`, `list/1` by window or cohort filter, `schema_version/0`) that only decodes files. Reason: there is a single implementation of the milestone derivation, so no parity drift (compare EXP-X1-1 U3).
- **KTD6. Backfill** (KD7). `analytics/ledger-backfill --since 2026-09-01` reduces all retained launch files. With facts enabled it calls the daemon RPC `FactsCapture.capture/1` for merged tickets that lack `pr_facts`. Without the daemon, it calls the `GitHubFacts` query through a small CLI wrapper `aiur analytics facts <ticket>`. Pre-X1 tickets get `quality.pre_x1: true`, and missing cohort keys read `unknown`.

## Implementation Units

### U1. Ticket-record schema and pure builder

**Files:** `analytics/schema/ticket-record.v1.json` (new), `analytics/lib/analytics/ledger.py` (new: `build_ticket_record(events, run_contexts, facts, timeline) -> dict`), `analytics/tests/test_ledger.py`, fixtures `analytics/tests/fixtures/ledger/`.
**Test scenarios:**
- A ticket dispatched in launch A (Claude) and merged in launch B gives one record with `first_dispatch` from A, `merged` from B and `cohort.backend: "claude"`.
- A retry on Codex after Claude gives `cohort.mixed` containing `backend`, and both attempts listed.
- `pr_facts` present gives `pr_ready`, `first_review` and `first_approval` as `observed`, source `github`.
- Only `state_change` to `ci-wait` and back, at 10:00 and 10:20, gives `ci_wait_total = 1_200_000`.
- `state_change` into `rework` twice after `pr_opened` gives `rework_rounds: 2`.
- A repo-timeline revert whose `revert_of` equals the ticket's `merge_commit_sha` gives `facts.reverted_by`.
- A ticket missing `dispatch` gives `first_dispatch.status: "unavailable"` and `quality.capture_partial: true`.
- Output validates against the schema, and no body or free-text fields appear.

### U2. Multi-file reduce and the ledger command

**Dependencies:** U1.
**Files:** `analytics/lib/analytics/reduce_cmd.py` (`--ledger` and `--telemetry-glob`), `analytics/lib/analytics/sources.py` (multi-file glob, already the source abstraction), `analytics/ledger-backfill` (new entry script, matching `analytics/reduce`), `analytics/tests/test_sources.py`, `analytics/tests/test_ledger.py`.
**Test scenarios:**
- Two launch files with an overlapping carried `dispatch` give one dispatch after dedupe.
- An unreadable or truncated file gives a warning, and the other files are still reduced.
- `--since` excludes tickets whose last event is earlier than the since-date.
- A rerun with no new input leaves file mtimes unchanged (no-op).

### U3. Daemon integration

**Dependencies:** U2.
**Files:** `src/lib/aiur/run_telemetry/summaries.ex` (pass the glob and `--ledger` in `reduce_command/1`; add a `ledger_dir/0` path helper), `src/lib/aiur/run_telemetry/ledger.ex` (new read facade), `src/test/aiur/run_telemetry/summaries_test.exs`, `src/test/aiur/run_telemetry/ledger_test.exs`.
**Test scenarios:**
- `reduce_command/1` includes every launch file found under a temp logs root.
- `Ledger.list(window: {from, to})` returns decoded records, and a corrupt file is skipped and reported, not raised.
- Telemetry disabled means no ledger write, and the reads return `{:error, :disabled}`.

### U4. Backfill for #3755 and docs

**Files:** `analytics/README.md` (ledger section), `website/docs-app/concepts/build-orders.md` (the `analytics/` row at line 77 gains `tickets/` and `repo-timeline.ndjson`), and a CLI subcommand `aiur analytics facts` if the existing `aiur analytics` CLI module (`src/test/aiur/analytics_cli_test.exs` shows it exists) is the right home.
**Verification:** Run a backfill from 2026-09-15 on this host. The success criterion: at least 95% of merged tickets have `first_dispatch`, `pr_opened` and `merged` observed, for tickets inside retained launch files. Report the measured figure in the PR.

## Interfaces offered to other areas (contract)

- `analytics/schema/ticket-record.v1.json`, plus `Aiur.RunTelemetry.Ledger.get/1` and `list/1`. Additive fields are allowed within v1. Removing or renaming a field requires v2.
- X2 freezes a baseline by copying the matching records (or their hashes) into the experiment store at creation time (Executor call-out: retention).
- X7 can run `ledger-backfill` right away to capture the #3755 baseline before #3763 merges, even if EXP-X1-2 and EXP-X1-3 have not landed. Those records are marked `pre_x1`.

## Risks

- **Old launch files have broken JSON heads** (dossier note). Mitigation: the existing tolerant parser plus per-file warnings.
- **Large inputs** (tens of launch files, up to 258 MB each). Mitigation: an incremental mode that tracks per-file byte offsets in `<state-node>/analytics/ledger-cursor.json`. The materialize timeout (30 s, `summaries.ex:31`) applies only on shutdown; the async path has no timeout.
- **Ticket identifier collisions across repos.** These cannot happen, because the ledger is per state node, which is per repo.
