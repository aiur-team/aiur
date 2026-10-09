---
execution: code
artifact_readiness: implementation-ready
---
# CPU pressure dispatch admission

Issue #3839: admit model-waiting agents independently of compile/test concurrency.

## Decisions

Use Linux CPU PSI `some avg60` (percent, independent of scheduler count) for
fleet admission and AIMD. Default hard ceiling 20%, target 10%; explicit null
disables each. Keep existing load settings for PSI-unavailable fallback only.
Preserve memory, descriptors, provider and GitHub admission. Remove build queue
occupancy as a dispatch constraint; builds retain their existing cap, pacing,
and nice. The optional short-window build PSI gate is deferred: concurrent
builds already have a separate admission mechanism.

AIMD keeps three fresh overload samples and decrease cooldown. Recovery needs
pressure below 80% of target; unavailable pressure never masquerades as zero.
Legacy load-only helpers remain available for fallback and compatibility.

## Units

1. Add PSI reader and pressure policy/envelope; wire real dispatch sampling,
   auto-resume, capacity constraints and status. Add tests in
   `src/test/aiur/system_pressure_test.exs` and
   `src/test/aiur/orchestrator/pressure_admission_test.exs` for malformed reads,
   pressure holds, high-load/low-pressure admission with four occupied builds,
   memory holds, fallback, 16-slot ramp, sustained overload and recovery band.
2. Add schema settings with null preservation and component ownership, update
   `website/docs-app/reference/configuration.md`, existing operator guides,
   `.aiur/examples/config.example`, and `src/README.md`.

## Verification and completion

Run scoped compile, format, affected tests, mutation checks in an isolated
worktree, lint, bare-assert and PR structural gates. Review the draft diff.
Host acceptance requires actual 1-hour before and after fleet measurements
(agents, PSI, load, memory, merged/hour) from the Executor. Do not claim measured
throughput improvement or completion without them; no live fleet deployment
is authorized in an agent turn. Integration branch: main.
