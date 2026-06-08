defmodule Aiur.Claude.ReplAgentTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.ReplAgent
  alias Aiur.Tmux

  setup do
    test_pid = self()
    name = Module.concat(__MODULE__, :"Inst#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      start_supervised({Tmux, [transport: {:mock, test_pid}, name: name, session: "test"]})

    %{tmux: name}
  end

  # Respond to one mock tmux call framed like the control-mode wire format.
  defp respond(tmux, body) do
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}%end 1 1 0\n"})
  end

  defp respond_error(tmux, body) do
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}%error 1 1 0\n"})
  end

  test "start_session spawns the REPL, awaits readiness, and returns a session", %{tmux: tmux} do
    ws = System.tmp_dir!()

    task =
      Task.async(fn ->
        ReplAgent.start_session(ws,
          tmux: tmux,
          model: "claude-opus-4-8",
          rc_name: "aiur-repl-test",
          window_name: "aiur-repl-test",
          projects_dir: "/nonexistent-projects-dir"
        )
      end)

    # 1. new-window spawns the pane.
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert String.starts_with?(cmd, "new-window -d -n aiur-repl-test")
    assert String.contains?(cmd, "exec claude")
    assert String.contains?(cmd, "--model 'claude-opus-4-8'")
    refute String.contains?(cmd, "--remote-control")
    respond(tmux, "%99\n")

    # 2. await_ready captures the pane until the prompt glyph shows.
    assert_receive {:tmux_mock_out, "capture-pane -p -t %99"}, 1_000
    respond(tmux, "Welcome\n❯\n")

    # 3. pane_pid resolves the OS pid.
    assert_receive {:tmux_mock_out, "display-message -p -t %99 \#{pane_pid}"}, 1_000
    respond(tmux, "4242\n")

    assert {:ok, session} = Task.await(task, 2_000)
    assert session.backend == "claude-repl"
    assert session.pane_id == "%99"
    assert session.os_pid == 4242
    assert session.workspace == ws
    assert session.model == "claude-opus-4-8"
    assert session.remote_control == false
    assert session.transcript_path == nil
  end

  test "start_session passes --remote-control when opted in", %{tmux: tmux} do
    ws = System.tmp_dir!()

    task =
      Task.async(fn ->
        ReplAgent.start_session(ws,
          tmux: tmux,
          remote_control: true,
          rc_name: "aiur-rc-test",
          window_name: "aiur-rc-test",
          projects_dir: "/nonexistent-projects-dir"
        )
      end)

    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert String.contains?(cmd, "--remote-control 'aiur-rc-test'")
    respond(tmux, "%7\n")

    assert_receive {:tmux_mock_out, "capture-pane -p -t %7"}, 1_000
    respond(tmux, "❯\n")

    assert_receive {:tmux_mock_out, "display-message -p -t %7 \#{pane_pid}"}, 1_000
    respond(tmux, "10\n")

    assert {:ok, session} = Task.await(task, 2_000)
    assert session.remote_control == true
  end

  test "start_session kills the pane and errors when the REPL never becomes ready", %{tmux: tmux} do
    ws = System.tmp_dir!()

    task =
      Task.async(fn ->
        ReplAgent.start_session(ws,
          tmux: tmux,
          window_name: "aiur-noready",
          ready_timeout_ms: 0,
          projects_dir: "/nonexistent-projects-dir"
        )
      end)

    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert String.starts_with?(cmd, "new-window")
    respond(tmux, "%5\n")

    # Readiness polls capture-pane; never show the prompt. With a 0ms deadline
    # the first non-matching capture exhausts the budget and the pane is killed.
    drain_until_kill(tmux, "%5", task)
  end

  # Keep answering capture-pane (no prompt) until the readiness deadline
  # elapses and start_session issues kill-pane, then assert the error.
  defp drain_until_kill(tmux, pane, task) do
    receive do
      {:tmux_mock_out, "capture-pane -p -t " <> ^pane} ->
        respond(tmux, "still booting\n")
        drain_until_kill(tmux, pane, task)

      {:tmux_mock_out, "kill-pane -t " <> ^pane} ->
        respond(tmux, "")
        assert {:error, :repl_not_ready} = Task.await(task, 2_000)
    after
      2_000 -> flunk("did not observe kill-pane within timeout")
    end
  end

  test "start_session surfaces a spawn error without awaiting readiness", %{tmux: tmux} do
    ws = System.tmp_dir!()

    task =
      Task.async(fn ->
        ReplAgent.start_session(ws,
          tmux: tmux,
          window_name: "aiur-fail",
          projects_dir: "/nonexistent-projects-dir"
        )
      end)

    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert String.starts_with?(cmd, "new-window")
    respond_error(tmux, "no server running\n")

    assert {:error, _} = Task.await(task, 2_000)
    refute_receive {:tmux_mock_out, "capture-pane" <> _}, 200
  end

  test "stop_session kills the pane and graceful-kills the os pid", %{tmux: tmux} do
    session = %{
      backend: "claude-repl",
      pane_id: "%88",
      os_pid: nil,
      workspace: System.tmp_dir!(),
      transcript_path: nil,
      model: nil,
      remote_control: false,
      rc_name: "x",
      tmux: tmux
    }

    task = Task.async(fn -> ReplAgent.stop_session(session) end)

    assert_receive {:tmux_mock_out, "kill-pane -t %88"}, 1_000
    respond(tmux, "")

    assert :ok = Task.await(task, 2_000)
  end
end
