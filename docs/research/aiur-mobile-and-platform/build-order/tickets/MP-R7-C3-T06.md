---
ticket_id: MP-R7-C3-T06
feature_id: MP-R7
chunk_id: MP-R7-C3
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Config validation reads the backend catalog through a registered semantic check (remove config → Aiur.CodingAgent edges)
status: blocked
blocked_by: [DESIGN-R7, MP-R1-C4-T01, MP-R1-C4-T03, MP-R7-C3-T05]
prior_units: [U4, U7]
prior_boundaries: [CA (20), K (1)]
prior_features: [MP-R1 (C4 config split)]
prior_findings: [CR-R1-7 (Phase D contract-requests resolution)]
size_owner: "src/lib/aiur/config.ex: U8 CONFIG owner (look up at the implementation SHA, RC-23)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C3-T06 — Backend catalog feeds config by registration

Created in Phase D from contract request CR-R1-7: MP-R1-C4-T03 leaves these
edges allowlisted with owner MP-R7, and no MP-R7 ticket owned them. Rewritten in
the Phase D fix pass (review T-9) to full brief §9 depth.

## Identity and outcome

- Bucket 1, MP-R7, chunk C3. Waits for the U0 review (RC-19, plan "U0 review
  gate"). **User value:** none visible; behaviour-preserving. The `config`
  component (L0) stops referencing the `harness-adapters` facade (L2), which the
  R-down rule forbids.
- **Deliverable:**
  1. PROPOSED behaviour `Aiur.Config.BackendCatalog` (in `config`, L0) with the
     catalog questions config asks today.
  2. PROPOSED provider `Aiur.CodingAgent.ConfigCatalog` (harness-adapters) that
     answers them from `Aiur.CodingAgent.Registry.entries/0`, named in
     `config :aiur, :backend_catalog, Aiur.CodingAgent.ConfigCatalog`
     (`src/config/config.exs`, the composition root, as for capability providers).
  3. Every `Aiur.CodingAgent` reference under `src/lib/aiur/config*` removed
     (census below), and allowlist row 14 of MP-R7-C3-T05 deleted.
- **Non-goals:** new config keys, changed error text, changed defaults, the
  agent-kind dispatchable check (`config.ex:1327`, moved by MP-R1-C4-T01 to
  `Aiur.CodingAgent.SemanticCheck.Dispatchable`).

## Dependencies and blockers

- DESIGN-R7 (no-change confirmation).
- MP-R1-C4-T01 (semantic-check registry; it takes `config.ex:1327`).
- MP-R1-C4-T03 (the other config edges are gone, so this PR removes the last
  config → harness rows).
- MP-R7-C3-T05 (allowlist row 14 exists and is deleted here).

## Verified starting point (`45a290e3`)

Census: `git grep -n "CodingAgent" 45a290e3 -- src/lib/aiur/config.ex src/lib/aiur/config/`.

| Site | Call | Kind |
| --- | --- | --- |
| `config.ex:319` | `Aiur.CodingAgent.default_backend()` | runtime accessor |
| `config.ex:396` | `Aiur.CodingAgent.rate_limit_fallback_targets()` | runtime accessor |
| `config.ex:495` | `Aiur.CodingAgent.complexity_level(issue)` | runtime accessor |
| `config.ex:1405-1407` | `configurable_backends()`, `default_config_backend()` | runtime (`inferred_agent_kind/1`) |
| `config.ex:1413` | `known_backends()` | runtime (`backend_config_sections/2`) |
| `config/schema/agent.ex:120,209,210` | `default_backend()`, `default_rate_limit_fallback()` as Ecto `field` defaults | **compile time** |
| `config/schema/agent.ex:357,366,434,447-448` | `known_backends()`, `rate_limit_fallback_targets()` | changeset validation |
| `config/schema/agent.ex:387` | `get_in(backends(), [backend, :config_validator])` | changeset validation |
| `config/schema/agent.ex:418` | `dispatchable_backends(...)` | changeset validation |
| `config/schema/agent_validation.ex:7,132` | `alias Aiur.CodingAgent.Models`; `CodingAgent.models(backend)` | changeset validation |
| `config/routing_value.ex:25` | doc comment only | not an edge |

Registry values at base: `codex` has `default: true` and
`rate_limit_fallback: "claude"` (`coding_agent/providers/codex.ex:15-16`);
`claude` has `config_default: true` (`providers/claude.ex:14`). The catalog
functions are `coding_agent.ex:84-170`.

## Chosen design

- `Aiur.Config.BackendCatalog` callbacks: `known_backends/0`,
  `default_backend/0`, `default_config_backend/0`,
  `default_rate_limit_fallback/0`, `rate_limit_fallback_targets/0`,
  `configurable_backends/0`, `dispatchable_backends/1`, `config_validator/1`,
  `models/1`, `ambiguous_model_alias?/2`, `complexity_level/1`. Each delegates
  1:1 to today's function, so results are identical.
- `Aiur.Config.BackendCatalog.impl/0` reads `Application.fetch_env(:aiur,
  :backend_catalog)` at call time. The module name is data, so the checker sees
  no `config → harness-adapters` edge.
- **Compile-time defaults** (`agent.ex:120,209,210`) cannot call a provider
  registered at boot. They become module attributes in `Schema.Agent`
  (`@default_backend "codex"`, `@default_rate_limit_fallback "claude"`) with a
  drift test in harness-adapters' suite that asserts they equal the catalog's
  answers.
- **No provider configured** (a lean test composition): nothing raises;
  `impl/0` returns `{:error, :backend_catalog_unavailable}`, validators
  add that error to the changeset, and accessors return the same tuple. The code
  never assumes an empty catalog.

## Implementation steps

1. Add `src/lib/aiur/config/backend_catalog.ex` (behaviour + `impl/0`).
2. Add `src/lib/aiur/coding_agent/config_catalog.ex` implementing it by
   delegation; add `config :aiur, :backend_catalog, ...` to `src/config/config.exs`.
3. Replace each runtime and validation site in the census with
   `BackendCatalog` calls; keep error atoms and messages byte-identical.
4. Replace the three compile-time defaults with module attributes.
5. Delete allowlist row 14 (MP-R7-C3-T05) and run the checker.

## Non-happy paths

- Provider not configured → `{:error, :backend_catalog_unavailable}` in the
  changeset (test 2); boot with the real composition is unchanged.
- A registry change moves the default backend → the drift test (test 3) fails
  until the attribute is updated in the same PR.
- `complexity_level/1` on an issue without a level → unchanged `nil` path.
- Stale allowlist row left behind → MP-R1-C1-T05 ratchet fails.

## Compatibility and rollout

Behaviour-preserving; no config keys, messages or defaults change. One PR,
rollback by revert. Rebase onto U4 if it lands first (MP-R7 interlock S7 vs U4).

## Verification

Tests (all run with the canonical isolated command):

1. Existing `src/test/aiur/config_test.exs`, `src/test/aiur/config/schema_test.exs`,
   `src/test/aiur/config/priority_routes_test.exs`,
   `src/test/aiur/config/max_turns_by_complexity_test.exs` pass unchanged
   (same messages for unknown backends and bad fallback targets).
2. New `src/test/aiur/config/backend_catalog_test.exs`:
   `"validation reports backend_catalog_unavailable when no provider is configured"`
   (`Application.put_env(:aiur, :backend_catalog, nil)` in the test, restored
   on exit). Mutation: replace that branch with `[]` → the test fails.
3. New `src/test/aiur/coding_agent/config_catalog_test.exs`:
   `"schema compile-time defaults equal the registry's answers"` — asserts
   `%Schema.Agent{}.kind == CodingAgent.default_backend()` and the fallback
   pair. Mutation: change `@default_backend` to `"claude"` → fails.

```text
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/config_test.exs test/aiur/config/ \
  test/aiur/coding_agent/config_catalog_test.exs
python3 scripts/check-components.py
```

`python3 scripts/check-components.py` reports no `config → harness-adapters`
edge. Report the mutation commands in the PR body (AGENTS.md).

## Completion and handoff

- [ ] `git grep -n "CodingAgent" -- src/lib/aiur/config.ex src/lib/aiur/config/`
      returns only the `routing_value.ex` doc comment.
- [ ] Allowlist row 14 deleted; tests 2 and 3 mutation-checked.
- Docs: none (internal, no interface change).
