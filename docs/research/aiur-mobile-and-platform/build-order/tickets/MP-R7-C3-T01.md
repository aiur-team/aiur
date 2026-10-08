---
ticket_id: MP-R7-C3-T01
feature_id: MP-R7
chunk_id: MP-R7-C3
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Move the agent tool surface out of Aiur.Codex.DynamicTool into Aiur.AgentTools
status: ready
blocked_by: [DESIGN-R7, MP-R7-C1-T01, MP-R7-C1-T03]
prior_units: [U4, U7]
prior_boundaries: [CA (20), CDX (21), RUN (18)]
prior_features: []
prior_findings: []
size_owner: n/a (no moved file exceeds 500 lines; largest is errors.ex at 430)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C3-T01 — Move the agent tool surface out of `Aiur.Codex.DynamicTool`

## Identity and outcome

- Bucket 1 (refactor), feature MP-R7 (harness adapter), chunk C3 (remove upward leaks).
- **User value:** none directly. It removes the most-referenced backend-internal
  leak (runner, app-server core, Claude and OpenAI-compat adapters all call a
  module named after Codex). MP-E7-C5 (`read_messages` pull tool) and MP-E2 add
  tools to this surface; they must not add them under `Aiur.Codex.*`.
- **Deliverable:** the twelve `Aiur.Codex.DynamicTool*` modules (the facade plus
  eleven submodules, 12 files, census below) are renamed into
  the existing neutral namespace `Aiur.AgentTools` (which already holds
  `Aiur.AgentTools.Catalog` and `Aiur.AgentTools.MCP`). Every caller switches.
  Tool names, specs, argument validation, error payloads and quotas are
  byte-identical.
- **Non-goals:** no new tool, no tool rename, no change to which harness sees
  which tool, no change to `Aiur.AgentTools.MCP` behaviour. Not a split of
  `tool_executor.ex` (U8 `AGENT_TURN`).

## Dependencies and blockers

- **DESIGN-R7** (confirms no user-facing change).
- **MP-R7-C1-T01** (registry contract test) and **MP-R7-C1-T03** (provider-frame
  goldens: the `dynamicTools` arrays in Codex `thread/start` and Claude
  `thread/start` frames are pinned there) must merge first so this move is
  proved behaviour-preserving.
- Concurrency: may run in parallel with MP-R7-C3-T02, -T03, -T04 (disjoint
  files except `app_server/adapter.ex`, which only T01 touches in C3).
  Conflicts with any open PR touching `src/lib/aiur/codex/dynamic_tool/**`
  (rebase; this ticket is a rename).
- Consumers waiting on it: MP-E7-C5-T01 (pull tool), MP-E2 native-capture tickets.

## Verified starting point (base `45a290e3`)

- Modules (all under `src/lib/aiur/codex/`): `dynamic_tool.ex` (45 lines;
  `execute/3` :17-34, `tool_specs/0` :36-39, `reset_turn_quotas/0` :41),
  `dynamic_tool/{args 63, blockers 117, emit_alert 155, emit_event 157,
  errors 430, handler 9, linear_graphql 122, response 36, review_threads 141,
  subscriptions 131, ticket_state 124}.ex` — 1,530 lines in 12 files.
- Production callers outside the module tree (`git grep -n DynamicTool`):
  - `agent_runner/tool_executor.ex:25,104` (`execute/3`)
  - `agent_runner/queue_drain.ex:21,670` and `agent_runner/turn_loop.ex:8,117`
    (`reset_turn_quotas/0`)
  - `app_server/adapter.ex:12,63` (`execute/2` default tool executor)
  - `agent_tools/catalog.ex:4,7` (`tool_specs/0`)
  - `codex/frames.ex:6,52`, `claude/coding_agent.ex:19,234`,
    `open_ai_compat/tool_spec.ex:4,109` (`tool_specs/0`)
  - comment-only: `github/issue_dependencies.ex:8`, `claude/coding_agent.ex:7`.
- `src/mix.exs:42` lists `Aiur.Codex.DynamicTool` in coverage `ignore_modules`.
- Tests: 13 files under `src/test/aiur/codex/dynamic_tool/` plus
  `src/test/aiur/codex/dynamic_tool_test.exs` and `src/test/aiur/dynamic_tool_test.exs`;
  `src/test/aiur/claude/coding_agent_test.exs` and
  `src/test/aiur/agent_runner/tool_executor_test.exs` reference the module.
- Prior research: feature-boundaries §20 "Move in: `Codex.DynamicTool.*` (called
  by Claude, OpenAI-compat and the runner — it is not Codex-specific)"; MP-R1
  migration-plan row PR-02 assigns this path to the harness-adapters tool
  surface (step S7, owner MP-R7).

## Chosen design

- **Target namespace `Aiur.AgentTools`**, not `Aiur.Harness.*`. Rationale: the
  catalog already lives there (`agent_tools/catalog.ex:1`), and it is used by
  the MCP bridge (`agent_tools/mcp.ex`) as well as the app-server adapters, so
  it is the agent tool surface the prior survey names, not part of one harness.
  MP-R1's manifest puts it inside the `harness-adapters` component (PR-02), so
  the component boundary is unchanged.
- Rename map (PROPOSED paths):

  | Today | After |
  | --- | --- |
  | `Aiur.Codex.DynamicTool` (`codex/dynamic_tool.ex`) | `Aiur.AgentTools.Dispatch` (`agent_tools/dispatch.ex`) |
  | `Aiur.Codex.DynamicTool.<X>` (`codex/dynamic_tool/<x>.ex`) | `Aiur.AgentTools.<X>` (`agent_tools/<x>.ex`) |

  `Handler` (behaviour) becomes `Aiur.AgentTools.Handler`.
- Public functions keep names and specs: `Dispatch.execute/3`,
  `Dispatch.tool_specs/0`, `Dispatch.reset_turn_quotas/0`.
- **No compatibility shim** is left under `Aiur.Codex.DynamicTool`: a shim keeps
  the leak alive and the C3-T05 boundary rule would have to allowlist it.
  The module is internal (no config, CLI or docs name it; only historical plan
  docs under `docs/` do).
- Invariant: `Aiur.AgentTools.Catalog.specs()` returns the same list, in the
  same order, as `Aiur.Codex.DynamicTool.tool_specs()` at the base SHA.

## Implementation steps

1. `git mv src/lib/aiur/codex/dynamic_tool.ex src/lib/aiur/agent_tools/dispatch.ex`;
   `git mv` each `codex/dynamic_tool/<x>.ex` to `agent_tools/<x>.ex`. Rename
   `defmodule`, `@behaviour` and `alias` lines only. Update the moduledoc of
   `dispatch.ex` ("Executes client-side tool calls requested by coding-agent
   turns").
2. Update the eight production caller files listed above (comment-only
   mentions excluded) to alias
   `Aiur.AgentTools.Dispatch` (or call `Aiur.AgentTools.Catalog.specs/0` where
   only specs are needed — `codex/frames.ex`, `claude/coding_agent.ex`,
   `open_ai_compat/tool_spec.ex`; behaviour identical because `Catalog.specs/0`
   delegates to `tool_specs/0`).
3. Update comment references in `github/issue_dependencies.ex:8` and
   `claude/coding_agent.ex:7`.
4. `src/mix.exs`: **delete** `Aiur.Codex.DynamicTool` from `ignore_modules`
   (line 42) and do **not** add `Aiur.AgentTools.Dispatch` (CONTRIBUTING.md
   "The coverage `ignore_modules` list only shrinks"). The existing
   `dynamic_tool_test.exs` suites exercise `execute/3` for every handler.
5. `git mv` the 15 test files to `src/test/aiur/agent_tools/` (keep file
   names, prefix `dynamic_tool_` → none, e.g. `agent_tools/emit_alert_test.exs`;
   `codex/dynamic_tool_test.exs` → `agent_tools/dispatch_test.exs`;
   `dynamic_tool_test.exs` → `agent_tools/dispatch_integration_test.exs`).
   Rename module names inside.
6. Account for every remaining hit:
   `mise exec -- rg -n --fixed-strings -- 'Codex.DynamicTool' src/ scripts/`
   must return nothing (CONTRIBUTING.md "Testing", rename rule).

Expected diff: ~1,530 moved lines (reported separately as moves), under 60
changed production lines.

## Non-happy paths

- **Unknown tool:** the "Unsupported dynamic tool" failure payload
  (`dynamic_tool.ex:27-32`) keeps its exact text; agents and goldens key on it.
- **Quota reset ordering:** `reset_turn_quotas/0` is called before each turn in
  both `turn_loop.ex:117` and `queue_drain.ex:670`; the rename must not change
  that call order (it returns `:ok` and is pattern-matched).
- **Hot code / release:** the release is rebuilt as a whole (`aiurdev build`),
  so no stale-module window exists in production.
- **Privacy/security:** no change; the guard on `task.*`/`agent.*` scopes in
  `emit_alert` moves verbatim.

## Compatibility and rollout

No config, CLI, flag, env var or rendered string changes. No migration.
Rollback: revert the PR. Docs under `docs/plans/` and `docs/brainstorms/`
that name `Aiur.Codex.DynamicTool` are historical and are not edited.

## Verification

Tests (all must pass unchanged in assertions; only module names change):

- `agent_tools/dispatch_test.exs` (moved) — every existing case.
- **New** `test "catalog specs are unchanged by the move"` in
  `src/test/aiur/agent_tools/catalog_test.exs` (PROPOSED): asserts
  `Catalog.names()` equals the literal ordered list of tool names at the base
  SHA (record the list from `45a290e3` when writing the test) and that every
  spec map's `"name"`, `"description"` and `"inputSchema"` keys exist.
  This is a **guard test** (it passes on main by design) and is named as such
  in its `describe` block; it is not counted as coverage for this move.
- MP-R7-C1-T03 provider-frame goldens (Codex and Claude `thread/start`
  `dynamicTools`) pass unchanged.
- Mutation check: the move adds no behaviour, so no new test can fail with the
  production hunk reverted; state this in the PR body. Instead, prove the
  goldens bind the surface: in a scratch worktree, delete one handler from
  `@handlers` in `dispatch.ex` and confirm MP-R7-C1-T03 and the catalog guard
  test fail.

Commands (from repo root). `mix test` boots aiur and writes
`~/.aiur/github-budget`, so every test command isolates `HOME` and
`XDG_CONFIG_HOME` and unsets `GITHUB_TOKEN`/`GH_TOKEN` (review T-4):

```text
env -C src mise exec -- mix compile --warnings-as-errors
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test test/aiur/agent_tools/ test/aiur/agent_runner/tool_executor_test.exs test/aiur/claude/coding_agent_test.exs test/aiur/codex/coding_agent_test.exs test/aiur/open_ai_compat/
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix aiur.affected_tests
env -C src mise exec -- mix lint
mise exec -- rg -n --fixed-strings -- 'Codex.DynamicTool' src/ scripts/
```

Manual: none required beyond CI (no rendered change); the C4 foreground run
covers it.

## Completion and handoff

- [ ] No `Aiur.Codex.DynamicTool` reference remains in `src/` or `scripts/`.
- [ ] `ignore_modules` is one entry shorter; coverage gate passes.
- [ ] C1 characterization and frame goldens pass unchanged.
- [ ] PR body reports moved vs changed lines and the mutation statement.
- Docs: none (no user-facing surface; AGENTS.md "Docs ship with the change"
  does not apply). MP-R7-C6-T01 documents the tool surface for contributors.
- Dependents: MP-R7-C3-T05 (boundary rule drops this edge), MP-E7-C5-T01,
  MP-E2 native capture.
