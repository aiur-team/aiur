---
title: BQ-G1-1 Start trigger setting and shared readiness policy - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/build-queue-optimistic-start/g1/brainstorm.md
epic: aiur-team/aiur#3755
---

# BQ-G1-1 Start trigger setting and shared readiness policy - Plan

## Summary

Add the `start_trigger` setting (config default plus per-queue override) and a pure `Aiur.StartTrigger` policy module. Queue readiness evaluates every edge through it. Dispatch moves onto the same module in BQ-G1-3; durable evidence arrives in BQ-G1-2. This PR is useful alone: with labels the queue already observes, all five triggers work for queues, and `pr_merged` closes the merged-but-open gap.

Product Contract unchanged (see origin).

---

## Problem Frame

`Readiness.classify/2` (`src/lib/aiur/build_queue/readiness.ex`) satisfies an edge only on `open?: false, state_reason: "completed"`. Every open blocker is `:pending` unless it has `agent:error` or a closed-unmerged PR. There is no setting to start earlier.

## Requirements

R1, R2, R3, R4 (policy half), R5, R6 (label part), R7 from the origin.

---

## Key Technical Decisions

- **KTD1. Trigger values are atoms in a fixed ladder** `[:issue_closed, :pr_merged, :pr_approved, :pr_ci_green, :pr_opened]`. `StartTrigger.satisfies?(stage, trigger)` is "stage index >= the trigger's required stage". Config strings map 1:1.
- **KTD2. Evidence is a struct, not the queue Observation.** `Aiur.StartTrigger.Evidence` holds `issue_open?` (`true | false | :unknown`), `state_reason`, `state_label` (normalised `agent:*` state), `pr` (`nil | :open | :merged | :closed_unmerged`), `pr_number`, `stage_reached` (atom or `nil`, from BQ-G1-2), `observed_at_ms`. The queue builds it from `Observation`; dispatch builds it from a hydrated `blocked_by` entry (BQ-G1-3). One input shape keeps R4 honest.
- **KTD3. Stage from labels.** `ci-wait`, `human-review`, `rework`, `merging`, `done` imply a ready PR (`:pr_opened`); `human-review`, `rework`, `merging`, `done` imply `:pr_ci_green`; `merging`, `done` imply `:pr_approved`; `done`, `pr: :merged`, or closed `completed` imply `:pr_merged`/final. The stage used is the max of the label stage and `stage_reached`.
- **KTD4. Verdict order** in `StartTrigger.edge_verdict(trigger, evidence, opts)`: cyclic -> stale/unknown observation -> closed issue (completed = satisfied final; not_planned per `:not_planned` opt; duplicate/other = unknown) -> `agent:error` label = failed -> `pr: :closed_unmerged` = failed -> stage satisfies trigger = `{:satisfied, :final | :optimistic}` -> `:pending`. The existing `Readiness.edge_verdict/2` becomes a wrapper that collapses `{:satisfied, _}` to `:satisfied`, so `item_verdict/1` and the planner keep their types.
- **KTD5. Trigger per edge = the dependent's queue trigger, else config.** The planner context gains `triggers: %{issue_id => trigger}` built from `items` and `queues`.
- **KTD6. Store compatibility.** `Model.Queue` gains `start_trigger: nil | atom`. `Codec` uses the existing `{:default, type, nil}` field form, so version 1 documents written before this change decode unchanged. `nil` means "follow config".
- **KTD7. `merged_issue_open` only under `issue_closed`.** `Planner.merged_keys/2` skips edges whose dependent's trigger is not `:issue_closed`; under any other trigger the edge is already satisfied by the merge.
- **KTD8. CLI.** `aiur queue add --start-on <trigger>` (for both `--build-order` adoption and named list creation) and a new verb `aiur queue set <queue> --start-on <trigger>`. Invalid values exit 64 with the list of valid values.

---

## Implementation Units

### U1. Pure policy module

**Goal:** the ladder, evidence struct and verdict function.
**Dependencies:** none.
**Files:** create `src/lib/aiur/start_trigger.ex`, `src/lib/aiur/start_trigger/evidence.ex`; test `src/test/aiur/start_trigger_test.exs`.
**Approach:** KTD1-KTD4. No process state, no I/O. Export `triggers/0`, `parse/1`, `stage/1` (from evidence), `edge_verdict/3`, `final?/1`.
**Patterns to follow:** `Aiur.BuildQueue.Readiness` (pure, verdict tuples, `opts` keyword with `:now_ms`, `:max_age_ms`, `:label_prefix`, `:not_planned`).
**Test scenarios:**
- Each trigger x each label stage: table test proving the ladder (e.g. `pr_opened` + `ci-wait` = `{:satisfied, :optimistic}`; `pr_ci_green` + `ci-wait` = `:pending`; `pr_merged` + `human-review` = `:pending`).
- `pr_merged` + open issue + `pr: :merged` = `{:satisfied, :final}` (merged-but-open, covers AE2).
- `issue_closed` + `pr: :merged` + open issue = `:pending`.
- Stale `observed_at_ms` with `ci-wait` label = `{:unknown, :stale}` for every trigger (R5, AE4).
- `pr: :closed_unmerged` under `pr_opened` = `{:failed, :pr_closed_unmerged}` even with `human-review` label (AE5).
- `stage_reached: :pr_ci_green` with label `in-progress` under `pr_ci_green` = satisfied (R6, AE3).
- `not_planned` honours `:not_planned` opt both ways.
**Verification:** module has no dependency on `Aiur.Orchestrator` or `Aiur.BuildQueue`.

### U2. Config and queue record

**Goal:** the setting exists and persists.
**Dependencies:** U1.
**Files:** `src/lib/aiur/config/schema/build_queue.ex`, `src/lib/aiur/build_queue/settings.ex`, `src/lib/aiur/build_queue/model.ex`, `src/lib/aiur/build_queue/codec.ex`, `src/examples/workflows/github-claude.yaml`, `src/examples/workflows/github-codex.yaml`; tests `src/test/aiur/config/build_queue_test.exs`, `src/test/aiur/build_queue/model_test.exs`, `src/test/aiur/build_queue/store_test.exs`.
**Approach:** `field(:start_trigger, :string, default: "pr_merged")` with `validate_inclusion`. `Settings.start_trigger/1` returns the atom. Queue field per KTD6.
**Test scenarios:**
- Config without the key resolves to `:pr_merged`; `"pr_opened"` resolves; `"soon"` is a changeset error naming the valid values.
- A store document from before this change (no `start_trigger` key) decodes with `nil`.
- Encode/decode round-trip keeps `:pr_ci_green`; an unknown string in the document fails decode with an `invalid` path, like other enum fields.

### U3. Readiness and planner use the policy

**Goal:** queue promotion follows the trigger.
**Dependencies:** U1, U2.
**Files:** `src/lib/aiur/build_queue/readiness.ex`, `src/lib/aiur/build_queue/planner.ex`, `src/lib/aiur/build_queue/reconcile.ex`, `src/lib/aiur/build_queue/read_model.ex`, `src/lib/aiur/build_queue/attention_actions.ex`; tests `src/test/aiur/build_queue/readiness_test.exs`, `planner_test.exs`, `merged_open_test.exs`, `projection_read_test.exs`.
**Approach:** `Readiness.edge_verdict/2` builds `Evidence` from the `Observation` and calls `StartTrigger.edge_verdict/3` with the trigger from `opts[:trigger]` (default `:issue_closed` to keep direct callers' behaviour explicit). `Planner.context/1` adds `triggers` (KTD5) and `edge_verdict/2` passes the dependent's trigger. `reconcile.ex` passes the config default (`Settings.start_trigger/1`). The read model reports per queue `start_trigger` (effective) and per prerequisite `stage` and `trigger` so BQ-G1-4 can render them. `merged_keys/2` per KTD7. `attention_actions.ex:42` builds the same opts so attention evaluation agrees.
**Test scenarios:**
- Queue `start_trigger: :pr_opened`, prerequisite open with `agent:ci-wait` and fresh labels: dependent projects `:ready` and plans `{:promote, id}` (AE1 queue half).
- Same queue, prerequisite `agent:in-progress`: `:waiting`.
- Queue `nil`, config `:pr_merged`, prerequisite open with `pr: :merged`: `:ready`; no `{:attention_open, {:merged_issue_open, _}}` (AE2 queue half, KTD7).
- Queue `:issue_closed`: today's `merged_open_test.exs` expectations still pass unchanged.
- Two queues with different triggers sharing one prerequisite: each dependent gets its own verdict.
- Promoted, unclaimed item whose queue trigger is tightened from `pr_opened` to `pr_merged` while the blocker is in `ci-wait`: plans `{:begin_withdraw, id}` (KD6).
**Verification:** all existing `src/test/aiur/build_queue/` tests pass with config default `pr_merged` (only merged-open cases change, by design).

### U4. CLI: `--start-on` and `queue set`

**Goal:** the operator can set and change the trigger.
**Dependencies:** U2.
**Files:** `packaging/npm/aiur-cli/libexec/aiur-queue.sh`, `src/lib/aiur/build_queue/mutation_cli.ex`, `src/lib/aiur/build_queue/build_order_commands.ex`, `src/lib/aiur/build_queue/list_commands.ex`, `src/lib/aiur/build_queue/list_mutations.ex`, `src/lib/aiur/build_queue/server.ex`; tests `src/test/aiur/build_queue/mutation_cli_test.exs`, `list_commands_test.exs`, `build_order_source_test.exs`, `packaging/npm/aiur-cli/test/queue-recovery.test.mjs` (or a new `queue-start-on.test.mjs`).
**Approach:** add `:start_on` to the `:add` allowed options; new verb `:set` with `[:queue, :start_on]`; server mutation `{:set_trigger, queue_name, trigger}` bumps the queue `generation` so the next reconcile re-plans. Unknown queue name is an error like `queue show`.
**Test scenarios:**
- `queue add --build-order 2573 --start-on pr_opened` stores `:pr_opened` on the adopted queue.
- `queue add 12 13 --queue wave --start-on pr_ci_green` on a new list stores it; on an existing list with a different trigger it errors and points to `queue set` (no silent overwrite).
- `queue set wave --start-on default` stores `nil` (follow config).
- `--start-on soon` exits 64 and prints the valid values; `--start-on` with `remove` exits 64.
- Shell parser forwards `--start-on` only for `add` and `set`.
**Verification:** `aiur queue show --json` shows the stored trigger after each command.

---

## Risks

- **Label trust.** `ci-wait` is agent-written. Mitigation: the agent skill requires a ready PR before `ci-wait`; BQ-G1-2 adds PR-identity evidence; optimistic triggers are opt-in.
- **Behaviour change at default.** `pr_merged` starts dependents a few minutes earlier than today in the merged-but-open window only. Merged code is on `main`, so the dependent branches from it.

## Documentation

Ships in this PR: `website/docs-app/reference/configuration.md` (`build_queue.start_trigger`), `website/docs-app/reference/cli.md` (`--start-on`, `queue set`). Concept docs land in BQ-G1-4.

## Definition of Done

- U1-U4 tests pass; existing build queue suite passes.
- A queue adopted with `--start-on pr_opened` promotes a dependent when its blocker enters `agent:ci-wait`, observed in `aiur queue show`.
