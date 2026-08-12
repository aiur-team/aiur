defmodule Aiur.TmuxTest do
  use ExUnit.Case, async: true

  alias Aiur.Tmux

  setup do
    test_pid = self()
    name = Module.concat(__MODULE__, :"Inst#{System.unique_integer([:positive])}")

    {:ok, pid} =
      start_supervised({Tmux, [transport: {:mock, test_pid}, name: name, session: "test"]})

    %{server: pid, name: name}
  end

  test "two unnamed instances start independently" do
    {:ok, first} =
      start_supervised({Tmux, [transport: {:mock, self()}, session: "first"]}, id: :first_unnamed_tmux)

    {:ok, second} =
      start_supervised({Tmux, [transport: {:mock, self()}, session: "second"]}, id: :second_unnamed_tmux)

    assert first != second
  end

  test "command/2 forwards a line to tmux and returns the parsed response", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :task_started)
        Tmux.command(name, "list-panes")
      end)

    assert_receive :task_started
    assert_receive {:tmux_mock_out, "list-panes"}, 1_000

    # Mock a tmux response framed like the control-mode wire format.
    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%1\n%end 1 1 0\n"})

    assert {:ok, ["%1"]} = Task.await(task, 1_000)
  end

  test "command/2 surfaces error responses", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.command(name, "bogus")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, "bogus"}

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\nfail\n%error 1 1 0\n"})

    assert {:error, ["fail"]} = Task.await(task, 1_000)
  end

  test "session/1 returns the configured session name", %{name: name} do
    assert "test" = Tmux.session(name)
  end

  test "move_pane_hidden/3 issues move-pane -d -h to the hidden target", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.move_pane_hidden(name, "%42", "_aiur_warm")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "move-pane -d -s %42 -t _aiur_warm -h"

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end

  test "set_pane_border/3 turns on the top border and forwards the text to that pane", %{name: name} do
    parent = self()
    # The text carries the RC session URL — a capability token. This test
    # asserts it reaches tmux on the pane-border-format arg; the security
    # property (never logged) is enforced by the dedicated silent exec path
    # in Tmux, which logs no args.
    url = "https://claude.ai/code/session_TESTONLY"

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.set_pane_border(name, "%9", " 📱 #{url} ")
      end)

    assert_receive :ready

    assert_receive {:tmux_mock_out, status_cmd}, 1_000
    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert_receive {:tmux_mock_out, format_cmd}, 1_000
    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert :ok = Task.await(task, 1_000)

    assert status_cmd == "set-option -p -t %9 pane-border-status top"
    assert format_cmd =~ "set-option -p -t %9 pane-border-format"
    assert format_cmd =~ url
  end

  test "set_pane_border/3 with nil unsets both border options on that pane", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.set_pane_border(name, "%9", nil)
      end)

    assert_receive :ready

    assert_receive {:tmux_mock_out, unset_status}, 1_000
    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert_receive {:tmux_mock_out, unset_format}, 1_000
    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert :ok = Task.await(task, 1_000)

    assert unset_status == "set-option -pu -t %9 pane-border-status"
    assert unset_format == "set-option -pu -t %9 pane-border-format"
  end

  test "move_pane_visible/3 issues move-pane -s -t -h (no -d) to the visible target", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.move_pane_visible(name, "%42", "agents")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "move-pane -s %42 -t agents -h"

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end

  test "set_pane_title/3 issues select-pane -T with the title as one argv element", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.set_pane_title(name, "%42", "7 CLI: ENS namespace (resolve, reverse, info)")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "select-pane -t %42 -T 7 CLI: ENS namespace (resolve, reverse, info)"

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end

  test "list_panes/2 returns pane ids for a target window", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.list_panes(name, "test:0")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "list-panes -t test:0 -F \#{pane_id}"

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%10\n%11\n%end 1 1 0\n"})

    assert {:ok, ["%10", "%11"]} = Task.await(task, 1_000)
  end

  test "new_hidden_window/3 creates a background window and returns its pane id", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.new_hidden_window(name, "aiur-repl-1", "exec claude")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "new-window -d -n aiur-repl-1 -P -F \#{pane_id} exec claude"

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%5\n%end 1 1 0\n"})
    assert {:ok, "%5"} = Task.await(task, 1_000)
  end

  test "new_hidden_window_with_env/4 passes launch-only environment through tmux", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)

        Tmux.new_hidden_window_with_env(name, "aiur-repl-telemetry", "exec claude", [
          {"CLAUDE_CODE_ENABLE_TELEMETRY", "1"},
          {"OTEL_RESOURCE_ATTRIBUTES", false}
        ])
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "new-window -d -n aiur-repl-telemetry -e CLAUDE_CODE_ENABLE_TELEMETRY=1 -e OTEL_RESOURCE_ATTRIBUTES= -P -F \#{pane_id} exec claude"

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%8\n%end 1 1 0\n"})
    assert {:ok, "%8"} = Task.await(task, 1_000)
  end

  test "new_hidden_window/3 bootstraps the session when no server is running", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.new_hidden_window(name, "aiur-repl-1", "exec claude")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, "new-window" <> _}, 1_000

    # No tmux server on the socket yet — `new-window` fails.
    send(
      GenServer.whereis(name),
      {:tmux_mock_data, "%begin 1 1 0\nno server running on /tmp/tmux-1001/test\n%error 1 1 0\n"}
    )

    # Falls back to `new-session`, which starts the server and the window.
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "new-session -d -s test -n aiur-repl-1 -P -F \#{pane_id} exec claude"

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%7\n%end 1 1 0\n"})
    assert {:ok, "%7"} = Task.await(task, 1_000)
  end

  test "move_pane_hidden/3 surfaces tmux errors as {:error, _}", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.move_pane_hidden(name, "%bogus", "_aiur_warm")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    send(
      GenServer.whereis(name),
      {:tmux_mock_data, "%begin 1 1 0\ncan't find pane: %bogus\n%error 1 1 0\n"}
    )

    assert {:error, _} = Task.await(task, 1_000)
  end

  test "capture_pane/2 returns the pane's visible lines", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.capture_pane(name, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "capture-pane -p -t %42"

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\nline one\n❯\n%end 1 1 0\n"})

    assert {:ok, ["line one", "❯"]} = Task.await(task, 1_000)
  end

  test "paste_text/3 loads a buffer then pastes it into the pane", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.paste_text(name, "%42", "multi\nline\nprompt")
      end)

    assert_receive :ready

    assert_receive {:tmux_mock_out, "load-buffer -b " <> rest1}, 1_000
    [buffer, tmp] = String.split(rest1, " ", parts: 2)
    assert String.starts_with?(buffer, "aiur-paste-")
    assert File.read!(tmp) == "multi\nline\nprompt"
    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert_receive {:tmux_mock_out, cmd}, 1_000
    # `-p` wraps the paste in bracketed-paste markers so a TUI (claude REPL)
    # collapses a multi-line paste into a submittable `[Pasted text]` chip
    # instead of expanded newlines (where Enter inserts a newline, not submit).
    assert cmd == "paste-buffer -p -d -b #{buffer} -t %42"
    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert :ok = Task.await(task, 1_000)
    refute File.exists?(tmp)
  end

  test "kill_pane/2 issues kill-pane and returns :ok", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.kill_pane(name, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "kill-pane -t %42"

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert :ok = Task.await(task, 1_000)
  end

  test "send_interrupt/2 issues send-keys C-c and returns :ok", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.send_interrupt(name, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "send-keys -t %42 C-c"

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert :ok = Task.await(task, 1_000)
  end

  test "kill_pane/2 treats an already-gone pane as :ok", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.kill_pane(name, "%gone")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    send(
      GenServer.whereis(name),
      {:tmux_mock_data, "%begin 1 1 0\ncan't find pane: %gone\n%error 1 1 0\n"}
    )

    assert :ok = Task.await(task, 1_000)
  end

  test "pane_pid/2 parses the integer pid for a pane", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.pane_pid(name, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "display-message -p -t %42 \#{pane_pid}"

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n12345\n%end 1 1 0\n"})

    assert {:ok, 12_345} = Task.await(task, 1_000)
  end

  test "pane_pid/2 returns an error when no pid is printed", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.pane_pid(name, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert {:error, :no_pane_pid} = Task.await(task, 1_000)
  end
end
