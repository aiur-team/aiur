defmodule Aiur.Tmux.InputTest do
  use ExUnit.Case, async: false

  alias Aiur.Tmux.Input

  defp mock_state(parent), do: %{transport: {:mock, parent}, session: "test"}

  test "send_keys_literal/3 emits send-keys -t pane -l text" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Input.send_keys_literal(state, "%42", "hello")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "send-keys -t %42 -l hello"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end

  test "send_enter/2 emits send-keys -t pane Enter" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Input.send_enter(state, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "send-keys -t %42 Enter"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end

  test "clear_input/2 emits send-keys -t pane C-u" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Input.clear_input(state, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "send-keys -t %42 C-u"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end

  test "send_interrupt/2 emits send-keys -t pane C-c" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Input.send_interrupt(state, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "send-keys -t %42 C-c"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end

  test "send_escape/2 emits send-keys -t pane Escape" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Input.send_escape(state, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "send-keys -t %42 Escape"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end

  test "paste_text/3 writes temp file, emits load-buffer then paste-buffer, removes file" do
    parent = self()
    state = mock_state(parent)
    text = "multi\nline\nprompt"

    task =
      Task.async(fn ->
        send(parent, :ready)
        Input.paste_text(state, "%42", text)
      end)

    assert_receive :ready

    assert_receive {:tmux_mock_out, "load-buffer -b " <> rest1}, 1_000
    [buffer, tmp] = String.split(rest1, " ", parts: 2)
    assert String.starts_with?(buffer, "aiur-paste-")
    assert File.read!(tmp) == text
    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "paste-buffer -p -d -b #{buffer} -t %42"
    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert :ok = Task.await(task, 1_000)
    refute File.exists?(tmp)
  end
end
