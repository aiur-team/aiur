defmodule Aiur.Tmux.StyleTest do
  use ExUnit.Case, async: false

  alias Aiur.Tmux.Style

  defp mock_state(parent), do: %{transport: {:mock, parent}, session: "test"}

  test "set_pane_border/3 with text emits set-option status then format and returns :ok" do
    parent = self()
    state = mock_state(parent)
    url = "https://claude.ai/code/session_TESTONLY"

    task =
      Task.async(fn ->
        send(parent, :ready)
        Style.set_pane_border(state, "%9", " 📱 #{url} ")
      end)

    assert_receive :ready

    assert_receive {:tmux_mock_out, status_cmd}, 1_000
    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert_receive {:tmux_mock_out, format_cmd}, 1_000
    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert :ok = Task.await(task, 1_000)

    assert status_cmd == "set-option -p -t %9 pane-border-status top"
    assert format_cmd =~ "set-option -p -t %9 pane-border-format"
    assert format_cmd =~ url
  end

  test "set_pane_border/3 with text returns :ok even when tmux errors (secret path)" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Style.set_pane_border(state, "%9", "some text")
      end)

    assert_receive :ready

    assert_receive {:tmux_mock_out, _}, 1_000
    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\nfailed\n%error 1 1 0\n"})

    assert_receive {:tmux_mock_out, _}, 1_000
    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\nfailed\n%error 1 1 0\n"})

    assert :ok = Task.await(task, 1_000)
  end

  test "set_pane_border/3 with nil emits the two set-option -pu unsets" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Style.set_pane_border(state, "%9", nil)
      end)

    assert_receive :ready

    assert_receive {:tmux_mock_out, unset_status}, 1_000
    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert_receive {:tmux_mock_out, unset_format}, 1_000
    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert :ok = Task.await(task, 1_000)

    assert unset_status == "set-option -pu -t %9 pane-border-status"
    assert unset_format == "set-option -pu -t %9 pane-border-format"
  end

  test "set_pane_title/3 emits select-pane -T with spaced title as one argv element" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Style.set_pane_title(state, "%42", "7 CLI: ENS namespace (resolve, reverse, info)")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "select-pane -t %42 -T 7 CLI: ENS namespace (resolve, reverse, info)"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end
end
