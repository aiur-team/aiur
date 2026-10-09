---
title: EXP-X1-2 Cohort attributes - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
origin: docs/research/experiments/x1/brainstorm.md
ticket: EXP-X1-2
complexity: 2
---

# EXP-X1-2 Cohort attributes - Plan

## Summary

Record generic cohort attributes at two levels, so experiments can slice A/B cohorts and before/after lines without re-deriving anything:

- **Per boot**, in a new `run_context` record, written at boot and again on each config change: aiur version, build source SHA, config hash, and consumer static tags.
- **Per attempt**, on the existing `dispatch` lifecycle point: backend, model, effort, epic and feature, label tags, blocker list, and start mode.

## Problem Frame

- Today the `dispatch` point carries only `outcome`, `complexity`, `worker_host`, `remote` and `retry_attempt` (`src/lib/aiur/orchestrator/dispatcher.ex:2667-2675`). A live record from 2026-10-09 confirms this.
- The `restart` record carries only the pid, the start time and `existing_records` (`src/lib/aiur/run_telemetry/writer.ex:127-132`).
- `Aiur.Identity.instance_section/0` (`src/lib/aiur/identity.ex:41`) reports the mix vsn `0.0.9`, which is the same for every build. The build's real identity is `source_sha=` in `AIUR_BUILD_STAMP` at the release root (`scripts/aiurdev:40,283-300`, `packaging/npm/aiur-cli/libexec/aiur-engine.sh:3827-3835`).
- Lifecycle metadata accepts only whitelisted scalar fields (`src/lib/aiur/run_telemetry/lifecycle.ex:21-47,230-234`). A list becomes `"unknown"`.

Requirements: R3, R5, R7 (brainstorm). Decisions KD2 and KD6.

## Key Technical Decisions

- **KTD1. Two levels, not every record** (KD6). The `run_context` kind holds boot-level fields. The dispatch point holds attempt-level fields. The ledger (EXP-X1-5) joins them by `boot_id` and `attempt_id`. Reason: there is no per-event bloat, and the config hash can change mid-boot.
- **KTD2. Version triple.** `aiur_vsn` comes from `Application.spec(:aiur, :vsn)`. `build_sha` comes from `AIUR_BUILD_STAMP` `source_sha` (read from `:code.root_dir()`; `unknown` when absent, as in a dev `mix` run). `package_version` comes from the stamp's `package_version=` when present. Reason: the vsn alone cannot tell builds apart, and X3 keys version lines on build_sha or vsn.
- **KTD3. Config hash.** This is the SHA-256 of the canonical JSON of the effective `Aiur.Config` settings, with sorted keys. Fields whose name matches the secret pattern used by `Aiur.UsageEnvelope` (`usage_envelope.ex:15`) are dropped, as are volatile fields such as observability refresh intervals. The record also carries a `config_section_hashes` map (agent, orchestrator, routing, capacity, observability) so an analyst can see which section changed. The raw config is never recorded. On `{:workflow_config_updated, _}` from the `workflow_store:configuration` PubSub topic (`src/lib/aiur/workflow_store.ex:487`), the Writer recomputes the hash. It emits a new `run_context` only when the hash differs.
- **KTD4. Attempt cohort fields.** These are added to the dispatch point:
  - `backend` from `CodingAgent.backend_for/1`, `model` from `CodingAgent.model_for/1` and `effort` from `CodingAgent.effort_for/1`, all resolved on the issue actually dispatched (`src/lib/aiur/coding_agent.ex:509,708,772`);
  - `feature` (slug) and `epic` (number) from `Aiur.BuildOrder.Features.owner/1`, with `nil` when the Features store is unavailable or the ticket has no owner;
  - `tags`: labels matching `observability.capture_label_prefixes`, a bounded list with at most 20 entries of 64 characters each;
  - `blockers`: identifiers from `issue.blocked_by` (at most 20; used by EXP-X1-3 and EXP-X1-5);
  - `start_mode`: `"normal"` by default; #3755 sets `"optimistic"`.
- **KTD5. Lifecycle metadata gains bounded string lists** for `tags` and `blockers` only. Other values keep scalar normalization. The `@metadata_fields` whitelist grows by `model`, `effort`, `feature`, `epic`, `tags`, `blockers`, `start_mode`. Reason: this keeps the privacy contract in `lifecycle.ex:2-8` (no free text).
- **KTD6. Consumer config** (KD2). These fields join `observability` (`src/lib/aiur/config/schema/observability.ex`):
  - `capture_tags`: a map of string to string, at most 20 entries, recorded in `run_context` (for example `{"host": "box-a", "variant": "B"}`);
  - `capture_label_prefixes`: a list, default `["experiment:", "cohort:", "feature:"]`.
  Reason: generic. A consumer repo tags cohorts with labels or config, not with aiur code.
- **KTD7. Schema version.** `RunTelemetry.schema_version/0` goes from 2 to 3 (`src/lib/aiur/run_telemetry.ex:15-16`). Both reducers accept 2 and 3. `run_context` is added to `SUPPORTED_KINDS` (`analytics/lib/analytics/reduce.py:25`).

## High-Level Technical Design

```
boot ──► Writer.init ──► restart record ──► run_context{aiur_vsn, build_sha, package_version,
                                                        config_hash, config_section_hashes, capture_tags, repo}
workflow_store:configuration ──► Writer ──► (hash changed?) ──► run_context (new hash)
Dispatcher.spawn_issue_on_worker_host ──► Lifecycle.record(:dispatch, :point,
        {complexity, backend, model, effort, feature, epic, tags[], blockers[], start_mode, retry_attempt, ...})
```

## Implementation Units

### U1. Run context builder

**Goal:** A pure module builds the boot-level cohort map.
**Files:** `src/lib/aiur/run_telemetry/run_context.ex` (new), `src/test/aiur/run_telemetry/run_context_test.exs`.
**Approach:** Implement `build(settings, opts)` with injectable `stamp_path`, `vsn` and `repo`. It returns a sanitized map plus the config hash. The secret-field filter reuses the UsageEnvelope pattern.
**Test scenarios:**
- A stamp file with `source_sha=abc` gives `build_sha: "abc"`.
- A missing stamp gives `"unknown"`.
- Two settings structs that differ only in a secret-named field give the same hash.
- Changing `agent.max_concurrent_agents` changes `config_hash` and `config_section_hashes.agent`, and only that section hash.
- More than 20 `capture_tags` are truncated, and a warning field is set.

### U2. Writer emits run_context

**Goal:** A `run_context` record goes out after `restart`, and again on a config-hash change.
**Dependencies:** U1.
**Files:** `src/lib/aiur/run_telemetry/writer.ex` (`init/1`, a new `handle_info({:workflow_config_updated, _}, state)`), `src/test/aiur/run_telemetry/writer_test.exs`.
**Approach:** Subscribe to the PubSub topic in `init`. Keep `last_config_hash` in state. Add `run_context` to the carried records on segment rolls, as `@carried_point_events` does today (`writer.ex:39-43`), so every segment has its context.
**Test scenarios:**
- Boot writes `restart` (sequence 1) and then `run_context` (sequence 2).
- A config broadcast with an unchanged hash writes nothing.
- A broadcast with a changed hash writes one new `run_context`.
- A segment roll re-emits the current context, marked as carried.

### U3. Dispatch cohort attributes

**Goal:** The dispatch point carries the attempt cohort.
**Files:** `src/lib/aiur/orchestrator/dispatcher.ex` (about line 2668), `src/lib/aiur/run_telemetry/lifecycle.ex` (whitelist and list normalization), `src/test/aiur/run_telemetry/lifecycle_test.exs`, `src/test/aiur/orchestrator/dispatcher_telemetry_test.exs` (new, or the closest existing dispatcher test).
**Approach:** A helper `TelemetryCohort.attempt_fields(issue)` lives in run_telemetry so the orchestrator calls one function. `Features.owner/1` is called with a short timeout and fails open to `nil`. Lists are normalized to strings of at most 64 characters, at most 20 items.
**Test scenarios:**
- An issue with labels `complexity:2`, `experiment:optimistic` and `bug`, and prefixes at their defaults, gives `tags == ["experiment:optimistic"]`.
- An issue with `selected_backend: "codex"` gives `backend: "codex"`, plus the resolved model and effort.
- Two blockers give `blockers == ["3755", "3763"]`.
- A Features call that times out gives `feature: nil`, and dispatch still proceeds.
- A list value for a non-list field still normalizes to `"unknown"`.

### U4. Config schema, docs and reducers

**Goal:** The new config fields are validated and documented, and the reducers carry the new fields.
**Files:** `src/lib/aiur/config/schema/observability.ex`, `website/docs-app/reference/configuration.md` (about lines 679-682), `src/lib/aiur/run_telemetry/dataset.ex`, `analytics/lib/analytics/reduce.py` (`_lifecycle_event` adds model, effort, feature, epic, tags, blockers, start_mode; a new `run_contexts` list in the boot summary), `analytics/schema/run-summary.v1.json` (optional `run_contexts` property), `src/lib/aiur/run_telemetry.ex` (schema version 3), and tests in `analytics/tests/test_reduce.py` and `src/test/aiur/config_test.exs` (or the observability schema test).
**Test scenarios:**
- A config with `capture_tags` that is not a map is rejected with a clear error.
- `scripts/check-config-docs.py` passes.
- The reducer keeps `run_context` records in the summary, and a v2-only fixture still reduces.

## Interfaces offered to other areas

- X2, X4: `run_context` fields and attempt fields, through the ledger (EXP-X1-5). These are the only cohort keys.
- X3: `build_sha` and `aiur_vsn` changes across `run_context` records are the version-line signal.
- #3755 / X7: set `start_mode: "optimistic"` in the dispatch metadata when a dependent starts before its blockers merge.

## Risks

- **Hash churn.** Volatile config fields make every boot look like a config change. Mitigation: an explicit volatile-field exclusion list, plus the section hashes.
- **Features lookup cost on the dispatch path.** Mitigation: a bounded timeout and fail-open, and the lookup runs only when telemetry is enabled (`TelemetryLifecycle.enabled?()` already guards the call site).
