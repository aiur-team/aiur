defmodule Aiur.ProcessReaperAgentSocketTest do
  use ExUnit.Case, async: false
  alias Aiur.Claude.Repl.Launcher
  alias Aiur.{ProcessReaper, Tmux}

  test "REPL launcher defaults to agent socket context and records that socket" do
    previous = System.get_env("AIUR_AGENT_TMUX_SOCKET")
    System.put_env("AIUR_AGENT_TMUX_SOCKET", "isolated-launch-agents")

    on_exit(fn ->
      if previous, do: System.put_env("AIUR_AGENT_TMUX_SOCKET", previous), else: System.delete_env("AIUR_AGENT_TMUX_SOCKET")
    end)

    {:ok, tmux} = start_supervised({Tmux, name: Tmux, transport: {:mock, self()}})

    task =
      Task.async(fn ->
        Launcher.start_session(System.tmp_dir!(),
          hook_settings_fun: fn _rc, _identifier -> nil end,
          process_group_fun: fn pid -> pid end,
          process_identity_fun: fn _pid -> :gone end,
          projects_dir: "/nonexistent"
        )
      end)

    assert_receive {:tmux_mock_out, command}, 1_000
    assert String.starts_with?(command, "new-window")
    send(tmux, {:tmux_mock_data, "%begin 1 1 0\n%0\n%end 1 1 0\n"})
    assert_receive {:tmux_mock_out, "display-message -p -t %0 \#{pane_pid}"}, 1_000
    send(tmux, {:tmux_mock_data, "%begin 1 1 0\n999999999\n%end 1 1 0\n"})
    assert_receive {:tmux_mock_out, "capture-pane -p -t %0"}, 1_000
    send(tmux, {:tmux_mock_data, "%begin 1 1 0\n❯\n%end 1 1 0\n"})
    assert {:ok, session} = Task.await(task)
    assert session.tmux == {:socket, Tmux, "isolated-launch-agents"}
    assert session.tmux_socket == "isolated-launch-agents"
  end

  test "socket pane registrations reap the correct server even without a tmux GenServer" do
    socket = "aiur-reaper-unit-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
    sibling = socket <> "-sibling"
    previous = Application.get_env(:aiur, :process_reaper_registrations)
    Application.put_env(:aiur, :process_reaper_registrations, true)
    name = Module.concat(__MODULE__, :"Reaper#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}")
    {:ok, reaper} = start_supervised({ProcessReaper, name: name})

    on_exit(fn ->
      Application.put_env(:aiur, :process_reaper_registrations, previous)
      for value <- [socket, sibling], do: System.cmd("tmux", ["-L", value, "kill-server"], stderr_to_stdout: true)
    end)

    for value <- [socket, sibling], do: assert({_, 0} = System.cmd("tmux", ["-L", value, "new-session", "-d", "-s", "repl", "sleep 120"]))
    assert :ok = ProcessReaper.register(reaper, :agent, {:pane, "%0", socket}, [])
    assert [{{:pane, "%0", ^socket}, :agent, %{}}] = ProcessReaper.entries(reaper)
    assert :ok = ProcessReaper.reap(reaper, [:agent], [])
    {_, result} = System.cmd("tmux", ["-L", socket, "has-session"], stderr_to_stdout: true)
    assert result != 0
    assert {_, 0} = System.cmd("tmux", ["-L", sibling, "has-session"])
  end
end
