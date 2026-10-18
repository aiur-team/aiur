defmodule Aiur.Orchestrator.GlobalPauseLegacyResumeTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.{GlobalPause, State}

  test "unpausing resumes a worker held by a legacy global pause" do
    id = "legacy-global-pause-#{System.unique_integer([:positive])}"

    entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: id,
      issue: %Issue{id: id, identifier: id, state: "in-progress", title: "Legacy pause"},
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :global_pause,
      session_id: "thread-#{id}",
      started_at: DateTime.utc_now()
    }

    state = %State{globally_paused: true, running: %{id => entry}}

    assert {:reply, {:ok, %{globally_paused: false}}, resumed_state} =
             GlobalPause.set_global_pause_call(state, false)

    assert resumed_state.running[id].control.status == :working
    refute Map.has_key?(resumed_state.running[id], :paused_reason)
    assert_receive {:resume_agent, _request_id}, 1_000
  end
end
