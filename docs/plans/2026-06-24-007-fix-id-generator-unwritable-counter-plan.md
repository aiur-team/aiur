---
title: "fix: Keep IdGenerator alive on unwritable counter paths"
type: fix
date: 2026-06-24
execution: code
---

# fix: Keep IdGenerator alive on unwritable counter paths

## Summary

Prevent `Aiur.Events.IdGenerator` from crash-looping when its event counter file cannot be persisted, while preserving the existing reserve-before-return behavior for writable log roots.

---

## Problem Frame

`Aiur.Events.IdGenerator.reserve_next_batch/1` currently assumes `persist/1` returns `:ok`. When `JsonStore.write!/2` fails with filesystem errors such as `:eperm`, `persist/1` rescues and returns `:error`; the match in `reserve_next_batch/1` then crashes the GenServer during boot or later reservation. The visible failure is noisy supervision restarts in otherwise passing tests, and the risk is that an unwritable inherited log root takes down event publishing.

---

## Requirements

- R1. An unwritable counter path must not crash `Aiur.Events.IdGenerator` during boot or later batch reservation.
- R2. Persistence failures must be surfaced with an actionable warning without log-spamming every `next_id/1` call.
- R3. Normal writable counter paths must keep the current monotonic, reserve-before-return restart guarantee.
- R4. Tests must exercise an unwritable counter path and assert the process remains alive with controlled behavior.

---

## Key Technical Decisions

- **Degrade inside the generator process:** Treat persistence failure as a local degraded state instead of a startup failure, because event publishing can still preserve in-process monotonicity and the acceptance criteria prefer staying alive or failing in a controlled way.
- **Warn once per degraded process:** Track whether the failure has already been reported in GenServer state so repeated reservations do not create a crash-loop-shaped warning stream.
- **Leave writable semantics untouched:** Keep `JsonStore.write!/2` and the reserve-before-return persisted shape for successful writes; only the `{:error, reason}` branch changes behavior.

---

## Implementation Units

### U1. Non-crashing persistence degradation

- **Goal:** Make reservation tolerate `persist/1` failures without taking down the GenServer.
- **Requirements:** R1, R2, R3.
- **Files:** Modify `src/lib/aiur/events/id_generator.ex`.
- **Approach:** Change `persist/1` to return `:ok` or `{:error, reason}`. Update `reserve_next_batch/1` to return the new state even when persistence fails, mark the state as degraded or warned, and emit one actionable warning that names the counter path and the consequence. Clear the degraded warning marker if a later reservation persists successfully.
- **Patterns to follow:** Keep the module's existing GenServer state-map style and `Logger.warning/1` usage.
- **Test scenarios:** Covered in U2.
- **Verification:** Writable path tests still pass and unwritable-path behavior no longer terminates the GenServer.

### U2. Unwritable counter path coverage

- **Goal:** Add regression coverage for persistence failures at boot and during later reservations.
- **Requirements:** R1, R2, R3, R4.
- **Files:** Modify `src/test/aiur/events/id_generator_test.exs`.
- **Approach:** Add focused tests that point the generator at an unwritable or impossible counter path, assert startup succeeds, `next_id/1` returns increasing values, and `Process.alive?/1` remains true after the failed reservation path. Keep existing writable restart tests intact to guard normal monotonicity.
- **Execution note:** Start with the failing regression test before changing the implementation.
- **Patterns to follow:** Reuse the test module's temp-dir setup, explicit `GenServer.stop/1` cleanup, and `async: false` posture.
- **Test scenarios:** Boot with an unwritable counter path and call `next_id/1`; force a later batch reservation against the same unwritable path and assert increasing IDs plus a live process; run existing writable restart tests to preserve persisted monotonicity.
- **Verification:** Targeted `id_generator_test.exs` passes.

---

## Scope Boundaries

- This plan does not change `JsonStore` semantics globally; other callers should continue receiving raised write failures through `write!/2`.
- This plan does not select a separate sandbox-local fallback path unless implementation proves that degrading in-process cannot satisfy the tests cleanly.
- This plan does not address unrelated file log handler warnings from inherited live-run log roots.

---

## Risks & Dependencies

- When persistence is degraded, restart-safe monotonicity cannot be guaranteed across BEAM restarts for that unwritable path. The warning must make that trade-off visible so the operator can fix the log root.
- A permission-based unwritable test can be flaky for privileged users, so tests should prefer a deterministic impossible path shape when possible.

---

## Sources & Research

- `src/lib/aiur/events/id_generator.ex` contains the failing `:ok = persist(new_state)` reservation path and existing reserve-before-return logic.
- `src/test/aiur/events/id_generator_test.exs` already covers writable monotonicity, kill simulation, corrupt files, and `peek/1`.
- `src/lib/aiur/json_store.ex` owns atomic JSON writes and raises on write failures.
