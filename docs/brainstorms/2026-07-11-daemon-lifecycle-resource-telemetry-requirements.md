---
date: 2026-07-11
topic: daemon-lifecycle-resource-telemetry
---

# Daemon Lifecycle and Resource Telemetry

## Summary

Add debug-only, daemon-owned resource and lifecycle telemetry, plus a backend-agnostic generator that turns one or more run records into a self-contained HTML analytics dashboard.

---

## Problem Frame

Aiur's current run analytics depend on an operator-attached sampler. Sampling stops when that operator session exits or hands off, excludes processes the sampler does not know about, and leaves no durable account of ticket transitions between prewarm, setup, execution, review, and rework. The resulting gaps prevent trustworthy saturation analysis and make failed event-listener wakeups indistinguishable from ordinary idle time.

The runtime already knows when it dispatches work, provisions workspaces, starts agent sessions, pauses or resumes workers, receives trusted GitHub activity, and moves tickets into review or rework. Those facts are not yet joined into a durable analytics record.

---

## Assumptions

*This requirements doc was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input — un-validated bets that should be reviewed before planning proceeds.*

- A generator may consume several session directories or telemetry files as one logical run so daemon restarts do not fragment the analysis.
- Linux process accounting is authoritative where available. Unsupported platforms, remote workers, and indeterminate operator processes report explicit unavailability rather than fabricated zeroes.
- Trusted PR and comment events already published inside Aiur are the primary GitHub anchors; optional GitHub enrichment may fill events that predate a daemon restart.
- A broken review wakeup is a trusted comment received after review pause without a subsequent rework-start and agent-resume transition in the observed timeline.
- Telemetry belongs under the existing per-session log root and follows its retention policy.

---

## Actors

- A1. Aiur daemon: owns sampling and lifecycle capture independently of any attached UI or operator process.
- A2. Ticket agent: moves through prewarm, setup, spinup, implementation, build/test, review, pause, and rework phases.
- A3. Operator or orchestrator process: may be resource-attributed when the daemon can identify its local process tree.
- A4. Dashboard generator: reads durable telemetry and optional GitHub anchors and emits the canonical HTML artifact.
- A5. Operator or reviewer: opens the artifact locally, explores timelines, and evaluates saturation or lifecycle failures.

---

## Key Flows

- F1. Debug telemetry capture
  - **Trigger:** Aiur starts with debug enabled.
  - **Actors:** A1, A2, A3
  - **Steps:** The daemon records its restart boundary, discovers attributable local process trees, samples resources on a stable cadence, and appends lifecycle transitions as they occur. Capture continues whether or not an operator remains attached.
  - **Outcome:** The session log contains durable, timestamped resource and lifecycle records until daemon shutdown or restart.
  - **Covered by:** R1–R7

- F2. Review-to-rework lifecycle
  - **Trigger:** A ticket opens a PR and enters human review.
  - **Actors:** A1, A2
  - **Steps:** The daemon records PR opening and review pause; a trusted comment is recorded; the orchestrator either transitions the ticket to rework and resumes its agent or leaves an observable missing-transition sequence.
  - **Outcome:** The dashboard can distinguish a successful listener wakeup from a broken pause-to-resume path.
  - **Covered by:** R5, R6, R10

- F3. Offline dashboard generation
  - **Trigger:** An operator or agent supplies one or more telemetry inputs to the generator.
  - **Actors:** A4, A5
  - **Steps:** The generator validates and orders records, reconciles optional GitHub anchors, derives lifecycle intervals and findings, and writes one portable HTML file.
  - **Outcome:** The artifact opens locally without a server or network dependency and supports interactive inspection.
  - **Covered by:** R8–R12

---

## Requirements

**Capture and durability**

- R1. Resource and lifecycle capture runs inside the supervised daemon only when debug mode is enabled; a normal run starts no sampler and creates no telemetry artifact.
- R2. Every telemetry record carries a version, wall-clock timestamp, daemon boot identity, and enough actor or ticket identity to merge records across files without relying on filename conventions.
- R3. Capture is append-only and durable under the existing per-session log root. A daemon restart records a new restart boundary and resumes capture without requiring an operator to reconnect.
- R4. Resource sampling records CPU, resident memory, open file descriptors, and read/write I/O for the daemon and each locally attributable ticket agent. Operator/orchestrator and remote-worker data is included when determinable and otherwise marked unavailable.

**Lifecycle truth**

- R5. Ticket lifecycle records cover dispatch, prewarm, workspace setup, agent spinup, implementation, build/test, PR opened, review pause, comment received, rework start, and agent pause/resume with a cause.
- R6. Lifecycle timestamps come from explicit runtime transitions or trusted internal GitHub events wherever those sources exist. The system must not make log-text heuristics the primary source of lifecycle truth.
- R7. Repeated polls or replayed source events must not create misleading duplicate phase transitions, while distinct comments, pauses, resumes, attempts, and daemon restarts remain visible.

**Generator and artifact**

- R8. The generator accepts a telemetry file, a session directory, or a collection of session inputs and produces a single HTML file containing all required data, styling, and behavior.
- R9. The artifact includes an interactive per-actor resource timeline, an interactive per-ticket lifecycle timeline, a resource profile summarizing sustained and peak usage, and an operational findings/notes section.
- R10. Lifecycle analysis identifies review pauses where a trusted comment is not followed by the expected rework/resume sequence and shows the evidence and elapsed time supporting the finding.
- R11. The generator tolerates partial runs, restarts, unsupported resource fields, unknown future record types, and malformed individual lines by preserving usable data and surfacing warnings instead of failing the entire report.
- R12. The generated HTML has no external runtime dependencies: no remote scripts, stylesheets, fonts, data fetches, or artifact-service requirement. Optional publication elsewhere is additive only.

---

## Acceptance Examples

- AE1. **Covers R1, R3, R4.** Given a debug run whose attached operator exits midway, when ticket agents continue working, resource samples and lifecycle events continue to append until the daemon itself stops. Given the same run without debug, no telemetry process or file exists.
- AE2. **Covers R2, R3, R8.** Given two session roots separated by a daemon restart, when both are supplied to the generator, the report renders one ordered timeline with a visible restart boundary and no operator-handoff hole after the second boot.
- AE3. **Covers R4, R11.** Given two local ticket agents, one remote agent, and no determinable operator PID, the local agents and daemon have measured samples while remote/operator rows are explicitly unavailable rather than zero-valued.
- AE4. **Covers R5–R7.** Given one ticket that reuses a warm base, provisions a workspace, starts an agent, edits code, and runs tests, its chart shows the real ordered transitions once each; a later independent test run appears as a distinct build/test interval.
- AE5. **Covers R5, R6, R10.** Given a ticket paused for human review and a trusted review comment, when the event listener transitions it to rework and resumes the agent, no broken-wakeup finding appears. If the comment is recorded but rework/resume never follows, the report flags the missing transition with timestamps.
- AE6. **Covers R8, R9, R12.** Given a generated report copied to a machine with networking disabled, opening it directly in a browser renders all charts, filters, tooltips, profiles, and findings without additional files.
- AE7. **Covers R1, R11.** Given telemetry is disabled, high ticket concurrency adds no periodic process scans or telemetry writes. Given a debug sampler encounters an unreadable process entry, it skips that process, records the limitation, and keeps the daemon alive.

---

## Success Criteria

- A completed or interrupted debug run leaves enough durable evidence to explain which actors consumed resources and which lifecycle phase each ticket occupied.
- Operator handoff no longer creates a sampling gap while the daemon remains alive, and daemon restarts are explicit boundaries rather than silent holes.
- Review listener failures are visible as deterministic lifecycle findings instead of manual log archaeology.
- Any supported coding backend can invoke the generator and deliver the same standalone HTML artifact.
- Debug-off runs show no sampler process, periodic process walk, or telemetry file I/O.

---

## Scope Boundaries

- No adaptive multi-resource controller, dispatch threshold, build gate, or resource policy change.
- No replacement or duplication of the FD-headroom gate owned by #929; this work consumes its measurement surface when available.
- No remote-host telemetry transport or agent installation protocol in this ticket.
- No external database, hosted analytics service, or required artifact publication.
- No replacement for Aiur's live operational dashboard or per-agent transcript logs.
- No guarantee of resource attribution when the operating system does not expose the process tree or when ownership cannot be determined safely.

---

## Key Decisions

- Prefer explicit lifecycle events plus resource sampling over reconstructing phases from general logs; reconstruction alone cannot distinguish missing events from absent work.
- Keep the canonical report offline and self-contained so its generation and viewing do not depend on a particular agent backend or hosted artifact surface.
- Preserve unknown and unavailable data visibly; a gap is evidence and must not be normalized into a misleading zero.
- Merge multiple session inputs at generation time rather than requiring daemon restarts to append to one immortal file.

---

## Dependencies / Assumptions

- #926's merged memory sampler establishes the repository's fail-open Linux procfs convention.
- #929 owns the canonical FD-headroom gate/measurement surface; integration may stack on its branch while it is unmerged.
- Aiur's internal GitHub event exchange continues to publish PR-opened, merged, issue-comment, and review-comment events for tracked tickets.
- Existing log retention may delete old session roots; operators must generate or archive reports before configured retention removes their inputs.

---

## Outstanding Questions

### Resolve Before Planning

- None.

### Deferred to Planning

- [Affects R4][Technical] Select a sampling cadence and process-tree aggregation strategy that stays inexpensive at saturation.
- [Affects R5, R7][Technical] Define phase-transition deduplication and attempt identity without hiding legitimate repeated build/test or pause/resume intervals.
- [Affects R8, R11][Technical] Define the stable versioned record contract and warning behavior for mixed schema versions.
- [Affects R10][Technical] Select the elapsed-time rule used to classify a comment-to-resume transition as missing versus merely delayed.
