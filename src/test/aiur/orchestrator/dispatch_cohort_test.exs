defmodule Aiur.Orchestrator.DispatchCohortTest do
  use Aiur.TestSupport
  alias Aiur.Orchestrator.{Dispatcher, State}
  alias Aiur.RunTelemetry.Lifecycle

  test "the actual dispatch point records the selected cohort and starts its runner" do
    parent = self()
    previous = Application.get_env(:aiur, :run_telemetry_lifecycle_recorder)
    Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, fn kind, attrs, _ -> send(parent, {:record, kind, attrs}) end)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, previous), else: Application.delete_env(:aiur, :run_telemetry_lifecycle_recorder)
    end)

    issue = %Issue{
      id: "cohort-dispatch",
      identifier: "3794",
      state: "todo",
      selected_backend: "codex",
      selected_model: "cohort-model",
      labels: ["experiment:x", "model:high"],
      blocked_by: [%{identifier: "3755"}]
    }

    # Stand-in for a runner leaked by an earlier test: its record arrives first.
    Task.await(Task.async(fn -> Lifecycle.record("leaked", "leaked:attempt", :agent_spinup, :start) end))

    state =
      Dispatcher.do_dispatch_issue(%State{max_concurrent_agents: 1, effective_concurrent_agents: 1}, issue, nil, nil,
        runner: fn dispatched, _, _ ->
          send(parent, {:started, dispatched.id})
          :ok
        end
      )

    assert Map.has_key?(state.running, issue.id)
    receive_barrier({:started, "cohort-dispatch"})
    # The recorder is global app env, so a runner leaked by an earlier test can
    # deliver its own lifecycle records (e.g. agent_spinup) here first.
    assert_received {:record, :lifecycle, %{ticket: "3794", event: "dispatch"} = attrs}
    assert {attrs.backend, attrs.model, attrs.effort, attrs.tags, attrs.blockers, attrs.start_mode} == {"codex", "cohort-model", "high", ["experiment:x"], ["3755"], "ready"}
  end
end
