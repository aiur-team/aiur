---
title: BQ-G1-4 Surface the start trigger in CLI, waiting reasons and docs - Plan
date: 2026-10-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/build-queue-optimistic-start/g1/brainstorm.md
epic: aiur-team/aiur#3755
---

# BQ-G1-4 Surface the start trigger in CLI, waiting reasons and docs - Plan

## Summary

Make the trigger and the missing stage visible wherever an operator asks "why is this ticket not running": `aiur queue show` (human and JSON), the dispatch decline log line and `[waiting=...]` strings, the build queue dashboard panel, and the concept docs.

Product Contract unchanged (see origin).

---

## Requirements

R10 from the origin.

---

## Key Technical Decisions

- **KTD1. One describer.** `Aiur.StartTrigger.describe(trigger, evidence, verdict)` returns the short reason text, e.g. `#12 needs pr_ci_green (now pr_opened, PR #99)`, `#12 satisfied optimistically (pr_opened)`, `#12 unknown: stale observation`, `#12 failed: PR closed unmerged`. CLI, log line and panel all call it, so wording never drifts.
- **KTD2. `queue show`.** The queue header line shows `start on <trigger>` (with `(default)` when following config). The `waiting on` column uses the describer per unsatisfied prerequisite; satisfied-optimistic prerequisites show as `#12 optimistic` so the operator sees optimistic starts. JSON adds `start_trigger`, `start_trigger_source` (`queue` | `config`) per queue and `stage`, `trigger`, `optimistic` per prerequisite.
- **KTD3. Dispatch strings.** `DispatchPolicy.describe_dependency_hold/2` names the trigger: `blocked by open dependency #12 (in-progress); needs pr_opened`. The `waiting_for_dependency` evidence in `waiting_reason.ex` carries the same text. The reason atom `:waiting_for_dependency` does not change (status board and tests key on it).
- **KTD4. Panel.** `src/lib/aiur_web/build_queue/copy.ex` and `panel.ex` show the queue trigger and per-item reason through the describer; no new layout.

---

## Implementation Units

### U1. Describer

**Goal:** single wording source.
**Dependencies:** BQ-G1-1 U1.
**Files:** `src/lib/aiur/start_trigger.ex`; test `src/test/aiur/start_trigger_test.exs`.
**Test scenarios:** one case per verdict kind and per trigger; PR number omitted when unknown; output has no trailing punctuation and stays under 80 characters for a single blocker.

### U2. `queue show` and read model

**Dependencies:** U1, BQ-G1-1 U3.
**Files:** `src/lib/aiur/build_queue_cli.ex`, `src/lib/aiur/build_queue/read_model.ex`; tests `src/test/aiur/build_queue_cli_test.exs`, `src/test/aiur/build_queue/projection_read_test.exs`.
**Test scenarios:**
- Queue with `:pr_opened`: header shows `start on pr_opened`; queue with `nil`: `start on pr_merged (default)`.
- Waiting item shows `#12 needs pr_ci_green (now pr_opened, PR #99)`.
- Item started optimistically shows `#12 optimistic`.
- `--json` contains the KTD2 keys; old consumers ignoring them still parse.

### U3. Dispatch log and waiting reason

**Dependencies:** U1, BQ-G1-3 U2.
**Files:** `src/lib/aiur/orchestrator/dispatch_policy.ex` (`describe_dependency_hold/2`), `src/lib/aiur/orchestrator/waiting_reason.ex`; tests `src/test/aiur/orchestrator/dispatch_policy_test.exs`, `waiting_reason_test.exs`, `waiting_descriptor_test.exs`.
**Test scenarios:**
- Default trigger: existing text plus `; needs pr_merged` (update the #2751 assertions deliberately).
- Under `pr_opened` with a stale blocker: text names `unknown: stale observation`.
- `render(:waiting_for_dependency)` unchanged.

### U4. Panel copy

**Dependencies:** U1, U2.
**Files:** `src/lib/aiur_web/build_queue/copy.ex`, `src/lib/aiur_web/build_queue/panel.ex`; tests `src/test/aiur_web/live/build_queue_panel_test.exs`.
**Test scenarios:** panel renders the trigger and the describer text for a waiting item; no layout snapshot change beyond the text.

### U5. Docs

**Dependencies:** BQ-G1-1..3 merged (text describes shipped behaviour).
**Files:** `website/docs-app/concepts/build-orders.md` (new "Start trigger" section after "Queueing a Build Order"; revise "Merged PRs with open issues" to say it applies only under `issue_closed`), `website/docs-app/concepts/ticket-lifecycle.md` ("Build queue" section: the ladder, dispatch follows the same rule), `website/docs-app/reference/cli.md`, `website/docs-app/reference/configuration.md`.
**Test expectation:** none -- documentation; verify docs build and links.
**Content:** the ladder table (trigger, starts when, evidence), the default, how to set per queue, what "optimistic" means for the dependent agent (link to G2 docs), that Linear supports only `issue_closed` and `pr_merged`, and that `pr_approved` costs one conditional review read per watched blocker.

---

## Definition of Done

- U1-U5 done; `aiur queue show` on a live queue under `pr_opened` shows the trigger and an optimistic prerequisite.
