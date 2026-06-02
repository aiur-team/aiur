defmodule Aiur.AgentList.InputTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentList.Input

  defmodule Target do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_cast(:activate, parent) do
      send(parent, :activated)
      {:noreply, parent}
    end

    def handle_cast(:activate_new_pane, parent) do
      send(parent, :activate_new_pane)
      {:noreply, parent}
    end

    def handle_cast(:toggle_pause, parent) do
      send(parent, :toggle_pause)
      {:noreply, parent}
    end

    def handle_cast({:adjust_max_concurrent_agents, delta}, parent) do
      send(parent, {:adjust_max, delta})
      {:noreply, parent}
    end

    def handle_cast(_cast, parent), do: {:noreply, parent}
  end

  test "space toggles pause while enter opens and arrows adjust max" do
    {:ok, target} = start_supervised({Target, self()})
    input = input_fun([" ", "\r", "\e", "[", "D", "\e", "[", "C", :eof])

    start_supervised!({Input, target: target, input_fun: input, skip_raw_mode: true})

    assert_receive :toggle_pause, 500
    assert_receive :activated, 500
    assert_receive {:adjust_max, -1}, 500
    assert_receive {:adjust_max, 1}, 500
  end

  test "capital-O dispatches activate_new_pane" do
    {:ok, target} = start_supervised({Target, self()})
    input = input_fun(["O", :eof])

    start_supervised!(
      {Input, target: target, input_fun: input, skip_raw_mode: true},
      id: :input_o
    )

    assert_receive :activate_new_pane, 500
  end

  test "CSI-u Shift+Enter (\\e[13;2u) dispatches activate_new_pane" do
    {:ok, target} = start_supervised({Target, self()})

    input =
      input_fun([
        "\e",
        "[",
        "1",
        "3",
        ";",
        "2",
        "u",
        :eof
      ])

    start_supervised!(
      {Input, target: target, input_fun: input, skip_raw_mode: true},
      id: :input_shift_enter
    )

    assert_receive :activate_new_pane, 500
  end

  test "CSI-u plain Enter (\\e[13u) dispatches activate" do
    {:ok, target} = start_supervised({Target, self()})

    input = input_fun(["\e", "[", "1", "3", "u", :eof])

    start_supervised!(
      {Input, target: target, input_fun: input, skip_raw_mode: true},
      id: :input_plain_enter
    )

    assert_receive :activated, 500
  end

  defp input_fun(bytes) do
    {:ok, agent} = Agent.start_link(fn -> bytes end)

    fn ->
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {:eof, []}
      end)
    end
  end
end
