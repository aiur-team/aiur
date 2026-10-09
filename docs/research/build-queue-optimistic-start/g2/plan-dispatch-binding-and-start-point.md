---
title: BQ-G2-1 Bind blocker events and start on the blocker branch at optimistic dispatch - Plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/build-queue-optimistic-start/g2/brainstorm.md
epic: aiur-team/aiur#3755
code_baseline: origin/main 0e5b8d0de
depth: Standard
---

# BQ-G2-1 Bind blocker events and start on the blocker branch at optimistic dispatch - Plan

## Summary

When dispatch lets a ticket start while a blocker PR is still open (G1's trigger), the orchestrator binds the blocker subscriptions before the worker spawns, starts a fresh ticket branch on the blocker head, injects an "Optimistic start" prompt block, and records the optimistic start on the running entry. Covers brainstorm R1-R4, R11; KD1-KD5.

Product Contract preservation: unchanged.

## Problem Frame

Dispatch today only starts tickets whose blockers are terminal (`src/lib/aiur/orchestrator/dispatcher.ex` `dispatch_issue_with_dependency_check/5`). Once G1 relaxes that, a dependent would start on `origin/<base>` with no blocker subscriptions on GitHub (the poll binder never sees `blocked_by`, see `auto_subscriptions.ex` comment above `direct_blockers_for/2`), and a prompt that tells it to open its PR against the base branch. It would be blind to the blocker's pushes and build on code that lacks the blocker's work.

## Requirements

- R1 bind the `aiur_declare_blocker` subscription set for every non-terminal blocker before spawn.
- R2 an optimistic dispatch whose binding fails is declined (`:optimistic_subscription_failed`) and retried.
- R3 fresh branch starts at the single unmerged blocker's head SHA; several unmerged -> base tip; existing remote branch untouched.
- R4 first-turn prompt carries the Optimistic start block on every workspace path.
- R11 running entry and dispatch telemetry carry the optimistic start record.

## Key Technical Decisions

- **Reuse `AutoSubscriptions.subscribe_for_declared_blocker/2`** (KD1). It already writes the 9+2 topics with `blocker:auto` / `blockee:auto`; mid-turn drain and edge-removal unbinding follow. Call it from the orchestrator process at the dispatch gate; do not go through `ToolExecutor` (that path also POSTs the dependency).
- **Bind for all non-terminal blockers on every dispatch** (KD2); only optimistic dispatch fails closed. Non-optimistic binding failure logs a warning and dispatches anyway (today's behavior has no binding at all).
- **Optimistic context travels on the `Issue`**, as a new optional field `optimistic_start` (nil by default), set in `dispatch_issue_with_dependency_check/5` before `do_dispatch_issue/5`. `Issue` already flows to `Workspace.Context.build/1` and `PromptBuilder.build_prompt/2`, so no new plumbing through the runner.
- **Start point via `Workspace.Context` -> `Checkout`.** `Context.build/1` adds `start_point: %{ref, sha}` from `issue.optimistic_start` when there is exactly one unmerged blocker. `Checkout.checkout_fresh_branch/2` uses it only on the `:no_remote` branch (fresh ticket): fetch the blocker ref, verify the fetched SHA equals the evidence SHA (or descends from it), then `checkout -B <branch> <sha>`. Fetch failure falls back to the base tip; the prompt block then makes the worker merge it.
- **Evidence source** (KD5): G1's gate evidence (`head_ref`, `head_sha`, `pr_number`); missing SHA -> `BranchRefStore.latest/1`; still missing -> decline `:optimistic_ref_unavailable` (non-attention, retried).
- **Prompt block lives in `PromptBuilder`**, next to `integration_branch_prompt/1`, so operator templates cannot drop it. It overrides the base-branch PR rule only for the single-blocker case and names the ancestry check.

## High-Level Technical Design

```mermaid
sequenceDiagram
  participant D as Dispatcher (orchestrator)
  participant G1 as G1 dependency gate
  participant AS as AutoSubscriptions
  participant R as Runner task
  participant W as Workspace / Checkout
  participant P as PromptBuilder
  D->>G1: hydrated issue, trigger
  G1-->>D: dispatch + optimistic_blockers[]
  D->>AS: subscribe_for_declared_blocker(D, B) for each non-terminal B
  alt binding failed and optimistic
    D-->>D: decline :optimistic_subscription_failed
  else
    D->>D: issue.optimistic_start = record; running_entry.optimistic_start
    D->>R: spawn
    R->>W: ensure workspace (start_point = B head when single)
    R->>P: build_prompt (Optimistic start block)
  end
```

## Implementation Units

### U1. Optimistic start record and Issue field

**Goal:** One struct-shaped map describes the optimistic start; `Issue` can carry it.
**Requirements:** R11.
**Dependencies:** G1 gate evidence shape (cross-area).
**Files:** `src/lib/aiur/issue.ex`, new `src/lib/aiur/orchestrator/optimistic_start.ex`, `src/test/aiur/orchestrator/optimistic_start_test.exs`.
**Approach:** `OptimisticStart.from_gate_evidence(blockers, fallback_lookup)` returns `{:ok, record} | {:error, :optimistic_ref_unavailable}`. Record: `blockers: [%{identifier, pr_number, ref, sha}]`, `primary: identifier | nil` (set only when exactly one), `pr_base: ref | :base_branch`, `started_at`. Pure; the `BranchRefStore.latest/1` lookup is injected.
**Patterns to follow:** `Aiur.Workspace.Context` (pure policy module, injected collaborators).
**Test scenarios:**
- One blocker with full evidence -> `primary` set, `pr_base` = its ref.
- Two blockers -> `primary` nil, `pr_base: :base_branch`, both listed.
- Evidence missing SHA, `BranchRefStore` has one -> uses it.
- Neither source has a SHA -> `{:error, :optimistic_ref_unavailable}`.
- Empty blocker list -> `{:ok, nil}` (ordinary dispatch).
**Verification:** module tests pass; `Issue` default `optimistic_start: nil` leaves existing struct tests green.

### U2. Bind subscriptions and attach the record at the dispatch gate

**Goal:** Subscriptions exist before spawn; optimistic dispatch fails closed.
**Requirements:** R1, R2, R11.
**Dependencies:** U1; G1's gate change in the same function.
**Files:** `src/lib/aiur/orchestrator/dispatcher.ex` (`dispatch_issue_with_dependency_check/5`, `spawn_issue_on_worker_host/6` running entry and `TelemetryLifecycle.record(... :dispatch ...)`), `src/lib/aiur/orchestrator/dispatch_policy.ex` (decline reasons), `src/test/aiur/orchestrator/dispatcher_optimistic_start_test.exs`.
**Approach:** After the gate allows dispatch, for each non-terminal blocker call the binder (injectable via opts `:blocker_subscriber`, default `AutoSubscriptions.subscribe_for_declared_blocker/2`). Optimistic + any `{:error, _}` -> `emit_dispatch_attempt_decline(state, hydrated, :optimistic_subscription_failed, false)`; escalate to attention after 3 consecutive declines of the same ticket (reuse the decline-streak mechanism if one exists, else non-attention only). Then build the record (U1), put it on the issue, and copy it into the running entry (`optimistic_start:` key) and the dispatch telemetry point (`optimistic: true`, `optimistic_blockers: [...]`). Add a status-board decline phrase for the two new reasons.
**Patterns to follow:** existing `:dependency_hydration_failed` decline; `ToolExecutor` injection of `blocker_subscriber`.
**Test scenarios:**
- Optimistic dispatch: the binder is called for blocker B with (D, B) and returns before the runner fun is invoked (assert ordering with a message-recording runner).
- Binder error on optimistic dispatch -> no runner spawn, decline reason `:optimistic_subscription_failed`, ticket not claimed.
- Binder error on ordinary dispatch (blocker merged-open) -> spawn proceeds, warning logged.
- Ticket with no blockers -> binder not called; `optimistic_start` nil on running entry.
- Running entry and telemetry carry the record on optimistic dispatch.
- Integration: after dispatch, `SubscriptionStore.snapshot(D)` lists `ticket.B.branch.push` with reason `blocker:auto`, and `AutoSubscriptions.direct_blockers_for/2` returns `["B"]`.
**Verification:** tests above; existing `dispatcher_test.exs`, `dispatcher_blocked_by_cost_test.exs` green.

### U3. Fresh branch starts at the blocker head

**Goal:** Prewarm materialize path starts the ticket branch on the blocker SHA.
**Requirements:** R3.
**Dependencies:** U1.
**Files:** `src/lib/aiur/workspace/context.ex`, `src/lib/aiur/workspace/checkout.ex`, `src/lib/aiur/workspace/materialize.ex`, `src/lib/aiur/workspace/provisioner.ex` (thread `start_point` through `create_or_materialize`), `src/test/aiur/workspace/checkout_test.exs`, `src/test/aiur/workspace/context_test.exs`, `src/test/aiur/workspace/materialize_test.exs`.
**Approach:** `Context.build/1` adds `start_point` (nil unless `optimistic_start.primary`). `checkout_fresh_branch/3` accepts it; on `:no_remote`, fetch `origin <ref>`, require `FETCH_HEAD` == sha or `merge-base --is-ancestor sha FETCH_HEAD`, then branch at `sha` (the evaluated SHA, not a newer one: the worker pulls newer pushes via events). Any failure -> today's base start point plus a log line `optimistic_start_point=fallback`. Existing remote ticket branch path unchanged. Cold-clone and SSH paths are not changed (prompt fallback covers them).
**Patterns to follow:** `fresh_base_start_point/1` fallback style.
**Test scenarios (real temp git repos, as `checkout_test.exs` does):**
- Fresh ticket + start point on a remote blocker branch -> HEAD == blocker SHA, branch name is the ticket branch.
- Remote ticket branch already exists -> start point ignored, HEAD == remote ticket tip.
- Blocker ref missing on remote -> HEAD == `origin/<base>`.
- Remote blocker ref moved past the SHA -> HEAD == evidence SHA.
- Remote blocker ref rewritten so SHA is not an ancestor -> fallback to base.
**Verification:** tests; manual: an optimistic dispatch on the dev daemon shows the workspace `git log -1` equal to the blocker head.

### U4. Optimistic start prompt block

**Goal:** Every first-turn prompt of an optimistic dispatch states the blocker refs, the ancestry check, and the PR base.
**Requirements:** R4 (and carries R7's PR-base rule to the worker).
**Dependencies:** U1.
**Files:** `src/lib/aiur/prompt_builder.ex`, `src/test/aiur/prompt_builder_test.exs`.
**Approach:** `optimistic_start_prompt(issue)` returns "" when nil; else a block after the integration-branch block listing, per blocker, `#N`, PR, ref, SHA; the instruction to run the ancestry check and merge missing heads; the PR base (`--base <blocker ref>` for one blocker, `$AIUR_BASE_BRANCH` for several) stated as overriding the base-branch rule for PR creation only; "open as draft and do not move to ci-wait or human-review while a listed PR is unmerged; load `aiur-agent` `stub-then-fetch.md` section Optimistic start". Refs and SHAs are validated against the ticket-branch pattern and hex before rendering (they come from GitHub; never render free text).
**Patterns to follow:** `integration_branch_prompt/1`.
**Test scenarios:**
- No optimistic start -> prompt byte-identical to today's.
- One blocker -> block contains ref, SHA, `--base <ref>`, the ancestry command.
- Two blockers -> both listed, PR base is `$AIUR_BASE_BRANCH`.
- Ref with a newline or shell metacharacters -> blocker omitted and block says to resolve it with `scripts/resolve-ticket-branch N`.
**Verification:** tests; snapshot of a rendered prompt attached to the PR.

## Scope Boundaries

- Not in scope: G1's trigger setting and gate; G3 restack and merge-order gate; G5 slot accounting; force-push publication (BQ-G2-3); skill text (BQ-G2-2).
- Cold-clone and SSH worker start point: prompt fallback only.

### Deferred to Follow-Up Work

- Tool guard refusing `ci-wait` / `human-review` while `optimistic_start` blockers are unmerged (only if agents ignore the prompt; G3's merge gate is the hard stop).

## Risks & Dependencies

- **G1 interface drift.** G2 assumes the gate yields `optimistic_blockers` with `identifier, pr_number, head_ref, head_sha`. Mitigation: U1's `from_gate_evidence/2` is the only adapter.
- **Orchestrator latency.** Binding is up to 3 blockers x 11 synchronous `SubscriptionStore` calls in the orchestrator. Bounded; same cost `IssueSync` already pays on Linear.
- **Stale SHA at start.** The worker starts on the evaluated SHA, and any later push arrives as an event because binding preceded spawn.
- **Blocker closed unmerged before spawn.** G4 owns the policy; G2 only records the start.

## Documentation

- `website/docs-app/concepts/build-orders.md` (Queueing a Build Order): one paragraph on what an optimistic dependent starts on and what it is subscribed to.
- `website/docs-app/concepts/message-bus.md`: note that dispatch, not only `aiur_declare_blocker`, creates `blocker:auto` bindings.

## Rollout

No flag. Inert until G1 ships a non-default trigger. Ship before or with G1's gate change; ship before BQ-G2-2's skill text is relied on.

## Verification Contract

- `mix test` for the files listed; `mix aiur.affected_tests` clean.
- Dev-daemon check: with G1 set to `pr_opened`, dispatch a dependent; confirm bindings in its SubscriptionStore file, workspace HEAD on the blocker SHA, and the prompt block in the first turn log.

## Definition of Done

All units merged with tests; docs updated; the dev-daemon check passes and is recorded on the ticket.
