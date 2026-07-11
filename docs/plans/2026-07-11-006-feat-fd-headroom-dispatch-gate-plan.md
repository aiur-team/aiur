---
title: "feat: Add FD Headroom Dispatch Gate"
type: feat
status: completed
date: 2026-07-11
---

# feat: Add FD Headroom Dispatch Gate

## Summary

Add a reusable per-process file-descriptor sampler and use it to hold normal new-work dispatch before the Aiur daemon reaches its soft open-file limit. The sampler exposes raw usage, limit, and headroom data for the future multi-resource controller and daemon telemetry work.

---

## Problem Frame

Aiur previously crashed with `:emfile` when concurrent agent setup and tmux polling exhausted the BEAM process's open-file allowance. Structural fan-out reductions and a launcher-side soft-limit raise reduced the likelihood, but dispatch still admits new process trees without checking whether the daemon has enough descriptors left to spawn them.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input — un-validated bets that should be reviewed before implementation proceeds.*

- “Low headroom” is a default-on reserve of 10% of the daemon's finite soft open-file limit; no new operator knob is added because the ticket asks for a hard safety gate rather than optional admission control.
- The gate follows the merged memory gate's scope: normal automated new-work dispatch is held, while running agents are never stopped and retry/reactivation semantics remain unchanged.
- The observed `:emfile` is a per-process limit failure, so system-wide file-table exhaustion (`:enfile`) is explicitly separate from this ticket.
- Missing platform data fails open for portability, but a sampling operation that itself reports `:emfile` is treated as exhausted and fails closed until a later poll recovers.

---

## Requirements

- R1. Read the Aiur daemon's current open-descriptor usage and finite soft open-file limit without spawning a subprocess on each poll.
- R2. Hold normal new-work dispatch whenever remaining descriptors fall below the safety reserve, without mutating or stopping already-running work.
- R3. Re-evaluate on later polls so dispatch resumes automatically once descriptor headroom recovers.
- R4. Emit an always-on, stable diagnostic for every FD-based dispatch deferral with usage, limit, remaining headroom, and reserve context.
- R5. Expose a reusable sample contract containing raw FD usage, limit, remaining count, and normalized headroom for the multi-resource controller (#927) and resource telemetry (#930).
- R6. Deterministically cover low-headroom deferral, equality/recovery, unavailable data, and exhaustion while sampling; leave the live high-concurrency soak as an operator-root validation step.

---

## Scope Boundaries

- Do not change the structural opencode/tmux fan-out fixes already landed for #409.
- Do not gate Mix builds; the incident and this ticket concern daemon `open_port` capacity, while build admission remains owned by the memory/build gate.
- Do not implement the multi-resource adaptive controller (#927), telemetry recorder/dashboard (#930), or phase staggering (#931).
- Do not add a system-wide Linux file-table (`file-max` / `file-nr`) gate; exhaustion there surfaces as `:enfile`, not the reported per-process `:emfile`.
- Do not allocate descriptors or launch a dogfood saturation run from the shared agent workspace.

### Deferred to Follow-Up Work

- Consume the raw FD sample in the CPU/memory/FD closed-loop controller: #927.
- Record daemon and per-agent FD samples in durable lifecycle telemetry: #930.
- Run the 12–16 agent survival/recovery soak from the operator repository root and capture the before/after FD timeline.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/system_memory.ex` provides the direct pure-sampler and fail-open precedent.
- `src/lib/aiur/orchestrator/dispatch_policy.ex` keeps host reads and pure hold/dispatch decisions separately testable.
- `src/lib/aiur/orchestrator/dispatcher.ex` applies memory admission to normal new work and logs stable `aiur_perf` hold lines.
- `packaging/npm/aiur-cli/libexec/aiur-engine.sh` already raises the effective soft nofile limit before the release starts and is the portable place to export that effective limit to the BEAM.
- `docs/measurements/2026-06-23-emfile-structural-fix-census.md` establishes census-style resource assertions and the remaining FD holders.

### Institutional Learnings

- Resource regressions need census-style assertions, not only functional assertions (`docs/refactor/regression-safety.md`).
- Dispatch gates must hold only future work and recover naturally without consuming retry budgets or disturbing live agents.
- Sampling cannot depend on spawning `ulimit`, `lsof`, or another helper at the moment descriptor headroom is already scarce.

### External References

- Erlang documents `:emfile` from `open_port` as exhaustion of descriptors available to the emulator OS process: https://www.erlang.org/doc/apps/erts/erlang.html
- Linux documents `/proc/<pid>/fd` as the process's open-descriptor directory: https://docs.kernel.org/6.2/filesystems/proc.html

---

## Key Technical Decisions

- Sample process descriptors directly: count `/proc/<pid>/fd` entries on Linux and support the daemon's `/dev/fd` view where available, rather than forking an external census command.
- Use the process's finite soft limit: read arbitrary Linux process limits from `/proc/<pid>/limits`; export the launcher's post-raise daemon limit for platforms without procfs.
- Make the sample actor-capable: the public sampler accepts an OS PID so #930 can reuse the same contract for daemon and agent actors instead of implementing another FD probe.
- Return raw and normalized facts: usage, finite limit, available count, and headroom ratio stay policy-neutral; the hard gate owns the 10% safety decision.
- Preserve independent resource decisions: memory, FD, and hard-load gates remain individually testable and log their own reason, while the future controller can consume the raw samples together.

---

## Open Questions

### Resolved During Planning

- Which limit matters? The BEAM process's soft `RLIMIT_NOFILE`, because the recorded failure was `open_port` returning `:emfile`; the kernel-wide file table corresponds to `:enfile`.
- Should the poll run an external command? No; the gate must remain useful precisely when spawning another process may fail.
- How does telemetry reuse the work? Through a PID-parameterized public sampler that exposes policy-neutral facts.

### Deferred to Implementation

- Whether `/dev/fd` enumeration needs a platform-specific normalization after focused tests; unsupported variants remain fail-open rather than adding a subprocess fallback.

---

## Implementation Units

### U1. Add the reusable FD sampler and launcher limit handoff

**Goal:** Measure an OS process's open descriptors against its finite soft limit without per-sample subprocesses.

**Requirements:** R1, R5, R6

**Dependencies:** None

**Files:**
- Create: `src/lib/aiur/system_file_descriptors.ex`
- Modify: `packaging/npm/aiur-cli/libexec/aiur-engine.sh`
- Test: `src/test/aiur/system_file_descriptors_test.exs`
- Test: `src/test/aiur_engine_test.exs`

**Approach:** Add a pure sampler that accepts an OS PID, obtains the descriptor directory and finite soft limit from procfs when available, and returns a stable map of used, limit, available, and ratio values. For the daemon on non-procfs platforms, let the launcher export the effective post-raise soft limit and use `/dev/fd` when supported. Distinguish ordinary unavailability from an `:emfile` read failure so imminent exhaustion cannot accidentally fail open.

**Execution note:** Implement the parsing and source-failure cases test-first with injected directory/limit sources; never create a real descriptor storm.

**Patterns to follow:** `Aiur.SystemMemory` source overrides and parse-to-`:unavailable` contract; the existing best-effort nofile raise in the shared engine.

**Test scenarios:**
- Happy path: realistic procfs limit text plus a descriptor listing produces exact used, limit, available, and normalized headroom values.
- Integration: the shared launcher exports the effective finite soft limit observed after its existing raise logic.
- Actor reuse: sampling a supplied numeric PID resolves that process's procfs paths rather than the daemon-only paths.
- Edge case: used count at or above the reported limit clamps remaining headroom to zero.
- Edge case: an unlimited or malformed soft limit returns unavailable because there is no finite ceiling for a hard decision.
- Error path: missing procfs and `/dev/fd` data returns unavailable; `:emfile` from descriptor enumeration returns an exhausted sentinel.

**Verification:** Focused sampler and engine tests prove the map contract and limit handoff without spawning census commands or consuming significant FDs.

### U2. Gate and recover normal dispatch on FD headroom

**Goal:** Defer new agent process trees before FD exhaustion and resume them on a later healthy sample.

**Requirements:** R2, R3, R4, R6

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/orchestrator/dispatch_policy.ex`
- Modify: `src/lib/aiur/orchestrator/dispatcher.ex`
- Modify: `src/lib/aiur/orchestrator.ex`
- Test: `src/test/aiur/orchestrator_load_gate_test.exs`
- Test: `src/test/aiur/orchestrator/dispatcher_test.exs`

**Approach:** Add a pure FD hold/dispatch policy beside the memory and load gates, sample once per normal dispatch cycle, and hold before candidate selection when the normalized headroom is below 10%. Treat exact equality as admissible, unavailable sources as fail-open, and an exhausted sampling sentinel as fail-closed. Log the stable `aiur_perf fd_hold surface=dispatch` diagnostic without changing state so the next poll naturally retries.

**Patterns to follow:** `read_memory`, `memory_gate`, `maybe_choose_under_load`, and `aiur_perf memory_hold surface=dispatch`.

**Test scenarios:**
- Happy path: headroom above or exactly at the reserve permits the existing load-gated selection path.
- Hold: headroom just below the reserve returns the unchanged state, chooses no issue, and emits the always-on diagnostic with sample facts.
- Recovery: a low sample followed by an admissible sample allows the later cycle to dispatch normally.
- Error path: unavailable platform data preserves dispatch; an `:emfile` sampling failure holds.
- Integration: FD admission remains independent from low-memory and hard-load holds, and updating the adaptive load envelope still occurs once per poll.

**Verification:** Policy and dispatcher tests demonstrate deterministic hold/recovery while all existing prewarm, memory, load-envelope, and hard-load tests remain green.

### U3. Document the safety contract and operator soak

**Goal:** Make the default-on gate, telemetry seam, diagnostics, and remaining hardware validation discoverable.

**Requirements:** R4, R5, R6

**Dependencies:** U1, U2

**Files:**
- Modify: `src/README.md`
- Modify: `docs/measurements/2026-06-23-emfile-structural-fix-census.md`

**Approach:** Document what the 10% reserve measures, the platform/fail-open boundary, the stable deferral line, and the raw sampler contract intended for #927/#930. Extend the existing census document with the deterministic gate coverage and the exact operator-root soak still required for end-to-end acceptance.

**Patterns to follow:** The adjacent load/memory admission reference and the existing operator-only hardware capture section.

**Test scenarios:**
- Test expectation: none -- this unit documents behavior pinned by U1/U2 tests and an operator-only soak procedure.

**Verification:** Operators can identify why dispatch is held, what values telemetry/controller consumers receive, and how to validate no-`:emfile` recovery under real saturation.

---

## System-Wide Impact

- **Interaction graph:** The launcher communicates the effective daemon limit to a pure OS sampler; the normal poll samples once before issue selection; future controller/telemetry consumers read the same sampler contract.
- **Error propagation:** Unsupported or malformed platform data remains non-fatal and fail-open, except a direct `:emfile` sampling failure, which is conservatively treated as exhausted.
- **State lifecycle risks:** Holds mutate no claims, retry counters, running entries, or adaptive-capacity state, so recovery is the next ordinary poll rather than a separate state transition.
- **API surface parity:** The shared launcher covers npm and `aiurdev`; procfs PID sampling supports daemon and agent actors on Linux. No web API payload is changed in this ticket.
- **Integration coverage:** Dispatcher tests prove that a low sample prevents issue selection and a later healthy sample re-enters the existing dispatch path.
- **Unchanged invariants:** Prewarm readiness, memory admission, the AIMD load envelope, hard load admission, state caps, paused reservations, and retry/reactivation behavior remain independent.

---

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| FD usage can rise between sampling and process spawn | Keep a proportional reserve rather than waiting for the final descriptor; dispatch remains sequential and re-samples every poll. |
| Enumerating the descriptor directory itself fails near exhaustion | Treat `:emfile` as an exhausted sample and hold instead of using the ordinary fail-open path. |
| Procfs is absent or a platform's `/dev/fd` semantics differ | Use the launcher-provided finite limit where possible, test supported fallbacks, and fail open without spawning an external helper. |
| The 10% reserve is too conservative or too small for an unusual workload | Expose raw facts for #927 to tune closed-loop behavior; keep this ticket's hard gate simple and document the assumption for human review. |
| Telemetry work duplicates the sampler while developing concurrently | Publish the stable sampler contract to #930 and keep telemetry storage/presentation out of this diff. |

---

## Documentation / Operational Notes

- The stable deferral prefix is `aiur_perf fd_hold surface=dispatch`; logs include used, limit, remaining, and reserve values.
- The agent workspace must not run the live `scripts/aiurdev --test` saturation harness. The final PR will leave that acceptance check explicitly pending for the operator root.
- The existing launcher soft-limit raise remains best-effort; the gate adds back-pressure rather than replacing that mitigation.

---

## Sources & References

- Origin issue: #929
- Related incident/fix: #409 and PR #457
- Memory admission pattern: #926 and PR #964
- Future controller: #927
- Concurrent telemetry: #930
- Related code: `src/lib/aiur/system_memory.ex`, `src/lib/aiur/orchestrator/dispatch_policy.ex`, `src/lib/aiur/orchestrator/dispatcher.ex`
- Related measurement: `docs/measurements/2026-06-23-emfile-structural-fix-census.md`
- Erlang `open_port` errors: https://www.erlang.org/doc/apps/erts/erlang.html
- Linux procfs process descriptors: https://docs.kernel.org/6.2/filesystems/proc.html
