---
title: GitHub Budget Served-Free Ranking - Plan
type: feat
date: 2026-08-21
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# GitHub Budget Served-Free Ranking - Plan

## Goal Capsule

- **Objective:** Make the GitHub budget ranking distinguish a quiet caller from a ranked caller whose reads are being served by the daemon cache.
- **Authority:** Issue #2221 and the repository's dashboard correctness rules govern the result; the cache snapshot is observational data and must never alter spend accounting.
- **Stop conditions:** Do not attribute a cache hit to GraphQL or core, add cache hits to quota totals or charts, or render unavailable/unobserved cache data as zero.
- **Execution profile:** Extend the existing LiveView projection and focused LiveView tests, then update the existing operator guide.
- **Tail ownership:** The implementation owns scoped compile, format, affected tests, draft-PR self-review, and CI handoff.

## Product Contract

### Summary

Add a boot-scoped, caller-wide served-free column to each existing quota caller row so low spend accompanied by cache hits reads differently from low spend with no cache hits.

### Problem Frame

The ranking correctly measures only requests that reached GitHub. Since the read-through cache wraps quota observation, a served read contributes neither points nor calls, leaving quiet and effectively cached callers visually identical.

### Requirements

- R1. Each ranked quota caller shows how many reads the daemon cache served for that caller since boot.
- R2. An available cache with no hits for a caller renders a worded no-hit state rather than a bare numeric zero.
- R3. An unavailable cache renders a distinct worded unavailable state and ignores zero-shaped fallback counters.
- R4. Served-free values remain outside points, calls, shares, rates, charts, attributed totals, and outside-spend calculations; the non-caller remainder row shows an explicit non-applicable cell.
- R5. The operator guide explains the column's caller-wide, since-boot scope and that it is not spend.
- R6. The widened table remains readable and keyboard-reachable on narrow dashboard viewports.

### Scope Boundaries

- Keep quota rows ranked by points and keep GraphQL and core budgets separate.
- Do not insert cache-only callers into a budget table: `ReadCache.snapshot/0` has caller totals but no GitHub resource dimension, so assigning those rows to GraphQL or core would invent attribution.
- Do not change cache metrics or quota accounting; this is a read-only join at the presentation boundary.

### Acceptance Examples

- AE1. Given two ranked callers with equally low spend, when one has positive cache hits and the other has none, then the served-free cells show a positive read count and a worded no-hit state respectively.
- AE2. Given the same quota data, when the cache snapshot is unavailable, then every ranked caller shows a worded unavailable state and all spend cells remain unchanged.

## Planning Contract

### Key Technical Decisions

- KTD1. Read `Aiur.GitHub.ReadCache.snapshot/0` through a test-replaceable provider seam during initial load and the existing quota-history refresh cadence. This mirrors the page's quota/history seams and keeps the view live without creating a GitHub request or a new event system.
- KTD2. Resolve served-free display values by caller only for existing quota rows. Cache metrics are caller-wide and boot-scoped, so the heading/caption must state that boundary rather than imply a per-budget window.
- KTD3. Branch on `available?` before reading caller counters. Positive hits render as reads, available zero/absence renders words, and unavailable renders a different worded state.
- KTD4. Keep the join inside LiveView assigns/render helpers. `QuotaUsage` remains the single source of every spend total and chart series.

### Assumptions

- The issue's requested “served-free column” applies to callers already present in each spend ranking; adding budget-neutral cache-only rows is outside this change because the supplied snapshot cannot place them in a budget without guessing.
- Cache hits since daemon boot are useful alongside the current quota window only when their different time scope is explicit in the table copy.

## Implementation Units

### U1. Join cache activity into ranked caller rendering

- **Goal:** Render positive, available no-hit, and unavailable served-free states without changing spend accounting.
- **Requirements:** R1, R2, R3, R4, R6; AE1, AE2; KTD1-KTD4.
- **Dependencies:** None.
- **Files:** `src/lib/aiur_web/live/github_cache_live.ex`, `src/lib/aiur_web/operator_control_center/github_cache/styles.ex`, `src/test/aiur_web/live/github_cache_live_test.exs`.
- **Approach:** Snapshot the read cache at the existing free observational seams, pass it separately to the usage layer, and add a clearly non-spend table column whose helper branches on availability before caller hits. Give the remainder row an aligned non-applicable cell and place the table in a labelled, keyboard-focusable horizontal scroll region on narrow viewports.
- **Patterns to follow:** Existing provider seams and unobserved-vs-zero helpers in `AiurWeb.GithubCacheLive`; `Aiur.GitHub.ReadCache.Metrics.snapshot/0` availability-first contract.
- **Test scenarios:**
  - Covers AE1. Positive hits for one ranked caller render as a read count while another ranked caller with no hits renders a worded no-hit state.
  - An explicitly present caller with `hit: 0` and an absent caller produce the same observed no-hit display.
  - Covers AE2. An unavailable snapshot renders a distinct unavailable phrase even if its counters are zero-shaped.
  - The points, calls, share, ordering, attributed total, outside remainder, and chart inputs remain quota-derived after cache data is joined.
  - The outside/remainder row renders an aligned non-applicable served-free cell rather than a blank or attributed value.
  - A quota-history sample refreshes the cache snapshot without moving the GitHub quota reading.
  - The widened table remains usable in a narrow viewport through its labelled, keyboard-focusable scroll region.
- **Verification:** Focused LiveView tests name the served-free states and prove the existing spend figures remain unchanged.

### U2. Document the operator interpretation

- **Goal:** Explain how to read the new column without treating it as budget spend.
- **Requirements:** R5.
- **Dependencies:** U1.
- **Files:** `website/docs-app/guide/executor-control-center.md`.
- **Approach:** Extend the existing GitHub cache section with the ranking's reached-GitHub boundary, the served-free column's since-boot scope, and its unavailable/no-hit distinction.
- **Patterns to follow:** Concise surface documentation already used by the Executor Control Center guide.
- **Test expectation:** None -- this unit changes explanatory documentation only.
- **Verification:** The guide describes all three display states and explicitly excludes served reads from spend totals.

## Verification Contract

- `mise exec -- mix compile --warnings-as-errors` succeeds from `src/`.
- `mise exec -- mix format` leaves the touched Elixir files formatted.
- `mise exec -- mix aiur.affected_tests` identifies the scoped test set.
- Every printed test command is run with `mix test --max-cases 4` and passes.
- The draft PR diff shows no changes to `QuotaUsage` totals or chart aggregation.

## Definition of Done

- U1 renders positive, available no-hit, and unavailable cache-hit states for ranked callers, preserves quota-derived accounting, and keeps the table usable at narrow widths.
- U2 documents the column's meaning and observation boundary.
- Focused tests execute and fail against an implementation that renders bare zero or folds hits into spend.
- Compile, format, and affected tests pass; no abandoned or exploratory code remains in the diff.
