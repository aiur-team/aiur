---
title: "MP-R1-GHA-4: Add the Aiur.GitHub.Access facade and move callers onto it - Plan"
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: brainstorm.md
ticket_id: MP-R1-GHA-4
complexity: 3
blocked_by: [MP-R1-GHA-3, MP-R1-C7-T07 (#3309), MP-R1-C7-T08 (#3310)]
base_sha: d2a022fad
date: 2026-10-09
---

# MP-R1-GHA-4: Add the Aiur.GitHub.Access facade and move callers onto it - Plan

## Summary

Create one facade module, `Aiur.GitHub.Access`, that is github-access's whole public
contract. Move every caller outside github-access onto it. Declare it as the only facade
in `components.json`. Behaviour does not change; the facade only delegates.

## Problem frame

C7-T06's census found 42 `Aiur.GitHub.*` modules called from outside `github/`; the
access ones with the most callers are `ResourceStore` (20), `Transport` (9), `Errors`
(6) plus `Budget`, `LocalHold`, `ReadCache`, `AgentCache`, `Quota`. A reusable component
needs a contract smaller than "every module" (brainstorm.md KD2). C7-T07/T08 already
move Dispatcher off `LocalHold`, `CycleFetchCache`, `AuthPreflight` and `Errors`; this
ticket waits for them so it does not edit `dispatcher.ex` (U2-owned).

## Requirements

- R1, R7 (brainstorm.md); KD1, KD2.

## Key technical decisions

- **Facade groups (directional):** requests (`request/2`, `graphql/3`,
  `fetch_json_list_conditional/4`, `fetch_json_map/…`, `put_caller/2`); resources
  (`deposit`, `lookup`, `fetch(freshness:)`, `subscribe`, `key_for_repo`); cache
  (`invalidate`, `invalidate_number`, `invalidate_repo`); budget (`guard_settings`,
  `with_transient_retry/2` wrapping `LocalHold.run/2`, `snapshot`, `usage`); cost
  (`cost_report/1`, `reconciliation/1` for `aiur github-cost`/`github-usage`); errors
  (`classify/1`); agent wrapper (`wrapper_install_spec/1`, `agent_scrub_names/0`).
  Final names are the implementer's; each is a `defdelegate` or a one-line wrapper.
- **Census first.** Run the checker census at the head; the facade covers exactly the
  functions outside callers use. No speculative functions.
- **Errors stay structured.** The facade returns today's tuples and error terms; U5's
  typed outcomes pass through unchanged.
- **CLI renderers stay in control-cli/github.** `github_cost_cli.ex`,
  `github_usage_cli.ex` call `Access.cost_report/1` instead of `Quota`/`Budget`.

## Implementation units

### U1. Facade module

**Files:** `src/lib/aiur/github/access.ex` (new);
`src/test/aiur/github/access_facade_test.exs` (new).
**Test scenarios:**
- Each facade function returns the same value as the delegated module for one fixture
  input (table-driven).
- `Access.with_transient_retry/2` waits out one local hold then returns the result
  (mirror C7-T07 test 3).

### U2. Caller migration in batches

**Goal:** Every outside reference to an access module goes through `Aiur.GitHub.Access`.
**Files:** callers by component, one commit per component: `github` domain modules,
github-listeners (`events/github_webhook/deposit.ex`, pollers), orchestration (non-
Dispatcher files), build-orders, projections, web, control-cli, agent-sandbox
(`agent_github_guard.ex`, contributors from C7-T04). Re-run the census to list them.
**Approach:** Mechanical alias swaps; no logic change. Files over 500 lines may only
shrink (U8 size gate).
**Test scenarios:**
- Existing suites for each migrated component green.
- Checker: with `facades: ["Aiur.GitHub.Access"]` a fixture caller of
  `Aiur.GitHub.ResourceStore` fails the `private` rule. **Mutation:** add
  `ResourceStore` back to the facade list; fixture passes, test fails.

### U3. Declare the facade

**Files:** `components.json` (`github-access.facades = ["Aiur.GitHub.Access",
"Aiur.GitHub.Access.*"]`, `facade_pending` removed); allowlists of migrated components.
**Verification:** checker green with no `github-access` facade rows in any allowlist.

## Risks

- **Large mechanical diff.** Mitigation: batches per component; each batch is its own
  PR if it exceeds review size.
- **Hidden callers** through `apply/3` or module attributes (`@sources`). Mitigation:
  `git grep` for module atoms as strings after the swap.

## Definition of done

- Only `Aiur.GitHub.Access*` is referenced from outside github-access; checker enforces
  it; existing GitHub, orchestrator and build-order suites green.
