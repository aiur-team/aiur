defmodule Aiur.AgentList.ControlsTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.Controls

  defmodule Orchestrator do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:pause_agent, id}, _from, parent),
      do:
        (
          send(parent, {:paused, id})
          {:reply, {:ok, 1}, parent}
        )

    def handle_call({:resume_agent, id}, _from, parent),
      do:
        (
          send(parent, {:resumed, id})
          {:reply, {:ok, :resumed}, parent}
        )

    def handle_call({:set_remote_control, id, desired}, _from, parent),
      do:
        (
          send(parent, {:remote, id, desired})
          {:reply, {:ok, :on}, parent}
        )

    def handle_call({:adjust_max_concurrent_agents, delta}, _from, parent),
      do:
        (
          send(parent, {:adjusted, delta})
          {:reply, {:ok, %{}}, parent}
        )
  end

  defp state(orchestrator, summary) do
    %{selection_focus: :agents, summaries: [summary], selection_index: 0, orchestrator: orchestrator, write_fun: fn _ -> :ok end, max_agents_alert?: false, remote_control_hint: nil}
  end

  test "routes pause, remote control, and concurrent-cap controls" do
    {:ok, orchestrator} = Orchestrator.start_link(self())
    state = state(orchestrator, %{identifier: "A", status: :running, work_state: :working})
    assert ^state = Controls.toggle_pause(state)
    assert_receive {:paused, "A"}
    state = Controls.toggle_remote_control(state)
    assert_receive {:remote, "A", true}
    assert ^state = Controls.adjust_max_concurrent_agents(state, 1)
    assert_receive {:adjusted, 1}
  end
end
