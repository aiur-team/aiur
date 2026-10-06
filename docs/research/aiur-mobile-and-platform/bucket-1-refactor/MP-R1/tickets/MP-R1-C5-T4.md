---
ticket_id: MP-R1-C5-T4
feature_id: MP-R1
chunk_id: MP-R1-C5
bucket: 1-refactor
title: Lifecycle telemetry through the signal port; Perf and LogFile reassigned to the signal component
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C5-T3]
prior_units: []
prior_boundaries: ["#11 signal", "TEL #29", "RUN #18", "CA #20", "CLD #22", "WS #19", "ORC #12", "ING #9"]
prior_features: []
prior_findings: []
size_owner: "src/lib/aiur/run_telemetry/lifecycle.ex: U8 TELEMETRY 'Run telemetry' (557 lines; split) — must not grow"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C5-T4 — Lifecycle telemetry through the port

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C5. Step S1.
- **User value:** none visible. Required components (agent-runner, harness adapters,
  workspace, orchestration) stop depending on the optional `telemetry` component, which
  is the R-optional rule (component-map §2). The run-telemetry dataset is byte-identical.
- **Deliverable:**
  1. `Aiur.Signal.lifecycle(ticket, attempt_id, event, boundary, metadata \\ %{}, opts \\ [])`
     and `Aiur.Signal.backend_message(ticket, attempt_id, backend, message, opts \\ [])`,
     delegating synchronously to `config :aiur, :signal, lifecycle_sink: Aiur.RunTelemetry.Lifecycle`
     (`record/6`, `observe_backend_message/5`, `run_telemetry/lifecycle.ex:64-97,117-163`).
     **Missing sink → `:ok`, no log**: telemetry is optional and its absence is a valid
     run shape (`telemetry?` gates `Aiur.RunTelemetry.Supervisor`, `aiur.ex:248,373`);
     the hot path must not log per event. This deliberately differs from `alert/2`
     (C5-T3), where absence is an error.
  2. Pure helpers used by emitters move to the port: `reason_class/1`
     (`lifecycle.ex:100-114`) and `new_attempt_id/1` (`:50-55`) become
     `Aiur.Signal.reason_class/1`, `Aiur.Signal.new_attempt_id/1`; `Lifecycle` delegates.
  3. Switch every caller outside `run_telemetry/` (base: 15 files, 27 sites of
     `record`/`observe_backend_message`, plus `reason_class`/`new_attempt_id` uses;
     enumerate with `rg -n 'RunTelemetry.Lifecycle' src/lib --glob '!src/lib/aiur/run_telemetry/**'`).
  4. Manifest: `perf.ex` and `log_file.ex` move to component `signal` (prior relocation
     rules map both to `SIG`). `Aiur.Perf` depends only on `Logger`, `Aiur.PubSub` and
     `Aiur.Boot` (`perf.ex:40-70`), so its 20 caller files (87 sites) need no code change.
- **Non-goals:** changing the telemetry dataset schema, `enabled?/1` semantics, Perf
  output; moving `run_telemetry/**` files.

## Dependencies and blockers

- DESIGN-R1 §1; C5-T3 (`Aiur.Signal` exists).
- **Concurrent:** C5-T5/T6 (different call sites; may conflict in the same files —
  rebase). **Dependents:** C1-T3 R-optional count drops.

## Verified starting point (`45a290e3`)

- `RunTelemetry.Lifecycle.record/6` (`lifecycle.ex:64-97`) checks `enabled?/1` itself and
  returns `:ok` otherwise; `observe_backend_message/5` likewise (`:117-163`).
- Walker: `RunTelemetry.Lifecycle` referenced from 17 files in 9 prior boundaries
  (CA, CLD, CTL, DSP, ING, PRL, RUN, TEL, WS); `Perf` from 20 files in 5 (CDX, CLD, OC, RUN,
  TUI).
- Tests: `src/test/aiur/run_telemetry/lifecycle_test.exs`,
  `src/test/aiur/regression/chat_open_perf_test.exs`.

## Chosen design

Same synchronous delegation as C5-T3; no process; no change in which process writes the
dataset (today `record/6` runs in the caller and hands off as it does now).

## Implementation steps

1. Port functions + config line.
2. Mechanical caller switch (one commit per component directory for review).
3. Manifest reassignment for Perf and LogFile; prune allowlist keys.

## Non-happy paths

- Telemetry disabled (`telemetry?: false`) → sink still configured, `record/6` returns
  `:ok` from its own `enabled?` check (unchanged).
- Sink unconfigured → `:ok` (documented above; test asserts no log line).

## Compatibility and rollout

No behaviour change. Rollback: revert.

## Verification

| Test (PROPOSED in `test/aiur/signal_test.exs`) | Expected |
|---|---|
| `lifecycle delegates all six arguments to the sink` | fake sink receives identical args |
| `backend_message delegates` | identical args |
| `missing lifecycle sink is a silent :ok` | `:ok`; `capture_log` empty |
| `reason_class and new_attempt_id equal the Lifecycle versions` | table of inputs; equal outputs (regression guard) |

Existing: `test/aiur/run_telemetry/lifecycle_test.exs`, `test/aiur/agent_runner/*`,
`test/aiur/regression/chat_open_perf_test.exs` stay green.

Command: `$TESTCMD test/aiur/signal_test.exs test/aiur/run_telemetry/lifecycle_test.exs test/aiur/regression/chat_open_perf_test.exs`.

Mutation check: drop `metadata` when delegating → test 1 fails; log on missing sink →
test 3 fails.

Checker: `R-optional` keys from required components to `Aiur.RunTelemetry.Lifecycle`
become stale; prune.

## Completion and handoff

- [ ] No module outside `run_telemetry/` references `RunTelemetry.Lifecycle`.
- [ ] Perf/LogFile owned by `signal`.
- [ ] Docs: none.
- **Dependents:** C1-T3 trend; MP-R7 (harness packages free of telemetry edges).
