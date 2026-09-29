---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
plan_source: ce-plan
issue: 2874
---

# Per-agent context and usage visibility

## Product Contract (brainstorm)

### Problem

An operator looking at a worker cannot see Aiur's turn count, and the TUI guide incorrectly claims that the board shows it. Existing context occupancy is separate from provider-reported cumulative inference usage. The latter has distinct scope and cache relationships, so a zero-filled shortcut would mislead operators.

### Decision

Deliver this issue in three reviewable slices. The first slice makes **Aiur orchestration turns** and **current context occupancy** visible together in each current-run Units row, with unknown values explicit. It corrects the TUI guide to describe the board as it exists. [#2881](https://github.com/aiur-team/aiur/issues/2881) adds per-agent input/output/cache usage from verified UsageEnvelope sources. [#2882](https://github.com/aiur-team/aiur/issues/2882) handles optional native compaction after the usage view can establish an honest baseline. Ben marked cache trends as aspirational; the first usage follow-up prioritizes a trustworthy current snapshot.

### User-facing rules

- A turn is an Aiur orchestration turn: the unique `session_started` event counted by `Aiur.Orchestrator.TokenAccounting`. It is not a model request or tool cycle. The count is scoped to the current running entry; a new retry/attempt may start at zero.
- Context occupancy is a current provider observation (`used_tokens` and, when known, `window_tokens`). It is not cumulative input tokens or an account allowance.
- A row without a valid turn count or context observation displays an explicit unknown marker. Stale status remains visibly stale through the existing Units source state.
- No new provider billing, quota, or savings claim is made by this slice.

### Acceptance

A current running row shows its observed turn count and context occupancy together. A row without either source says unknown, and a known turn count of zero remains zero. Existing writable/read-only controls and row navigation keep working. The TUI guide accurately names the fields visible on the board.

## Technical Plan (ce-plan)

### Evidence

- `src/lib/aiur/orchestrator/token_accounting.ex:178` increments `turn_count` for a new `session_started` identity; `status_report.ex:504` publishes the running value.
- `src/lib/aiur/orchestrator/status_report.ex:503` publishes `context_usage`. `Aiur.AgentContextPresentation` already formats known occupancy and unknown capacity without inventing a zero.
- `src/lib/aiur_web/operator_control_center/units_row/projection.ex` joins StatusReport rows to durable current-run membership. `UnitsTable` renders each row.
- `src/lib/aiur/agent_list/renderer/table.ex` renders CTX but no turn count. `website/docs-app/guide/tui.md` currently claims both.

### Work units

1. Project `turn_count` and `context_usage` from a matching running StatusReport entry into the Units row. Keep nil for absent/invalid values and identify StatusReport as the field source.
2. Render a compact, accessible facts line in each Units row with a defined turn scope and context wording; use `AgentContextPresentation` for context.
3. Correct the TUI guide and document the Units facts in the GUI guide.
4. Add focused projection and component tests for observed zero, positive, missing, and known-context/unknown-capacity states. Prove new tests fail with production hunks reverted in an isolated worktree. Run affected tests, format, compile and CI. Executor manual `aiurdev --test` remains outside agent issue workspaces per AGENTS.md.

### Out of scope

Provider token/cache totals and trends (#2881), automatic cache-miss diagnosis, compaction controls (#2882), pricing or savings claims, and provider-specific assumptions about unsupported fields.
