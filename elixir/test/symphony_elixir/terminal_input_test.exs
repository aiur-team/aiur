defmodule SymphonyElixir.TerminalInputTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TerminalInput

  defmodule DashboardProbe do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    @impl true
    def init(parent), do: {:ok, parent}

    @impl true
    def handle_cast(message, parent) do
      send(parent, {:dashboard_cast, message})
      {:noreply, parent}
    end
  end

  test "arrow keys dispatch dashboard selection commands without echoing through stdio" do
    parent = self()

    {:ok, dashboard} = DashboardProbe.start_link(parent)

    {:ok, input} = Agent.start_link(fn -> ["\e", "[", "B", "\e", "[", "A", :eof] end)

    {:ok, _pid} =
      TerminalInput.start_link(
        dashboard: dashboard,
        input_fun: fn -> Agent.get_and_update(input, fn [next | rest] -> {next, rest} end) end,
        skip_raw_mode: true
      )

    assert_receive {:dashboard_cast, {:select_agent, 1}}
    assert_receive {:dashboard_cast, {:select_agent, -1}}
  end
end
