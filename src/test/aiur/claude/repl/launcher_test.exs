defmodule Aiur.Claude.Repl.LauncherTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.Repl.Launcher
  alias Aiur.{ProcessReaper, Tmux}

  setup do
    test_pid = self()
    name = Module.concat(__MODULE__, :"Inst#{System.unique_integer([:positive])}")
    reaper = Module.concat(__MODULE__, :"Reaper#{System.unique_integer([:positive])}")
    {:ok, _pid} = start_supervised({Tmux, [transport: {:mock, test_pid}, name: name, session: "test"]})
    {:ok, _pid} = start_supervised({ProcessReaper, name: reaper})
    %{tmux: name, reaper: reaper}
  end

  defp respond(tmux, body) do
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}%end 1 1 0\n"})
  end

  # Drain capture-pane polls (no ready prompt) until kill-pane arrives.
  defp drain_until_kill(tmux, pane, task) do
    receive do
      {:tmux_mock_out, "capture-pane -p -t " <> ^pane} ->
        respond(tmux, "still booting\n")
        drain_until_kill(tmux, pane, task)

      {:tmux_mock_out, "kill-pane -t " <> ^pane} ->
        respond(tmux, "")
        assert {:error, :repl_not_ready} = Task.await(task, 2_000)
    after
      3_000 -> flunk("did not observe kill-pane within timeout")
    end
  end

  test "readiness timeout kills the pane and returns {:error, :repl_not_ready}", %{tmux: tmux} do
    ws = Path.expand(System.tmp_dir!())

    task =
      Task.async(fn ->
        Launcher.start_session(ws,
          tmux: tmux,
          window_name: "aiur-repl-test",
          ready_timeout_ms: 0,
          projects_dir: "/nonexistent"
        )
      end)

    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert String.starts_with?(cmd, "new-window")
    respond(tmux, "%10\n")

    drain_until_kill(tmux, "%10", task)
  end

  test "ready non-RC spawn returns session with backend=claude-repl and registers both ProcessReaper keys", %{
    tmux: tmux,
    reaper: reaper
  } do
    ws = Path.expand(System.tmp_dir!())
    previous_registrations = Application.get_env(:aiur, :process_reaper_registrations)
    Application.put_env(:aiur, :process_reaper_registrations, true)

    on_exit(fn ->
      ProcessReaper.unregister(reaper, {:pane, "%20"})
      ProcessReaper.unregister(reaper, {:os_pid, 5050})
      Application.put_env(:aiur, :process_reaper_registrations, previous_registrations)
    end)

    task =
      Task.async(fn ->
        Launcher.start_session(ws,
          tmux: tmux,
          process_reaper: reaper,
          identifier: "930",
          model: "claude-sonnet-5",
          window_name: "aiur-repl-test",
          projects_dir: "/nonexistent"
        )
      end)

    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert String.starts_with?(cmd, "new-window")
    assert String.contains?(cmd, "exec claude")
    refute String.contains?(cmd, "--remote-control")
    respond(tmux, "%20\n")

    assert_receive {:tmux_mock_out, "capture-pane -p -t %20"}, 1_000
    respond(tmux, "❯\n")

    assert_receive {:tmux_mock_out, "display-message -p -t %20 \#{pane_pid}"}, 1_000
    respond(tmux, "5050\n")

    assert {:ok, session} = Task.await(task, 2_000)
    assert session.backend == "claude-repl"
    assert session.pane_id == "%20"
    assert session.os_pid == 5050
    assert session.workspace == ws
    assert session.remote_control == false
    assert session.session_url == nil

    actor_meta = %{ticket: "930", backend: "claude-repl", worker_host: nil, remote: false}

    assert {{:pane, "%20"}, :agent, actor_meta} in ProcessReaper.entries(reaper)

    assert {{:os_pid, 5050}, :agent, Map.put(actor_meta, :comm, "claude")} in ProcessReaper.entries(reaper)
  end

  test "RC spawn with no attach evidence kills the pane and returns {:error, :remote_control_unavailable}", %{tmux: tmux} do
    ws = Path.expand(System.tmp_dir!())

    task =
      Task.async(fn ->
        Launcher.start_session(ws,
          tmux: tmux,
          remote_control: true,
          identifier: "930",
          hook_settings_fun: fn true, "930" -> "/tmp/aiur-hooks-930.json" end,
          rc_name: "aiur-rc-test",
          window_name: "aiur-rc-test",
          # 0ms URL capture budget so the first banner-less capture exhausts it
          url_capture_timeout_ms: 0,
          projects_dir: "/nonexistent"
        )
      end)

    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert String.contains?(cmd, "--remote-control")
    respond(tmux, "%30\n")

    assert_receive {:tmux_mock_out, "capture-pane -p -t %30"}, 1_000
    respond(tmux, "❯\n")

    assert_receive {:tmux_mock_out, "display-message -p -t %30 \#{pane_pid}"}, 1_000
    # Safe dead pid
    respond(tmux, "2147480000\n")

    # RC evidence scan: no banner
    assert_receive {:tmux_mock_out, "capture-pane -p -t %30"}, 1_000
    respond(tmux, "❯\n")

    # Pane must be killed on RC-unavailable degrade
    assert_receive {:tmux_mock_out, "kill-pane -t %30"}, 1_000
    respond(tmux, "")

    assert {:error, :remote_control_unavailable} = Task.await(task, 2_000)
  end

  test "RC spawn fails before opening a pane when the lifecycle-hook listener is unavailable", %{tmux: tmux} do
    assert {:error, :remote_control_requires_dashboard} =
             Launcher.start_session(Path.expand(System.tmp_dir!()),
               tmux: tmux,
               remote_control: true,
               identifier: "1077",
               hook_settings_fun: fn true, "1077" -> nil end
             )

    refute_receive {:tmux_mock_out, _command}, 100
  end
end
