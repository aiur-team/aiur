# MP-R1 core output

Commands target main `889212aa39a2fb992da7942c6e4236f7b70be376`.
Local paths use `<isolated-main>`, `<workspace>` and `<user-state>` placeholders;
ANSI color codes and blank output lines are removed. Result lines are otherwise unchanged.

## 07-core-tests

Working directory: `src`.

Command:

```sh
mise exec -- mix test --max-cases 4 test/aiur/identity_test.exs test/aiur/identity/ test/aiur/capabilities_test.exs test/aiur/capabilities_supervision_test.exs test/aiur/capabilities_notifications_test.exs test/aiur/capabilities_input_failure_test.exs test/aiur/capabilities_wire_test.exs test/aiur/capabilities_cli_test.exs test/aiur/capabilities/ test/aiur_capabilities_engine_test.exs test/aiur_web/controllers/capabilities_controller_test.exs test/aiur_web/capability_error_test.exs test/aiur_web/router_table_test.exs test/aiur_web/endpoint_sockets_test.exs test/aiur_web/dashboard_pages_gate_test.exs test/aiur/application_dashboard_pages_test.exs test/aiur/journal_test.exs test/aiur/journal_compatibility_test.exs test/aiur/signal_test.exs test/aiur/signal_lifecycle_port_test.exs
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:39:07.362496Z
UTC end: 2026-10-26T11:40:03.620263Z
Exit code: 0
aiur_build_gate queued slots=6 command=exec -- mix test --max-cases 4 test/aiur/identity_test.exs test/aiur/identity/ test/aiur/capabilities_test.exs test/aiur/capabilities_supervision_test.exs test/aiur/capabilities_notifications_test.exs test/aiur/capabilities_input_failure_test.exs test/aiur/capabilities_wire_test.exs test/aiur/capabilities_cli_test.exs test/aiur/capabilities/ test/aiur_capabilities_engine_test.exs test/aiur_web/controllers/capabilities_controller_test.exs test/aiur_web/capability_error_test.exs test/aiur_web/router_table_test.exs test/aiur_web/endpoint_sockets_test.exs test/aiur_web/dashboard_pages_gate_test.exs test/aiur/application_dashboard_pages_test.exs test/aiur/journal_test.exs test/aiur/journal_compatibility_test.exs test/aiur/signal_test.exs test/aiur/signal_lifecycle_port_test.exs
aiur_build_gate acquired slot=1 command=exec -- mix test --max-cases 4 test/aiur/identity_test.exs test/aiur/identity/ test/aiur/capabilities_test.exs test/aiur/capabilities_supervision_test.exs test/aiur/capabilities_notifications_test.exs test/aiur/capabilities_input_failure_test.exs test/aiur/capabilities_wire_test.exs test/aiur/capabilities_cli_test.exs test/aiur/capabilities/ test/aiur_capabilities_engine_test.exs test/aiur_web/controllers/capabilities_controller_test.exs test/aiur_web/capability_error_test.exs test/aiur_web/router_table_test.exs test/aiur_web/endpoint_sockets_test.exs test/aiur_web/dashboard_pages_gate_test.exs test/aiur/application_dashboard_pages_test.exs test/aiur/journal_test.exs test/aiur/journal_compatibility_test.exs test/aiur/signal_test.exs test/aiur/signal_lifecycle_port_test.exs
mise WARN  tracking config: failed to ln -sf <isolated-main>/mise.toml <user-state>/mise/tracked-configs/<config-id>: Read-only file system (os error 30)
==> voice_converse
Compiling 50 files (.ex)
Generated voice_converse app
==> aiur
Compiling 2357 files (.ex)
Generated aiur app
Running ExUnit with seed: 706927, max_cases: 4
Excluding tags: [:external, :perf_regression, :quarantine, :orchestrator_guard_probe, :manual_sandbox_reset, {:test, :"test a broker failure refuses the real gh command"}, {:test, :"test post_tool_use hook resets the deadline so the loop survives past the original timeout"}, {:test, :"test a process exiting before initialize persists its status and a redacted bounded diagnostic"}, {:test, :"test Codex adapter treats idle thread status as turn completion"}, {:module, :"Aiur.Core.AgentRunnerCheckpointQueueTest"}, {:test, :"test agent runner interrupts an active turn and waits for the next operator message before resuming"}, {:module, :"Aiur.DaemonHeartbeatTest"}, {:test, :"test a wake stream faster than the debounce still reaches a blocked waiter (#2600)"}, {:test, :"test the running store a checkpoint leaves no copy of the bodies on the store's heap"}, {:test, :"test a direct system gh API path is intercepted by the workspace guard"}, {:module, :"Aiur.OperatorSendTimeoutTest"}, {:module, :"Aiur.Orchestrator.OperatorMessages.CorrelatedReplayWakeTest"}, {:test, :"test CLI reorders three persisted sets and real reconciliation and dispatch follow the new ranks"}, {:test, :"test orchestrator snapshot reads open decisions without calling the per-ticket store"}, {:module, :"Aiur.OrchestratorStatusCliCapacityTest"}, {:module, :"Aiur.ProcessExhaustionTest"}, {:test, :"test future regression guard: tree cleanup kills the root and both background children"}, {:test, :"test pause/resume semantics resume revalidates tracker state after clearing the pause override"}, {:test, :"test cancelled git retains the workspace lock until its process group drains"}, {:test, :"test degraded dependency returns 409 with the typed envelope and current identity"}, {:test, :"test open_decision_count uses blocking Commands rather than attention chips"}]
...........................................................................................................................................................................................
Finished in 6.5 seconds (2.2s async, 4.3s sync)
187 tests, 0 failures (1 excluded)
aiur_build_gate released slot=1 status=0
```

## 08-progress-tests

Working directory: `src`.

Command:

```sh
mise exec -- mix test --max-cases 4 test/aiur/build_order/root_summary_progress_test.exs test/aiur/build_order/progress_renderer_test.exs test/aiur/build_progress_test.exs
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:40:03.646629Z
UTC end: 2026-10-26T11:40:12.128597Z
Exit code: 0
aiur_build_gate queued slots=6 command=exec -- mix test --max-cases 4 test/aiur/build_order/root_summary_progress_test.exs test/aiur/build_order/progress_renderer_test.exs test/aiur/build_progress_test.exs
aiur_build_gate acquired slot=1 command=exec -- mix test --max-cases 4 test/aiur/build_order/root_summary_progress_test.exs test/aiur/build_order/progress_renderer_test.exs test/aiur/build_progress_test.exs
mise WARN  tracking config: failed to ln -sf <isolated-main>/mise.toml <user-state>/mise/tracked-configs/<config-id>: Read-only file system (os error 30)
Running ExUnit with seed: 135556, max_cases: 4
Excluding tags: [:external, :perf_regression, :quarantine, :orchestrator_guard_probe, :manual_sandbox_reset, {:test, :"test a broker failure refuses the real gh command"}, {:test, :"test post_tool_use hook resets the deadline so the loop survives past the original timeout"}, {:test, :"test a process exiting before initialize persists its status and a redacted bounded diagnostic"}, {:test, :"test Codex adapter treats idle thread status as turn completion"}, {:module, :"Aiur.Core.AgentRunnerCheckpointQueueTest"}, {:test, :"test agent runner interrupts an active turn and waits for the next operator message before resuming"}, {:module, :"Aiur.DaemonHeartbeatTest"}, {:test, :"test a wake stream faster than the debounce still reaches a blocked waiter (#2600)"}, {:test, :"test the running store a checkpoint leaves no copy of the bodies on the store's heap"}, {:test, :"test a direct system gh API path is intercepted by the workspace guard"}, {:module, :"Aiur.OperatorSendTimeoutTest"}, {:module, :"Aiur.Orchestrator.OperatorMessages.CorrelatedReplayWakeTest"}, {:test, :"test CLI reorders three persisted sets and real reconciliation and dispatch follow the new ranks"}, {:test, :"test orchestrator snapshot reads open decisions without calling the per-ticket store"}, {:module, :"Aiur.OrchestratorStatusCliCapacityTest"}, {:module, :"Aiur.ProcessExhaustionTest"}, {:test, :"test future regression guard: tree cleanup kills the root and both background children"}, {:test, :"test pause/resume semantics resume revalidates tracker state after clearing the pause override"}, {:test, :"test cancelled git retains the workspace lock until its process group drains"}, {:test, :"test degraded dependency returns 409 with the typed envelope and current identity"}, {:test, :"test open_decision_count uses blocking Commands rather than attention chips"}]
...................................
Finished in 0.6 seconds (0.3s async, 0.2s sync)
35 tests, 0 failures
aiur_build_gate released slot=1 status=0
```

## 09-text-tests

Working directory: `src`.

Command:

```sh
mise exec -- mix test --max-cases 4 test/aiur/opencode/operator_text_test.exs
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:40:12.152613Z
UTC end: 2026-10-26T11:40:22.751654Z
Exit code: 0
aiur_build_gate queued slots=6 command=exec -- mix test --max-cases 4 test/aiur/opencode/operator_text_test.exs
aiur_build_gate acquired slot=1 command=exec -- mix test --max-cases 4 test/aiur/opencode/operator_text_test.exs
aiur_perf phase_stagger_hold surface=build phase=test wait_seconds=3
mise WARN  tracking config: failed to ln -sf <isolated-main>/mise.toml <user-state>/mise/tracked-configs/<config-id>: Read-only file system (os error 30)
Running ExUnit with seed: 432669, max_cases: 4
Excluding tags: [:external, :perf_regression, :quarantine, :orchestrator_guard_probe, :manual_sandbox_reset, {:test, :"test a broker failure refuses the real gh command"}, {:test, :"test post_tool_use hook resets the deadline so the loop survives past the original timeout"}, {:test, :"test a process exiting before initialize persists its status and a redacted bounded diagnostic"}, {:test, :"test Codex adapter treats idle thread status as turn completion"}, {:module, :"Aiur.Core.AgentRunnerCheckpointQueueTest"}, {:test, :"test agent runner interrupts an active turn and waits for the next operator message before resuming"}, {:module, :"Aiur.DaemonHeartbeatTest"}, {:test, :"test a wake stream faster than the debounce still reaches a blocked waiter (#2600)"}, {:test, :"test the running store a checkpoint leaves no copy of the bodies on the store's heap"}, {:test, :"test a direct system gh API path is intercepted by the workspace guard"}, {:module, :"Aiur.OperatorSendTimeoutTest"}, {:module, :"Aiur.Orchestrator.OperatorMessages.CorrelatedReplayWakeTest"}, {:test, :"test CLI reorders three persisted sets and real reconciliation and dispatch follow the new ranks"}, {:test, :"test orchestrator snapshot reads open decisions without calling the per-ticket store"}, {:module, :"Aiur.OrchestratorStatusCliCapacityTest"}, {:module, :"Aiur.ProcessExhaustionTest"}, {:test, :"test future regression guard: tree cleanup kills the root and both background children"}, {:test, :"test pause/resume semantics resume revalidates tracker state after clearing the pause override"}, {:test, :"test cancelled git retains the workspace lock until its process group drains"}, {:test, :"test degraded dependency returns 409 with the typed envelope and current identity"}, {:test, :"test open_decision_count uses blocking Commands rather than attention chips"}]
..............
Finished in 0.03 seconds (0.03s async, 0.00s sync)
14 tests, 0 failures
aiur_build_gate released slot=1 status=0
```

## 13-lint

Working directory: `src`.

Command:

```sh
mise exec -- mix lint
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:40:22.774173Z
UTC end: 2026-10-26T11:42:52.453198Z
Exit code: 0
aiur_build_gate queued slots=6 command=exec -- mix lint
aiur_build_gate acquired slot=1 command=exec -- mix lint
aiur_perf phase_stagger_hold surface=build phase=lint wait_seconds=5
mise WARN  tracking config: failed to ln -sf <isolated-main>/mise.toml <user-state>/mise/tracked-configs/<config-id>: Read-only file system (os error 30)
==> voice_converse
Compiling 50 files (.ex)
Generated voice_converse app
==> aiur
Compiling 2357 files (.ex)
Generated aiur app
lint: running specs.check
specs.check: all public functions have @spec or exemption
lint: running credo --strict
Checking 4930 source files (this might take a while) ...
Please report incorrect results: https://github.com/rrrene/credo/issues
Analysis took 89.5 seconds (3.3s to load, 86.1s running 69 checks on 4930 files)
56515 mods/funs, found no issues.
Use `mix credo explain` to explain issues, `mix credo --help` for options.
aiur_build_gate released slot=1 status=0
```
