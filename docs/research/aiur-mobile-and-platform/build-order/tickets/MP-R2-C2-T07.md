---
ticket_id: MP-R2-C2-T07
feature_id: MP-R2
chunk_id: MP-R2-C2
bucket: 1 (refactor)
title: Inject the IdGenerator's cold-boot floor sources from app boot (no Executor/launch-state edges in the bus)
status: ready
blocked_by: [DESIGN-R2 §1, MP-R2-C1-T06]
prior_units: [U8]
prior_boundaries: [BUS #10, EXE #26, K #1]
prior_features: []
prior_findings: [MP-R2 Phase C finding "IdGenerator scans the Executor journal"]
size_owner: n/a (id_generator.ex 365 lines; must stay ≤ 500); aiur.ex APP_BOOT 610 (must not grow); re-check per RC-23
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C2-T07 — IdGenerator floor sources

## Identity and outcome

- **Bucket 1, MP-R2, chunk C2.** No user-visible change.
- **Finding:** the id counter's cold-boot recovery reads two things that
  belong to other components: the Executor journal path
  (`Aiur.Executor.StatePaths.journal_path/0`) and launch-state adoption of
  earlier per-launch counters (`Aiur.LaunchStateAdoption.legacy_files/1`).
  Both are correct and must stay (they stop id reuse after a lost counter
  file, `id_generator.ex:25-39`); only *who names them* moves.
- **Deliverable:** a new start option `:floor_files` (0-arity fun returning
  a list of file paths to scan for the highest id) next to the existing
  `:legacy_counter_files` option; production values are supplied by the
  app-boot child spec, so `id_generator.ex` has no `Aiur.Executor.*` or
  `Aiur.LaunchStateAdoption` reference. MP-R2-C6-T02 later adds the export
  journal through the same option.
- **Non-goals:** no change to the recovery algorithm, the safety margin,
  the counter file location or format.

## Dependencies and blockers

DESIGN-R2 §1; C1-T06. Touches `aiur.ex:358` (one child entry). Concurrent
with every other C2 ticket except C1-T04 being edited at the same time.

## Verified starting point (45a290e3)

| Fact | Evidence |
| --- | --- |
| Option `:legacy_counter_files` exists, default `&legacy_counter_files/0` | `src/lib/aiur/events/id_generator.ex:115,126` |
| `legacy_counter_files/0` → `LaunchStateAdoption.legacy_files(legacy_file_name())`, rescue → `[]` | `:294-298` |
| Cold boot: `disk_max = max(scan_durable_event_logs_for_max_id(), legacy_counter_max(...))` | `:215-228` |
| `scan_durable_event_logs_for_max_id/0` scans `*.log` in `Paths.log_root_dir()` and `StatePaths.journal_path()` | `:320-336` |
| Child entry is the bare module | `src/lib/aiur.ex:358` |
| Supervision-health ids are the module name | `test/aiur/agent_control_cli_test.exs:1281-1288` (unchanged: a `{module, opts}` tuple keeps id = module) |
| Tests | `test/aiur/events/id_generator_test.exs`, `test/aiur/durable_runtime_state_test.exs:100-190` (stepped-back clock, legacy migration) |

PROPOSED: `src/lib/aiur/id_floor_sources.ex` (`Aiur.IdFloorSources`, app-boot
component).

## Chosen design

- `IdGenerator.init/1`: `floor_files = Keyword.get(opts, :floor_files, fn -> [] end)`
  and `legacy_counter_files = Keyword.get(opts, :legacy_counter_files, fn -> [] end)`;
  `scan_durable_event_logs_for_max_id/1` takes the state and scans
  `log_root_dir` `*.log` files (bus-owned: per-issue logs are where
  `[event:*] id=` markers land; `Paths` is kernel config) **plus** every path
  in `state.floor_files.()`.
- `Aiur.IdFloorSources`:

```elixir
def floor_files, do: [Aiur.Executor.StatePaths.journal_path()]
def legacy_counter_files do
  Aiur.LaunchStateAdoption.legacy_files("#{Aiur.Config.Paths.repo_name()}.event_id")
rescue
  _ -> []
end
```

- `aiur.ex:358` → `{Aiur.Events.IdGenerator, floor_files: &Aiur.IdFloorSources.floor_files/0,
  legacy_counter_files: &Aiur.IdFloorSources.legacy_counter_files/0}`.
- Defaults inside the bus become empty lists: a reusable bus without an
  Executor journal simply has no extra floor. In the full product the
  boot spec always supplies both, so behaviour is identical.
- **Invariant:** with the production child spec, `disk_max` is computed
  from the same set of files as today.

## Implementation steps

1. Add `Aiur.IdFloorSources` (≈15 lines).
2. Edit `id_generator.ex`: new option, new defaults, delete
   `legacy_counter_files/0`, change the journal line at `:333` to fold over
   `state.floor_files.()`; drop the two aliases. File shrinks.
3. Edit `aiur.ex:358` (same line count).
4. Remove the `id_generator.ex → Aiur.Executor.StatePaths` and
   `→ Aiur.LaunchStateAdoption` rows from the C1-T06 allowlist.

## Non-happy paths

- A floor file is unreadable or a fun raises: today each scan rescues to
  `0` (`:334-335,362-363`) and `legacy_counter_files` rescues to `[]`; keep
  both rescues, and wrap the `floor_files.()` call in the existing rescue.
- Tests that start an IdGenerator without options (many, e.g.
  `decision_store_test.exs:103`) now get no Executor-journal floor. That
  only matters on a cold boot with a lower wall clock than a journal id,
  which those tests do not set up; the floor behaviour is covered by test 1.

## Compatibility and rollout

No config, no file change. Rollback: revert.

## Verification

1. `id_generator_test.exs` new test `"cold boot seeds above the highest id in an injected floor file"`:
   temp dir, write `journal.ndjson` with `{"id": 9000000000000000}`, start
   with `path: <missing counter>`, `clock: fn -> 1 end`,
   `legacy_counter_files: fn -> [] end`, `floor_files: fn -> [journal] end`;
   assert `next_id > 9_000_000_000_000_000`. **Fails without step 2**
   (option ignored; seed ≈ 1 + 1_000_000).
2. `aiur_test`/application test `"IdGenerator child spec supplies the Executor journal floor"` —
   in `test/aiur/application_test.exs` (describe "child_specs/1 run-shape
   gating"), find the IdGenerator spec and assert its opts contain
   `floor_files` whose result includes `Aiur.Executor.StatePaths.journal_path()`.
   **Fails without step 3.** This test exists so the production behaviour
   cannot silently lose the journal floor.
3. Existing `id_generator_test.exs`, `durable_runtime_state_test.exs`,
   `decision_store_test.exs` (IdGenerator setups), `agent_control_cli_test.exs`
   supervision output unchanged and green.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/id_generator_test.exs test/aiur/durable_runtime_state_test.exs \
  test/aiur/application_test.exs test/aiur/agent_control_cli_test.exs \
  test/aiur/events/bus_boundary_test.exs
```

Mutation check: revert `id_generator.ex` hunk → test 1 fails; revert the
`aiur.ex` hunk → test 2 fails; restore → pass. Clean worktree each time.

## Completion and handoff

- [ ] `id_generator.ex` has no `Aiur.Executor.*` / `Aiur.LaunchStateAdoption` reference.
- [ ] `aiur.ex` line count unchanged.
- [ ] Tests 1–2 added and mutation-checked.
- [ ] Docs: none.
- Dependents: MP-R2-C6-T02 (adds the export journal to `floor_files`),
  C4-T01; MP-R1-C5 (kernel) may later own `Aiur.IdFloorSources`.
