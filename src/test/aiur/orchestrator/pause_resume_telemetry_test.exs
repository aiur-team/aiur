defmodule Aiur.Orchestrator.PauseResumeTelemetryTest do
  use ExUnit.Case, async: false

  alias Aiur.Issue
  alias Aiur.Orchestrator.{PauseResume, State}

  setup do
    previous_recorder =
      Application.get_env(:aiur, :run_telemetry_lifecycle_recorder)

    test_pid = self()

    Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, fn kind, attributes, opts ->
      send(test_pid, {:lifecycle, kind, attributes, opts})
      :ok
    end)

    on_exit(fn ->
      case previous_recorder do
        nil -> Application.delete_env(:aiur, :run_telemetry_lifecycle_recorder)
        recorder -> Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, recorder)
      end
    end)

    :ok
  end

  test "records one caused pause and resume at accepted control transitions" do
    issue = %Issue{id: "gid-930", identifier: "930"}

    entry = %{
      identifier: "930",
      issue: issue,
      telemetry_attempt_id: "attempt-1",
      control: %{status: :working}
    }

    state = %State{running: %{issue.id => entry}}
    paused = PauseResume.transition_control_status(state, entry, :paused, "operator.pause")
    paused_entry = paused.running[issue.id]
    _resumed = PauseResume.transition_control_status(paused, paused_entry, :working, "operator.resume")

    assert_receive {:lifecycle, :lifecycle, paused_event, []}
    assert_receive {:lifecycle, :lifecycle, resumed_event, []}

    assert paused_event.event == "agent_pause"
    assert paused_event.cause == "operator.pause"
    assert resumed_event.event == "agent_resume"
    assert resumed_event.cause == "operator.resume"
    assert paused_event.attempt_id == "attempt-1"
    assert resumed_event.attempt_id == "attempt-1"
  end
end
