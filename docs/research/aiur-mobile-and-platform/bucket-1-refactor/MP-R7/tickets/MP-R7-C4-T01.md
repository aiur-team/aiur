---
ticket_id: MP-R7-C4-T01
feature_id: MP-R7
chunk_id: MP-R7-C4
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Harness-declared supervision children (remove the composition root's Claude edge)
status: ready
blocked_by: [DESIGN-R7, MP-R7-C3-T03]
prior_units: [U7]
prior_boundaries: [CLI (31), CLD (22), CA (20)]
prior_features: []
prior_findings: []
size_owner: n/a (src/lib/aiur.ex is outside the U8 harness owners; edit is < 20 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C4-T01 — Harness-declared supervision children

## Identity and outcome

- Bucket 1, MP-R7, chunk C4 (component shape). **User value:** none directly.
- **Deliverable:** registry entries may declare `:children` (child specs the
  harness needs before the orchestrator starts). `Aiur.CodingAgent.child_specs/0`
  collects them, de-duplicated, in registry `init_order`.
  `Aiur.child_specs/1` (`src/lib/aiur.ex`) splices that list where
  `Aiur.Claude.Telemetry` sits today. This meets MP-R1 promotion criterion 2
  ("child specs, boot order and restart strategy are declared by the component
  and assembled by the composition root", migration-plan §5) for the harness
  component and removes allowlist row 8 of MP-R7-C3-T05.
- **Non-goals:** no change to child order, restart strategy (`:rest_for_one`,
  `aiur.ex:85-118`) or which run shapes start the child.

## Dependencies and blockers

- DESIGN-R7; MP-R7-C3-T03 (adds the `:launch_telemetry` key that names the same
  module; doing both in one registry pass avoids two edits of `providers/claude.ex`).
- Concurrency: parallel with C3-T05 (it deletes row 8 if it merges second) and
  C6. Conflicts with any PR reordering `aiur.ex` children — rebase and keep the
  ordering test green.

## Verified starting point (base `45a290e3`)

- `src/lib/aiur.ex:430-432`: comment "Claude telemetry owns an independent
  loopback listener and must be available before the Orchestrator starts owned
  Claude workers." then `Aiur.Claude.Telemetry` in the base child list, in every
  run shape; `child_specs/1` is pure (`aiur.ex:226-243`).
- Only harness process in the application tree: `git grep -n -E 'Aiur\.(Codex|Claude|Muse|OpenAICompat)' 45a290e3 -- src/lib/aiur.ex`
  returns only :432.
- `Aiur.Claude.Telemetry` is a GenServer (`claude/telemetry.ex:10,128`).
- Guard test: `src/test/aiur/application_test.exs:505-517`
  "Claude telemetry is dashboard-independent and starts before the orchestrator"
  (both run shapes); module list at :129.

## Chosen design

- New optional registry key `:children :: [Supervisor.child_spec() | module()]`.
  Set on `claude` (headless) only — `claude-repl` shares the process; the
  collector de-duplicates by child id, so declaring it on both would also work,
  but one declaration keeps ownership obvious.
- `CodingAgent.child_specs/0` (PROPOSED):
  `backends() |> Enum.sort_by(&elem(&1, 1)[:init_order] || 99) |> Enum.flat_map(&Map.get(elem(&1, 1), :children, [])) |> Enum.uniq_by(&Supervisor.child_spec(&1, []).id)`.
- `aiur.ex`: replace the literal with `CodingAgent.child_specs() ++` at the same
  list position (keep the comment, reworded: "harness children (today: Claude
  launch telemetry) must start before the Orchestrator").
- Invariant: the resulting `Aiur.child_specs/1` module list is identical to the
  base SHA's for every run shape tested in `application_test.exs`.

## Implementation steps

1. `backend.ex` typedoc + type: `optional(:children) => [Supervisor.child_spec() | module()]`.
2. `providers/claude.ex` `headless/0`: `children: [Aiur.Claude.Telemetry]`.
3. `coding_agent.ex`: `child_specs/0` with `@spec`, `@doc`.
4. `aiur.ex`: splice; the list is built with `++` already (`aiur.ex:463-484`),
   so the change is local.
5. MP-R7-C1-T01 contract test: every `:children` element is a valid child spec
   (`Supervisor.child_spec/2` does not raise).

## Non-happy paths

- **Test singleton:** the test app starts the same tree; `Aiur.Claude.Telemetry`
  already runs there, so no new process appears.
- **Fake backend** (test-only registry entry): declares no children, so test
  and prod trees stay equal apart from what exists today.
- **Duplicate declaration** in a future entry → de-duplicated by id; a
  conflicting spec for the same id raises at boot (Supervisor duplicate id),
  which the contract test catches first.

## Compatibility and rollout

No config, flag or user-visible change. Rollback: revert.

## Verification

1. Existing `application_test.exs:505` test passes unchanged (guard; named as
   such in the PR).
2. **New** `src/test/aiur/application_test.exs`:
   `test "child module list is unchanged by harness-declared children"` —
   for each of the four run shapes in the file, `modules(AiurApp.child_specs(opts))`
   equals a literal list captured from `45a290e3` (recorded in the test).
   Guard by design; it constrains order, not just presence.
3. **New** `src/test/aiur/coding_agent_test.exs`:
   `test "child_specs/0 collects registry-declared children once, in init_order"`
   — with an injected registry of two entries declaring the same module and one
   other → `[A, B]`. Mutation: remove `Enum.uniq_by` → test fails; remove the
   `sort_by` → test fails (fixture orders entries against `init_order`).

Commands (isolated `HOME`, GitHub tokens unset):

```text
env -C src mise exec -- mix test test/aiur/application_test.exs test/aiur/coding_agent_test.exs
mise exec -- rg -n 'Aiur\.Claude' src/lib/aiur.ex
```

The last command prints nothing.

## Completion and handoff

- [ ] `aiur.ex` names no harness module; child order unchanged.
- [ ] Test 3 fails with each mutation (PR body).
- [ ] MP-R7-C3-T05 allowlist row 8 removed (in this PR if C3-T05 merged first).
- Docs: none user-facing; C6-T01 lists the `:children` key.
- Dependents: MP-R7-C4-T02 (promotion criterion 2 evidence).
