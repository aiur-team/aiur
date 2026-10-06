---
ticket_id: MP-R7-C4-T03
feature_id: MP-R7
chunk_id: MP-R7-C4
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Physical aiur_harness package skeleton; move contract, registry and AppServer core
status: blocked
blocked_by: [DESIGN-R7, MP-R7-C4-T02 (go), CR-R7-1 (MP-R1 physical form for Elixir components), U8 AGENT_CORE split of coding_agent.ex, MP-R1-C7-T3 (agent sandbox), MP-R1-C5-T2 (kernel process helpers)]
prior_units: [U7, U8]
prior_boundaries: [CA (20), #17 agent sandbox, K (1)]
prior_features: []
prior_findings: []
size_owner: AGENT_CORE (src/lib/aiur/coding_agent.ex, 1,179 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C4-T03 — `aiur_harness` package skeleton and core move

## Identity and outcome

- Bucket 1, MP-R7, chunk C4. **Conditional:** executes only if MP-R7-C4-T02
  records **go**. On no-go this ticket stays blocked and is re-evaluated at the
  next MP-R1-C11 plan refresh.
- **Deliverable:** a separate Mix project for the harness component, in the
  location and form MP-R1 fixes (CR-R7-1), containing the contract
  (`Aiur.CodingAgent.Backend`), the registry (`Aiur.CodingAgent`,
  `coding_agent/**`), the shared app-server core (`app_server/**`) and the
  agent tool surface (`agent_tools/**`). The main app depends on it. Module
  names do not change (plan: "`Aiur.CodingAgent.Backend` kept so no caller
  breaks"; renaming to `Aiur.Harness.*` is not required by any consumer and
  would only churn call sites).
- **Non-goals:** moving adapters (T04); release packaging check (T05).

## Dependencies and blockers

- MP-R7-C4-T02 = go.
- **CR-R7-1 (contract request to MP-R1):** MP-R1 names the forms ("Mix app /
  npm package / repository", migration-plan §5) but not where an in-repo Elixir
  component package lives (e.g. `src/apps/<name>` umbrella child vs
  `packages/<name>` path dependency) or how `mix release` includes it. This
  ticket cannot pick it without making an R1 decision.
- `coding_agent.ex` is 1,179 lines (U8 owner `AGENT_CORE`); moving it creates a
  new >500 path, which the U8 transitional gate rejects (prior KTD1; MP-R1
  migration-plan §1 "A move must not create a file over 500 lines"). The
  AGENT_CORE split (prior boundary §20: "split `CodingAgent` into registry,
  routing and model grammar") must land first. Per RC-23 the implementer
  re-checks the owner against the then-current U8 ledger.
- The package's required deps are kernel, config and agent sandbox (MP-R1
  component-map row `harness-adapters`); those must exist as importable units
  first (MP-R1-C5-T2, MP-R1-C7-T3), or the package carries a temporary
  dependency on the main app, which would be a cycle — not allowed.

## Verified starting point (base `45a290e3`)

- One Mix app: `src/mix.exs:6-7` (`app: :aiur`, version 0.0.9). No umbrella,
  no `apps/` directory.
- Files to move: `src/lib/aiur/coding_agent.ex` (1,179),
  `src/lib/aiur/coding_agent/**`, `src/lib/aiur/app_server/**`,
  `src/lib/aiur/agent_tools/**` (after MP-R7-C3-T01). Total harness component
  at base: 140 files under the component paths (`git ls-tree`).
- Coverage `ignore_modules` (`src/mix.exs`) lists `Aiur.CodingAgent` and
  other harness modules; a new Mix project needs its own coverage config, and
  the list may not grow (CONTRIBUTING.md "Enforcement").

## Chosen design

Fixed by this ticket regardless of CR-R7-1's answer:

- Module names unchanged; only file locations and the Mix project boundary move.
- The package has no compile-time reference to `Aiur.Orchestrator`,
  `AiurWeb`, `Aiur.AgentRunner` (checked by the MP-R1 checker and by
  `mix xref graph --label compile-connected` showing no edge into the main app).
- Upward needs are met by registry callbacks or app env set at boot by the
  composition root (MP-R1 rule R-down).

Left to CR-R7-1: directory, umbrella vs path dependency, release assembly.

## Implementation steps

1. Create the package per CR-R7-1 with `mix.exs`, its own `test_helper.exs`
   and coverage config (no new `ignore_modules` entries).
2. `git mv` contract, registry, app-server core and agent tool surface.
3. Main app `mix.exs` declares the dependency; `config/config.exs` keeps
   working (no config key moves).
4. Move the corresponding tests (`src/test/aiur/{coding_agent,app_server,agent_tools}/**`,
   `coding_agent_test.exs`).

## Non-happy paths

- Compile-time cycle discovered (`mix xref graph --format cycles`): stop and
  record the edge; do not add an allowlist for a compile cycle.
- Release missing the package: caught by T05.

## Compatibility and rollout

No config, CLI or behaviour change. Rollback: revert the move PR (no on-disk
state involved; MP-R1 migration-plan §6).

## Verification

- Full suite of both projects green in CI; MP-R7-C1 characterization suite
  unchanged.
- `env -C src mise exec -- mix xref graph --format cycles` reports no cycle
  involving the package.
- `python3 scripts/check-components.py` green.
- Mutation: add `alias Aiur.Orchestrator` in a package module in a scratch
  branch → the package fails to compile (dependency not declared). That is the
  proof the physical boundary binds.

## Completion and handoff

- [ ] Package builds and tests alone; main app builds against it.
- [ ] No file > 500 lines created.
- Docs: C6-T01 updated with the package path.
- Dependents: MP-R7-C4-T04, -T05.
