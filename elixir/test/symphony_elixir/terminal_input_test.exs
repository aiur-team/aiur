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

  test "space and enter open the log pane in typing mode" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, [" ", "h", "\r", "\n", :eof])

    assert_receive {:dashboard_cast, :open_log}
    assert_receive {:dashboard_cast, {:append_text, "h"}}
    assert_receive {:dashboard_cast, :submit_message}
    assert_receive {:dashboard_cast, :submit_message}
  end

  test "left arrow closes the log pane from list focus" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", "\t", "\e", "[", "D", :eof])

    assert_receive {:dashboard_cast, :open_log}
    assert_receive {:dashboard_cast, :exit_typing}
    assert_receive {:dashboard_cast, :close_log}
  end

  test "PgUp and PgDn scroll the log pane" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", "\t", "\e", "[", "5", "~", "\e", "[", "6", "~", :eof])

    assert_receive {:dashboard_cast, :open_log}
    assert_receive {:dashboard_cast, :exit_typing}
    assert_receive {:dashboard_cast, {:scroll_log, :up}}
    assert_receive {:dashboard_cast, {:scroll_log, :down}}
  end

  test "tab switches from chat focus to agent-list focus and space reopens selected log" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", "\t", "j", " ", :eof])

    assert_receive {:dashboard_cast, :open_log}
    assert_receive {:dashboard_cast, :exit_typing}
    assert_receive {:dashboard_cast, {:select_agent, 1}}
    assert_receive {:dashboard_cast, :open_log}
  end

  test "ctrl-c pauses first and closes log on second press" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", <<3>>, <<3>>, :eof])

    assert_receive {:dashboard_cast, :open_log}
    assert_receive {:dashboard_cast, :pause_agent}
    assert_receive {:dashboard_cast, :close_log}
  end

  test "ctrl-c pause escalation survives tabbing to agent-list focus" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", <<3>>, "\t", <<3>>, :eof])

    assert_receive {:dashboard_cast, :open_log}
    assert_receive {:dashboard_cast, :pause_agent}
    assert_receive {:dashboard_cast, :exit_typing}
    assert_receive {:dashboard_cast, :close_log}
  end

  test "q remains literal input in typing mode" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", "q", :eof])

    assert_receive {:dashboard_cast, :open_log}
    assert_receive {:dashboard_cast, {:append_text, "q"}}
    refute_received {:dashboard_cast, :exit_typing}
  end

  test "bare esc timeout closes log immediately" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", "\e", "", :eof])

    assert_receive {:dashboard_cast, :open_log}
    assert_receive {:dashboard_cast, :close_log}
  end

  test "typing mode appends text, backspaces, submits, and supports alt-enter newline" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", "h", "i", <<127>>, "!", "\e", "\r", "t", "\n", :eof])

    assert_receive {:dashboard_cast, :open_log}
    assert_receive {:dashboard_cast, {:append_text, "h"}}
    assert_receive {:dashboard_cast, {:append_text, "i"}}
    assert_receive {:dashboard_cast, :backspace}
    assert_receive {:dashboard_cast, {:append_text, "!"}}
    assert_receive {:dashboard_cast, {:append_text, "\n"}}
    assert_receive {:dashboard_cast, {:append_text, "t"}}
    assert_receive {:dashboard_cast, :submit_message}
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

  test "bracketed paste appends one text block in typing mode" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    paste_start = ["\e", "[", "2", "0", "0", "~"]
    paste_body = ["h", "i", "\n", "there"]
    paste_end = ["\e", "[", "2", "0", "1", "~"]

    start_input(dashboard, ["i"] ++ paste_start ++ paste_body ++ paste_end ++ [:eof])

    assert_receive {:dashboard_cast, :open_log}
    assert_receive {:dashboard_cast, {:append_text, "hi\nthere"}}
  end

  defp start_input(dashboard, byte_queue) do
    {:ok, input} = Agent.start_link(fn -> byte_queue end)
    name = Module.concat(__MODULE__, "Reader#{System.unique_integer([:positive])}")

    {:ok, pid} =
      TerminalInput.start_link(
        name: name,
        dashboard: dashboard,
        input_fun: fn -> Agent.get_and_update(input, fn [next | rest] -> {next, rest} end) end,
        skip_raw_mode: true
      )

    pid
  end
end
