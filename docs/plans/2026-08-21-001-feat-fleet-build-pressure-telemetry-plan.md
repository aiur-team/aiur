---
title: "Fleet Build-Pressure Telemetry - Plan"
type: feat
date: 2026-08-21
topic: fleet-build-pressure-telemetry
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Fleet Build-Pressure Telemetry - Plan

## Goal Capsule

- **Objective:** Record durable, correlated fleet-occupancy and build-gate pressure inputs for a later matched-run throughput study.
- **Authority:** Issue #2225 defines the observed saturation problem; the existing run-telemetry and build-gate contracts define sampling and availability semantics; repository contribution rules define verification and documentation.
- **Stop conditions:** Do not change agent or build concurrency, add a second sampling loop, or report stale/degraded observations as current measurements.
- **Execution profile:** Extend the existing five-second telemetry sample and analytics pipeline, then hand CI and review back through the normal ticket lifecycle.

---

## Product Contract

### Summary

Add one durable fleet-level time series that correlates agent occupancy with build-slot use, queue depth, and the oldest live queue wait. Surface the series through the existing analytics timeline so a later throughput study can compare matched pressure evidence instead of relying on spot checks; this ticket does not itself identify a saturation point.

### Problem Frame

`aiur status` shows current build-gate holders, queued commands, and wait durations, while dispatch already stops new admissions when the gate is saturated. Those snapshots cannot answer whether a larger active fleet increases completed-ticket throughput because the telemetry stream does not retain the build-pressure series beside fleet occupancy.

### Requirements

#### Durable sampling

- R1. Every normal run-telemetry cadence records current fleet occupancy and configured, session, and effective agent capacity.
- R2. The same sample records whether the build gate is enabled, its active and configured slots, live queue depth, and the oldest live queue wait.
- R3. Missing, stale, or degraded source observations remain unavailable or partial evidence rather than becoming measured zeroes.
- R3a. Fleet and build observations retain their own observation times; one telemetry sample is a bounded-skew pair, not an atomic cross-source snapshot.

#### Analytics and compatibility

- R4. Current-run and retained-run analytics preserve the new metrics through both reducer paths and materialized summaries.
- R5. Browser, CLI/JSON, offline HTML, and Python analytics expose the same fleet-wide pressure evidence without inferring occupancy from CPU activity.
- R6. Existing telemetry schema versions and older records remain readable without migration; absent new fields reduce to `nil`/`null`.

#### Documentation

- R7. Operator documentation explains that analytics now retains build pressure beside fleet occupancy and that the evidence informs later concurrency tuning rather than changing capacity automatically.

### Acceptance Examples

- AE1. **Healthy pressure:** With 13 occupied agent slots, two active build slots, eight queued builds, and a 189-second oldest waiter, one fleet sample preserves those values with source observation times inside one sampler cadence. **Covers R1, R2, R3a.**
- AE2. **Idle healthy gate:** With no active or queued builds, a healthy enabled gate records zero active, zero queued, and zero oldest wait rather than unavailable values. **Covers R2, R3.**
- AE3. **Unpublished or stale fleet view:** If the fleet snapshot is unavailable or stale, build-gate measurements may still be recorded, while agent-capacity fields remain unavailable and are named as partial fields. **Covers R1, R3.**
- AE4. **Degraded build gate:** If lock metadata cannot be read authoritatively, build metrics remain unavailable and the sample identifies the build fields as partial instead of plotting misleading zeroes. **Covers R2, R3.**
- AE5. **Historical compatibility:** A schema-v2 telemetry stream without fleet fields still reduces and renders with the prior resource metrics. **Covers R4, R6.**

### Scope Boundaries

- Adaptive changes to `max_concurrent_agents`, the AIMD envelope, or `max_concurrent_builds` are deferred until matched telemetry demonstrates a throughput saturation point.
- The change does not add another status command, analytics page, telemetry schema version, or sampling process.
- Completed-build latency and tickets-per-hour derivation remain separate analytics work; this ticket records the pressure inputs needed to compare runs.

---

## Planning Contract

### Key Technical Decisions

- Attach fleet/build facts to the existing `_daemon` resource record, following the daemon-only `system_fd` pattern. This reuses durable timestamps, boot identity, retention, and gap semantics without inventing a second system actor or sampling stream.
- Read fleet capacity from the lock-free published dashboard snapshot. Preserve independent `fleet_capacity_status` and snapshot age, but accept numeric capacity only from a current snapshot; stale or unpublished data must not be stamped onto a new telemetry timestamp as current evidence.
- Add `oldest_wait_seconds` to the authoritative `Aiur.BuildGate.status/1` result, derived as the maximum non-negative duration among live queue holders. An empty healthy or disabled gate records zero; degraded status and incomplete queued metadata remain unavailable.
- Keep fleet and build source states independent of the process record's `availability`. Numeric fields from a healthy source remain usable when the other source or procfs is unavailable, and missing values remain `nil` rather than becoming zero.
- Extend the existing resource metric allowlists in both reducers and the summary decoder. New optional attributes preserve telemetry schema-v2 and run-summary-v1 compatibility.
- Build dedicated fleet-pressure series in the Operator Control Center presenter. Bucket capacity gauges by latest observation and pressure/wait values by maximum, retaining source-state/observation metadata so missing buckets remain gaps. Render aligned occupancy, build-depth, and wait lanes on the shared time domain rather than mixing counts and seconds on one unlabeled scale.
- Carry the same exact sampled values into the CLI, self-contained offline dashboard, and Python renderer. Legacy streams may retain the prior CPU-derived concurrency calculation only as an explicitly labelled fallback.
- Keep these consumers in parity because the browser, CLI, offline artifact, and Python report are documented views of the same retained analytics dataset; allowing one to keep CPU-inferred concurrency would make matched-run conclusions depend on the chosen renderer.

### Assumptions

- `Aiur.Orchestrator.dashboard_snapshot/2` remains the authoritative non-blocking fleet-capacity read model and returns the `capacity` payload used by status/dashboard surfaces.
- Build-gate holder durations represent live wait age at sample time; this plan does not infer completed wait duration after a command acquires a slot.

### Sequencing

U1 establishes the authoritative source aggregates and sample contract. U2 preserves that contract across reducers and summary reloads. U3 exposes the same evidence across analytics consumers. U4 documents the delivered operator behavior after the names and availability semantics are fixed.

---

## Implementation Units

### U1. Define and sample fleet and build pressure

**Goal:** Add authoritative oldest-wait aggregation and attach one fleet/build observation to each `_daemon` sample without weakening process-resource sampling.

**Requirements:** R1, R2, R3; AE1, AE2, AE3, AE4

**Dependencies:** None

**Files:**

- Modify: `src/lib/aiur/run_telemetry/sampler.ex`
- Modify: `src/lib/aiur/build_gate.ex`
- Test: `src/test/aiur/run_telemetry/sampler_test.exs`
- Test: `src/test/aiur/build_gate_test.exs`

**Approach:** Extend `BuildGate.status/1` with one canonical oldest-live-wait aggregate and make its Linux scan suitable for periodic telemetry: consolidate each holder's validation/parsing into one read and perform lock/metadata inspection in a bounded helper-process count rather than spawning per field. Add injectable fleet-snapshot and build-status readers to `sample_once/2`, call each once per cadence, capture each source's observation time, normalize their states independently, and merge the facts into the `_daemon` record even when procfs is unavailable. Preserve exact `occupied`, `max`, `effective`, and configured/session capacity fields; do not substitute process count or CPU activity.

**Patterns to follow:** Existing `fd_headroom_fun` injection and fail-open `safe_call/2`; `Aiur.Orchestrator.dashboard_snapshot/2`; `Aiur.BuildGate.status/0`; current unavailable-resource records.

**Test scenarios:**

- Covers AE1. A current capacity snapshot and saturated build status produce one `_daemon` record with exact occupancy, limits, active slots, queue depth, and maximum live wait.
- Covers AE2. A healthy empty queue produces numeric zeroes, including zero oldest wait.
- Covers AE3. A stale or unpublished fleet snapshot preserves healthy build measurements, leaves fleet fields nil, and lists them as partial.
- Covers AE4. A degraded or malformed build status preserves current fleet capacity while leaving all build metrics nil and partial.
- A procfs failure still preserves independent fleet/build fields on the unavailable daemon record.
- Build-gate status chooses the oldest live queue holder, ignores stale/unlocked metadata, and performs only one gate probe per sampler tick.
- A saturated two-active/eight-queued fixture completes the status scan with a bounded helper-process count and comfortably inside the five-second sampler cadence.
- Fleet/build observation timestamps remain ordered within the enclosing sample interval and unavailable sources do not receive invented observation times.
- Duplicate or incomplete queue-holder metadata never raises and never invents a wait duration.

**Verification:** Focused sampler tests prove source independence, exact values, and fail-open behavior without starting the full application.

### U2. Preserve the new metrics across reducers

**Goal:** Carry fleet/build metrics and source-state evidence through raw reduction, materialized summaries, and retained-run reloads.

**Requirements:** R4, R5, R6; AE5

**Dependencies:** U1

**Files:**

- Modify: `src/lib/aiur/run_telemetry/dataset.ex`
- Modify: `src/lib/aiur/run_telemetry/summaries.ex`
- Modify: `analytics/lib/analytics/reduce.py`
- Test: `src/test/aiur/run_telemetry/dataset_test.exs`
- Test: `src/test/aiur/run_telemetry/summaries_test.exs`
- Test: `analytics/tests/test_reduce.py`

**Approach:** Add identical numeric names to the Elixir and Python resource allowlists, retain source-state fields when decoding summary JSON, and keep the run-summary schema version unchanged because actor samples permit optional properties. Missing legacy fields remain absent rather than being backfilled with zero.

**Patterns to follow:** Current resource metric lists and profile statistics in both reducers; `Summaries.decode_sample/1`; the dashboard's `metrics` registry and accessible table.

**Test scenarios:**

- Raw telemetry with a `_daemon` record carrying fleet/build attributes reduces to exact samples and profile statistics in Elixir and Python.
- A materialized summary round-trip preserves every new metric and partial-field marker.
- Covers AE5. Older resource records without fleet/build attributes remain valid and yield nil fields without warnings.
- The Python and Elixir metric sets stay semantically identical so prior-boot summaries do not drop fields the live view shows.

**Verification:** Focused Elixir reducer/summary tests and the dependency-free Python analytics suite pass without a schema migration.

### U3. Render fleet-wide pressure consistently

**Goal:** Expose exact sampled occupancy, build depth, and oldest-wait evidence across every supported analytics consumer.

**Requirements:** R5, R6; AE1, AE2, AE5

**Dependencies:** U1, U2

**Files:**

- Modify: `src/lib/aiur_web/operator_control_center/analytics/presenter.ex`
- Modify: `src/lib/aiur_web/operator_control_center/analytics/charts.ex`
- Modify: `src/lib/aiur_web/live/analytics_live.ex`
- Modify: `src/lib/aiur/analytics_cli.ex`
- Modify: `src/lib/aiur/run_telemetry/dashboard.ex`
- Modify: `analytics/lib/analytics/render.py`
- Test: `src/test/aiur_web/operator_control_center/analytics/presenter_test.exs`
- Test: `src/test/aiur_web/operator_control_center/analytics/charts_test.exs`
- Test: `src/test/aiur_web/live/analytics_live_test.exs`
- Test: `src/test/aiur/analytics_cli_test.exs`
- Test: `src/test/aiur/run_telemetry/dashboard_test.exs`
- Test: `analytics/tests/test_render.py`

**Approach:** Build dedicated fleet/build buckets from `_daemon` samples independently of process `availability`. Gate fleet values by `fleet_capacity_status` and build values by `build_gate_status` in every renderer, retaining record-level availability only for process metrics. Use latest for capacity gauges and maximum for occupancy, active builds, queue depth, and oldest wait. Preserve observation/source states, leave missing buckets as gaps, and render aligned count and duration lanes on the existing shared time brush. Pair gaps with a compact status strip and legend that distinguishes stale fleet data, degraded build data, partial observations, and wholly empty intervals. Add a keyboard-reachable timestamped data table with the exact values and source states. The human CLI summary reports peak occupied agents, peak active/queued builds, longest live wait, and the latest measured capacity values for the selected range; JSON preserves the full series. Extend offline HTML and Python outputs with the same measured values, and label all evidence as whole-host/fleet-wide because Build Order filtering intentionally retains daemon overhead.

**Patterns to follow:** Existing Presenter bucketing and `Charts.with_exact_time_domain/3`; inline-SVG step series and shared brush; dashboard metric registry/accessibility table; CLI model serialization; Python concurrency renderer with an explicitly labelled legacy fallback.

**Test scenarios:**

- Occupied but CPU-idle agents still contribute exact occupancy, and runtime capacity changes remain historical rather than reading current config.
- Queue spikes and oldest waits use bucket maxima; capacity changes use the latest observation; degraded/unobserved buckets render gaps rather than zeroes.
- Browser charts render labelled fleet-wide lanes and obey the shared range/zoom controls; a matching state strip/legend makes every gap class explicit.
- The accessible timestamped table is keyboard reachable and covers populated, partial, stale/degraded, and empty intervals in LiveView tests.
- Procfs-unavailable daemon records still expose healthy fleet/build metrics in the offline and Python renderers through their source-specific status fields.
- CLI human and JSON outputs, offline HTML, and Python reports carry the same values; legacy telemetry remains readable with a clearly identified fallback.

**Verification:** Focused presenter/chart/LiveView/CLI/dashboard tests and Python renderer tests exercise the actual user-visible paths.

### U4. Document measurement-first tuning evidence

**Goal:** Make the new analytics evidence and its non-adaptive boundary discoverable to operators.

**Requirements:** R7

**Dependencies:** U1, U2, U3

**Files:**

- Modify: `website/docs-app/guide/executor-control-center.md`
- Modify: `website/docs-app/reference/cli.md`
- Modify: `src/README.md`

**Approach:** Extend the Analytics and CLI descriptions with the fleet/build-pressure metrics, their whole-host scope, the oldest-live-wait meaning, and the explicit statement that capacity remains operator/config/controller owned. Correct the canonical offline-artifact description in the source README.

**Patterns to follow:** Existing concise page/counterpart descriptions and explicit unavailable-evidence language in the Dashboard guide.

**Test scenarios:** Test expectation: none -- this is a concise documentation correction for the changed user-facing analytics surface.

**Verification:** The guide accurately describes what the analytics timeline records and does not claim automatic concurrency adaptation.

---

## System-Wide Impact

- **Sampling cost:** One lock-free snapshot read and one bounded filesystem build-status scan join the existing monitored sampler worker every five seconds; the scan must not fan out one metadata-reader process per derived field, and neither read executes in the Orchestrator mailbox.
- **Data compatibility:** Raw telemetry and summaries gain optional resource attributes only. Existing schema versions, retained streams, and older materialized summaries continue to decode.
- **Cardinality:** No actor is added; optional system attributes join the existing `_daemon` record once per cadence.
- **Operator surface:** Live and retained browser, CLI, offline HTML, and Python analytics gain fleet-wide pressure evidence; dispatch admission, build locking, and capacity controls do not change.

---

## Risks & Dependencies

| Risk | Mitigation |
| --- | --- |
| Stale fleet snapshots plotted as current occupancy | Accept numeric fleet capacity only from a current published snapshot; retain source failure as partial evidence. |
| Degraded build metadata plotted as an empty queue | Treat degraded or structurally invalid build status as unavailable build fields. |
| Analytics consumers disagree | Update and test reducers, summaries, Presenter/charts, CLI, offline HTML, and Python rendering as one contract. |
| Queue wait is misread as completed latency | Name and document it as the oldest **live** wait at the sample timestamp. |
| Five-second gate reads add orchestration pressure | Consolidate lock/metadata inspection into a bounded helper-process count, test the saturated 2-active/8-queued case, and reuse cadence overlap skipping as a backstop. |

---

## Verification Contract

- Compile Elixir with warnings treated as errors and run the formatter over the touched Elixir files.
- Use `mix aiur.affected_tests` to compute the scoped Elixir set, then run every emitted test command with `mix test --max-cases 4`.
- Run `PYTHONPATH=analytics/lib python3 -m unittest discover -s analytics/tests -t analytics` for canonical reducer and schema parity.
- Do not run the guarded `scripts/aiurdev --test` path from this issue workspace. Focused sampler/reducer/dashboard tests are the permitted local evidence; Executor-root manual verification remains outside this agent turn.

---

## Definition of Done

- Each normal telemetry cadence attaches at most one fleet/build observation to `_daemon`, with independent honest current/partial/unavailable semantics.
- Raw, live, retained, and materialized analytics preserve and render the same fleet/build metric set.
- Older telemetry and summaries remain readable without a schema migration.
- Operator documentation names the new evidence and the measurement-before-adaptation boundary.
- The scoped Elixir gate and Python analytics suite pass, abandoned experimental code is absent, the draft PR is self-reviewed, and CI receives the exact tested head against `main`.

---

## Sources & Research

- `docs/plans/2026-07-09-001-refactor-fleet-mix-build-gate-plan.md` defines the durable lease and current-status contract.
- `docs/brainstorms/2026-07-11-daemon-lifecycle-resource-telemetry-requirements.md` defines daemon-owned cadence, append-only evidence, and explicit unavailable semantics.
- `docs/plans/2026-07-09-001-refactor-load-concurrency-envelope-plan.md` keeps AIMD admission separate from build-gate measurement.
- `docs/plans/2026-07-11-006-feat-phase-aware-build-staggering-plan.md` establishes matched-run comparison as the basis for build-pressure tuning.
