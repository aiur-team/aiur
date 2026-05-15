defmodule SymphonyElixir.TerminalInputTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.TerminalInput

  @receive_timeout 1_000

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

    assert_receive {:dashboard_cast, {:select_agent, 1}}, @receive_timeout
    assert_receive {:dashboard_cast, {:select_agent, -1}}, @receive_timeout
  end

  test "space and enter open the log pane in typing mode" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, [" ", "h", "\r", "\n", :eof])

    assert_receive {:dashboard_cast, :open_log}, @receive_timeout
    assert_receive {:dashboard_cast, {:append_text, "h"}}, @receive_timeout
    assert_receive {:dashboard_cast, :submit_message}, @receive_timeout
    assert_receive {:dashboard_cast, :submit_message}, @receive_timeout
  end

  test "left arrow closes the log pane from list focus" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", "\t", "\e", "[", "D", :eof])

    assert_receive {:dashboard_cast, :open_log}, @receive_timeout
    assert_receive {:dashboard_cast, :exit_typing}, @receive_timeout
    assert_receive {:dashboard_cast, :close_log}, @receive_timeout
  end

  test "PgUp and PgDn scroll the log pane" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", "\t", "\e", "[", "5", "~", "\e", "[", "6", "~", :eof])

    assert_receive {:dashboard_cast, :open_log}, @receive_timeout
    assert_receive {:dashboard_cast, :exit_typing}, @receive_timeout
    assert_receive {:dashboard_cast, {:scroll_log, :up}}, @receive_timeout
    assert_receive {:dashboard_cast, {:scroll_log, :down}}, @receive_timeout
  end

  test "tab switches from chat focus to agent-list focus and space reopens selected log" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", "\t", "j", " ", :eof])

    assert_receive {:dashboard_cast, :open_log}, @receive_timeout
    assert_receive {:dashboard_cast, :exit_typing}, @receive_timeout
    assert_receive {:dashboard_cast, {:select_agent, 1}}, @receive_timeout
    assert_receive {:dashboard_cast, :open_log}, @receive_timeout
  end

  test "ctrl-c pauses first and closes log on second press" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", <<3>>, <<3>>, :eof])

    assert_receive {:dashboard_cast, :open_log}, @receive_timeout
    assert_receive {:dashboard_cast, :pause_agent}, @receive_timeout
    assert_receive {:dashboard_cast, :close_log}, @receive_timeout
  end

  test "ctrl-c pause escalation survives tabbing to agent-list focus" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", <<3>>, "\t", <<3>>, :eof])

    assert_receive {:dashboard_cast, :open_log}, @receive_timeout
    assert_receive {:dashboard_cast, :pause_agent}, @receive_timeout
    assert_receive {:dashboard_cast, :exit_typing}, @receive_timeout
    assert_receive {:dashboard_cast, :close_log}, @receive_timeout
  end

  test "q remains literal input in typing mode" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", "q", :eof])

    assert_receive {:dashboard_cast, :open_log}, @receive_timeout
    assert_receive {:dashboard_cast, {:append_text, "q"}}, @receive_timeout
    refute_received {:dashboard_cast, :exit_typing}
  end

  test "bare esc timeout closes log immediately" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", "\e", "", :eof])

    assert_receive {:dashboard_cast, :open_log}, @receive_timeout
    assert_receive {:dashboard_cast, :close_log}, @receive_timeout
  end

  test "typing mode appends text, backspaces, submits, and supports shift-enter newline" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    start_input(dashboard, ["i", "h", "i", <<127>>, "!", "\e", "[", "1", "3", ";", "2", "u", "t", "\n", :eof])

    assert_receive {:dashboard_cast, :open_log}, @receive_timeout
    assert_receive {:dashboard_cast, {:append_text, "h"}}, @receive_timeout
    assert_receive {:dashboard_cast, {:append_text, "i"}}, @receive_timeout
    assert_receive {:dashboard_cast, :backspace}, @receive_timeout
    assert_receive {:dashboard_cast, {:append_text, "!"}}, @receive_timeout
    assert_receive {:dashboard_cast, {:append_text, "\n"}}, @receive_timeout
    assert_receive {:dashboard_cast, {:append_text, "t"}}, @receive_timeout
    assert_receive {:dashboard_cast, :submit_message}, @receive_timeout
  end

  test "unknown CSI sequences are ignored" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    # \e[Z is a real but unhandled CSI sequence (Shift-Tab); should not crash.
    start_input(dashboard, ["\e", "[", "Z", "j", :eof])

    assert_receive {:dashboard_cast, {:select_agent, 1}}, @receive_timeout
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
    assert_receive {:dashboard_cast, {:select_agent, 1}}, @receive_timeout
    refute_received {:dashboard_cast, _}
  end

  test "bracketed paste appends one text block in typing mode" do
    {:ok, dashboard} = DashboardProbe.start_link(self())

    paste_start = ["\e", "[", "2", "0", "0", "~"]
    paste_body = ["h", "i", "\n", "there"]
    paste_end = ["\e", "[", "2", "0", "1", "~"]

    start_input(dashboard, ["i"] ++ paste_start ++ paste_body ++ paste_end ++ [:eof])

    assert_receive {:dashboard_cast, :open_log}, @receive_timeout
    assert_receive {:dashboard_cast, {:append_text, "hi\nthere"}}, @receive_timeout
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
