defmodule Aiur.AgentList.ControlsTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.Controls

  defmodule Orchestrator do
    use GenServer
    def start_link(parent, opts \\ []), do: GenServer.start_link(__MODULE__, {parent, opts})
    def init({parent, opts}), do: {:ok, %{parent: parent, opts: Map.new(opts)}}

    def handle_call({:pause_agent, id}, _from, %{parent: parent, opts: opts} = state),
      do:
        (
          send(parent, {:paused, id})
          {:reply, Map.get(opts, :pause_result, {:ok, 1}), state}
        )

    def handle_call({:resume_agent, id}, _from, %{parent: parent, opts: opts} = state),
      do:
        (
          send(parent, {:resumed, id})
          {:reply, Map.get(opts, :resume_result, {:ok, :resumed}), state}
        )

    def handle_call({:set_remote_control, id, desired}, _from, %{parent: parent} = state),
      do:
        (
          send(parent, {:remote, id, desired})
          {:reply, {:ok, :on}, state}
        )

    def handle_call({:adjust_max_concurrent_agents, delta}, _from, %{parent: parent} = state),
      do:
        (
          send(parent, {:adjusted, delta})
          {:reply, {:ok, %{}}, state}
        )
  end

  defp state(orchestrator, summary) do
    %{
      selection_focus: :agents,
      summaries: [summary],
      selection_index: 0,
      orchestrator: orchestrator,
      write_fun: fn _ -> :ok end,
      max_agents_alert?: false,
      remote_control_hint: nil
    }
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

  test "explains that pause and resume are masked by a global pause" do
    {:ok, orchestrator} =
      Orchestrator.start_link(self(),
        pause_result: {:error, :globally_paused},
        resume_result: {:error, :globally_paused}
      )

    state = state(orchestrator, %{identifier: "A", status: :running, work_state: :working})
    assert Controls.toggle_pause(state).remote_control_hint =~ "per-agent pause has no effect"

    paused = %{state | summaries: [%{identifier: "A", status: :running, work_state: :paused}]}
    assert Controls.toggle_pause(paused).remote_control_hint =~ "per-agent resume has no effect"
  end
end
