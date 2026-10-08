---
ticket_id: MP-R7-C1-T01
feature_id: MP-R7
chunk_id: MP-R7-C1
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Registry-wide harness contract test
status: ready
blocked_by: [DESIGN-R7]
prior_units: [U4]
prior_boundaries: [CA (20), CDX (21), CLD (22), OAI (23)]
prior_features: []
prior_findings: [MP-R7 plan F1, F2, F11]
size_owner: n/a (new test file only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C1-T01 — Registry-wide harness contract test

## Identity and outcome

- Bucket 1 (refactor), feature MP-R7, chunk C1 (characterize), ticket T01.
- **User value:** none visible. Every later R7 move (C2 descriptor, C3 leak
  cuts, C4 package move) is proved not to break a registered harness.
- **Deliverable:** one new ExUnit file that iterates over every entry of
  `Aiur.CodingAgent.Registry.entries/0` and asserts the backend contract.
- **Non-goals:** no production change; no new capability key; no assertion
  about delivery behaviour (that is T02/T03).

## Dependencies and blockers

- Blocked by **DESIGN-R7** (owner gate: confirm no user-facing change).
- No predecessor ticket. May run concurrently with C1-T02, C1-T03 and C5-T01.
- Shared contract: [harness-adapter §2–§3](../../../contracts/harness-adapter.md).
- **RC-22 (conditional, soft):** if draft PR #2870 (Gemini/ACP backend) merges
  first, this test covers the `gemini` entry automatically because it iterates
  the registry. No code change in this ticket is needed for that; do not add a
  Gemini-specific assertion here.

## Verified starting point (base `45a290e3`)

- Behaviour: `src/lib/aiur/coding_agent/backend.ex:117-147` — required
  callbacks `start_session/2`, `run_turn/4`, `stop_session/1`,
  `normalize_event/1`, `send_operator_message/2`; optional `interrupt/1`
  (`@optional_callbacks interrupt: 1`, :147).
- Required registry keys (type `capabilities`, `backend.ex:80-115`):
  `adapter`, `transcript`, `family`, `can_interrupt`, `safe_checkpoints`,
  `remote_control`, `resumable`, `models`, `efforts`.
- Registry: `src/lib/aiur/coding_agent/registry.ex:7-16` — `codex`, `claude`,
  `claude-repl`, `muse`, plus `Aiur.OpenAICompat.Registry.entries/0`
  (`kimi`, `deepseek`, `openrouter`; shared defaults at
  `open_ai_compat/registry.ex:107-130`), plus `fake` in `Mix.env() == :test`
  (`registry.ex:20-29`; `coding_agent/providers/fake.ex` reuses
  `Aiur.Codex.CodingAgent` as its adapter).
- Cross-references inside entries: `remote_transport: "claude-repl"`
  (`providers/claude.ex:30`), `fallback_backend: "claude"` (`providers/claude.ex:110`),
  `rate_limit_fallback: "claude"` (`providers/codex.ex:16`),
  `model_catalog_backend: "claude"` (`providers/claude.ex:94`).
- `immediate_delivery: true` only on `claude-repl`, with `safe_checkpoints: []`
  (`providers/claude.ex:101-103`).
- **Existing coverage (checked, no duplicate):** `src/test/aiur/coding_agent_test.exs`
  tests presentation descriptors, routing and `select_for_dispatch`; no test
  walks every entry against the behaviour or checks cross-key consistency
  (searched `src/test` for `Registry.entries` and `CodingAgent.backends()`:
  only `coding_agent_test.exs`, `init_test.exs`, `model_discovery_test.exs`,
  none of which assert the contract).

## Chosen design

A table-free property test over the live registry, so a new backend is
covered the day it is registered (the moduledoc rule at `backend.ex:5-15`).

Assertions per `{key, entry}`:

1. Every required key above is present.
2. `Code.ensure_loaded?(entry.adapter)` and the adapter exports each required
   callback with the right arity (`function_exported?/3`); `entry.transcript`
   loads.
3. If the adapter exports `interrupt/1`, `entry.can_interrupt == true`.
4. `immediate_delivery: true` ⇒ `safe_checkpoints == []`.
5. `remote_transport`, `fallback_backend`, `rate_limit_fallback` and
   `model_catalog_backend`, when present, name a registered key, and a
   `fallback_backend` is never the entry's own key.
6. `safe_checkpoints` is a list whose members are in
   `[:notification, :tool_result]` (the only values used at base).

Invariant pinned as a guard: assertion 4 is the one rule the plan names
(acceptance criterion 1).

## Implementation steps

1. Add `src/test/aiur/coding_agent/registry_contract_test.exs` (PROPOSED),
   `use ExUnit.Case, async: true`, module tag `@moduletag :r7_characterization`
   (tag consumed by C1-T04).
2. Build the iteration with `for {key, entry} <- Aiur.CodingAgent.Registry.entries()`
   generating one `test "#{key} satisfies the backend contract"` per entry at
   compile time is **not** possible (registry is runtime); use a single test
   per assertion family that collects failures into a list and asserts
   `failures == []`, so the failure message names every bad key.
3. No production file changes.

## Non-happy paths

- Unknown future key (e.g. `gemini`): covered automatically; if its adapter
  lacks a callback the test fails, which is the intended alarm.
- `fake` is test-only and reuses the Codex adapter; it must pass too, so it
  stays a real consumer of the contract (`registry.ex:18-19`).
- No secrets, processes or I/O touched.

## Compatibility and rollout

n/a — test-only; no config, flag, migration or packaging effect.

## Verification

Tests (all in `registry_contract_test.exs`):

| Test name | Expected at `45a290e3` |
| --- | --- |
| `every entry declares the required capability keys` | pass |
| `every adapter implements the required backend callbacks` | pass |
| `an adapter exporting interrupt/1 declares can_interrupt` | pass |
| `immediate delivery implies no safe checkpoints` | pass |
| `cross-entry references name registered backends` | pass |

Command (from `src/`): `mise exec -- mix test test/aiur/coding_agent/registry_contract_test.exs`

**Regression guard, not new coverage:** every test passes on main by design
(characterization, AGENTS.md "Keeping a test that already passes on main").
Mutation witnesses the implementer must run in a worktree and record in the PR:

- `providers/claude.ex:102` `safe_checkpoints: []` → `[:notification]`:
  `immediate delivery implies no safe checkpoints` fails.
- `providers/claude.ex:110` `fallback_backend: "claude"` → `"claude-headless"`:
  `cross-entry references name registered backends` fails.
- delete `def send_operator_message` clauses in `muse/coding_agent.ex:20-29`:
  `every adapter implements the required backend callbacks` fails (compile
  warning only for `@impl`; the test is what fails).

## Completion and handoff

- [ ] Test file added, tagged `:r7_characterization`, passes on main.
- [ ] Three mutation witnesses recorded in the PR body with exact commands.
- [ ] No production diff.
- Docs: none (test-only, AGENTS.md "Docs ship with the change" exempts it).
- Dependents: C1-T04 (suite tag), C2-T01 (adds the `delivery` key assertion),
  C4-* (must stay green after the package move).
