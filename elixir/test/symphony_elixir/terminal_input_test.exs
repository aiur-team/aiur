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
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["\e", "[", "B", "\e", "[", "A", :eof])

    assert_receive {:dashboard_cast, {:select_agent, 1}}
    assert_receive {:dashboard_cast, {:select_agent, -1}}
  end

  test "space and enter open the log pane" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, [" ", "\r", "\n", :eof])

    assert_receive {:dashboard_cast, :open_log}
    assert_receive {:dashboard_cast, :open_log}
    assert_receive {:dashboard_cast, :open_log}
  end

  test "left arrow closes the log pane" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["\e", "[", "D", :eof])

    assert_receive {:dashboard_cast, :close_log}
  end

  test "PgUp and PgDn scroll the log pane" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["\e", "[", "5", "~", "\e", "[", "6", "~", :eof])

    assert_receive {:dashboard_cast, {:scroll_log, :up}}
    assert_receive {:dashboard_cast, {:scroll_log, :down}}
  end

  test "bare esc closes the log pane and dispatches the next byte" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    # esc then j: close pane + advance selection in one step.
    start_input(dashboard, ["\e", "j", :eof])

    assert_receive {:dashboard_cast, :close_log}
    assert_receive {:dashboard_cast, {:select_agent, 1}}
  end

  test "unknown CSI sequences are ignored" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    # \e[Z is a real but unhandled CSI sequence (Shift-Tab); should not crash.
    start_input(dashboard, ["\e", "[", "Z", "j", :eof])

    assert_receive {:dashboard_cast, {:select_agent, 1}}
  end

  test "bracketed paste framing is consumed without dispatching individual bytes" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    # \e[200~ ... \e[201~ frames a paste. Pasted bytes (including a `j` that
    # would normally select_next) must NOT dispatch individual semantic casts.
    paste_start = ["\e", "[", "2", "0", "0", "~"]
    paste_body = ["h", "i", "\n", "j", "k"]
    paste_end = ["\e", "[", "2", "0", "1", "~"]
    # After the paste, send a real "j" to confirm normal dispatch resumes.
    bytes = paste_start ++ paste_body ++ paste_end ++ ["j", :eof]

    start_input(dashboard, bytes)

    # Only ONE select_agent cast (from the trailing real `j`), not three
    # (which is what would happen if the pasted j/k bytes leaked through).
    assert_receive {:dashboard_cast, {:select_agent, 1}}
    refute_received {:dashboard_cast, _}
  end

  defp start_input(dashboard, byte_queue) do
    {:ok, input} = Agent.start_link(fn -> byte_queue end)

    {:ok, pid} =
      TerminalInput.start_link(
        dashboard: dashboard,
        input_fun: fn -> Agent.get_and_update(input, fn [next | rest] -> {next, rest} end) end,
        skip_raw_mode: true
      )

    pid
  end
end
