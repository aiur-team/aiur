---
ticket_id: MP-R1-C4-T2
feature_id: MP-R1
chunk_id: MP-R1-C4
bucket: 1-refactor
title: Registered turn-sandbox root contributors - codex runtime settings stop calling AgentEnvironment, GitHub.Budget and BuildGate
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T2]
prior_units: [U8]
prior_boundaries: ["CFG #2", "#17 agent sandbox", "GHB #6", "CDX #21"]
prior_features: [MP-R7]
prior_findings: []
size_owner: "src/lib/aiur/config.ex: U8 CONFIG (1,462 lines) — this ticket must shrink it"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C4-T2 — Turn-sandbox root contributors

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C4. Step S9.
- **User value:** none visible. The writable roots an agent's Codex sandbox receives are
  contributed by the components that own them (package caches, GitHub budget state, the
  build gate), so config stops depending on agent-sandbox (L2) and github (L2, optional).
- **Deliverable:**
  - PROPOSED behaviour `Aiur.Config.TurnSandboxRoots`:
    `@callback contribute(policy :: map(), settings :: struct(), opts :: keyword()) :: {:ok, map()} | {:error, term()}`
    (returns the possibly-extended policy, so each contributor keeps its own guard logic).
  - Registry `config :aiur, :turn_sandbox_root_contributors, [Aiur.AgentEnvironment.SandboxRoots, Aiur.GitHub.Budget.SandboxRoots, Aiur.BuildGate.SandboxRoots]`
    — the current order.
  - `codex_runtime_turn_sandbox_policy/3` (`config.ex:1226-1233`) becomes
    `Schema.resolve_runtime_turn_sandbox_policy/3` then `Enum.reduce_while` over the
    registry.
  - The three `maybe_add_*` private functions (`config.ex:1235-1295`) move verbatim into
    the contributor modules; `Schema.add_runtime_turn_sandbox_roots/2` and the shared
    `workspace_write_policy?/1`, `policy_writable_roots/1` helpers become public in
    `Aiur.Config.Schema` (config component) so contributors call down, not up.
- **Edges removed:** `Aiur.Config → Aiur.AgentEnvironment` (`:1245`),
  `→ Aiur.GitHub.Budget` (`:1257`), `→ Aiur.BuildGate` (`:1278`).
- **Non-goals:** changing any root, condition or order; Claude/OpenAI-compat sandboxes.

## Dependencies and blockers

- DESIGN-R1 §1; C1-T2. Same-file serialization with C4-T1/T3/T4.
- **Concurrent with** MP-R7 work on `codex/` (no shared lines).
- **Dependents:** C1-T3's R-optional count drops (config → github was required→optional).

## Verified starting point (`45a290e3`)

- `codex_runtime_settings/2` (`config.ex:1210-1224`) → `codex_runtime_turn_sandbox_policy/3`
  (`:1226-1233`): `with resolve_runtime → maybe_add_package_manager_roots →
  maybe_add_github_budget_root → maybe_add_build_gate_root`.
- Guards: each contributor returns the policy unchanged when `opts[:remote]` is true or
  the policy is not workspace-write; the budget one also when `Budget.enabled?/0` is
  false and calls `Budget.ensure_state_dir/0`; the build-gate one reads
  `settings.agent.max_concurrent_builds`, `build_start_stagger_seconds`,
  `min_free_memory_mb` and `BuildGate.prepare_writable_root/1` with effective roots
  (`:1266-1294`).
- Tests: `src/test/aiur/workspace_and_config_test.exs` calls
  `Config.codex_runtime_settings` at `:135, :2022, :2052, :2934, :2951, :2971, :3074, :3079`
  (local vs remote, package caches, approval policy).

## Chosen design

- `reduce_while` stops at the first `{:error, _}` exactly like the current `with`.
- Contributors receive `settings` (already loaded) to avoid a second `settings!/0` read.
- Empty registry → policy unchanged (a deliberate difference from C4-T1's fail-closed:
  an absent contributor means that component is not installed, and today a disabled
  budget/gate already yields the unchanged policy). Record this in the module doc.

## Implementation steps

1. Characterization test on unchanged code: for a workspace-write policy, assert the
   ordered writable roots for (a) local, budget on, gate on; (b) remote; (c) budget off;
   (d) gate prepare error → `{:error, _}` propagated.
2. Behaviour + reduce; three contributor modules (verbatim moves).
3. Registry in `config.exs`; delete old private functions.
4. Manifest: contributor files owned by agent-sandbox (AgentEnvironment, BuildGate) and
   github (Budget).

## Non-happy paths

- Budget `ensure_state_dir` error → same `{:error, reason}` as today.
- Contributor raises → propagates as today (no new rescue).

## Compatibility and rollout

No config or behaviour change. Rollback: revert.

## Verification

PROPOSED `src/test/aiur/config/turn_sandbox_roots_test.exs` (characterization, green
before and after) plus the existing `workspace_and_config_test.exs` cases.

| Case | Expected |
|---|---|
| local, budget and gate enabled | roots = base ++ package caches ++ [budget dir] ++ [gate dir], in that order |
| remote | base roots only |
| budget disabled | no budget dir |
| gate prepare fails | `{:error, reason}`; package roots not leaked into a returned policy |
| order follows registry | reversed registry in a test env → order reversed (proves the registry drives order) |

Command: `$TESTCMD test/aiur/config/turn_sandbox_roots_test.exs test/aiur/workspace_and_config_test.exs`.

Mutation check: the "order follows registry" test fails if the implementation hardcodes
the three calls (the regression target of this ticket). The first four rows are
regression guards that must pass before and after.

Checker: three allowlist lines become stale; delete them.

## Completion and handoff

- [ ] Three edges removed; `config.ex` shorter.
- [ ] Docs: none.
- **Dependents:** C4-T5; MP-R7 (harness-owned contributors can register later).
