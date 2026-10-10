defmodule Aiur.CodexProberTest do
  use Aiur.TestSupport

  alias Aiur.AppServer.Adapter
  alias Aiur.Claude.RemoteControl
  alias Aiur.Codex.AppServerPort
  alias Aiur.Codex.Handshake
  alias Aiur.{CodexProber, Config, ModelAvailability}

  test "normalizes rate windows nested in the rateLimits response" do
    response = %{
      "rateLimits" => %{
        "primary" => %{"usedPercent" => 4, "windowDurationMins" => 10_080, "resetsAt" => 1_800_000_000},
        "secondary" => %{"usedPercent" => 12, "windowDurationMins" => 60, "resetsAt" => 1_800_000_100},
        "email" => "private@example.test"
      },
      "rateLimitReachedType" => nil
    }

    assert {:ok,
            %{
              "primary" => %{"usedPercent" => 4, "windowDurationMins" => 10_080, "resetsAt" => 1_800_000_000},
              "secondary" => %{"usedPercent" => 12, "windowDurationMins" => 60, "resetsAt" => 1_800_000_100}
            }} = CodexProber.normalize_codex_limits(response)
  end

  test "rejects a response without rate limit windows" do
    assert {:error, :no_usage_data} = CodexProber.normalize_codex_limits(%{"rateLimits" => %{}})
  end

  test "default probe path starts a narrow app-server in an allowed workspace" do
    parent = self()

    assert {:ok, %{"primary" => %{"usedPercent" => 4}}} =
             CodexProber.fetch_limits("codex",
               start_port_fun: fn workspace, nil, nil, nil ->
                 send(parent, {:probe_workspace, workspace})
                 {:ok, :fake_port}
               end,
               initialize_fun: fn :fake_port -> :ok end,
               read_rate_limits_fun: fn :fake_port ->
                 {:ok, %{"rateLimits" => %{"primary" => %{"usedPercent" => 4, "windowDurationMins" => 60}}}}
               end,
               stop_port_fun: fn :fake_port ->
                 send(parent, :probe_port_stopped)
                 :ok
               end
             )

    assert_receive {:probe_workspace, workspace}, 1_000
    assert String.starts_with?(Path.expand(workspace) <> "/", Path.expand(Config.workspace_root()) <> "/")
    assert {:ok, ^workspace} = AppServerPort.validate_workspace_cwd(workspace, nil)
    assert_receive :probe_port_stopped, 1_000
    refute File.exists?(workspace)
  end

  test "profile probe supplies the selected Codex home only to the child environment" do
    selected_home = Path.join(System.tmp_dir!(), "codex-profile-home")

    assert {:ok, %{"primary" => %{"usedPercent" => 8}}} =
             CodexProber.fetch_limits("codex",
               codex_home: selected_home,
               start_port_fun: fn _workspace, nil, nil, nil, env ->
                 assert env == [{"CODEX_HOME", selected_home}]
                 {:ok, :fake_port}
               end,
               initialize_fun: fn :fake_port -> :ok end,
               read_rate_limits_fun: fn :fake_port ->
                 {:ok, %{"rateLimits" => %{"primary" => %{"usedPercent" => 8}}}}
               end,
               stop_port_fun: fn :fake_port -> :ok end
             )
  end

  test "probe survives a broken stdin pipe and cleans up its process tree and workspace" do
    workspace = Aiur.TestSupport.tmp_root!("codex-broken-pipe")
    parent = self()
    trapping_exits? = elem(Process.info(self(), :trap_exit), 1)

    assert {:error, {:port_exit, :epipe}} =
             CodexProber.fetch_limits("codex",
               workspace: workspace,
               start_port_fun: fn dir, nil, nil, nil ->
                 {:ok, port} =
                   Adapter.start_port(
                     dir,
                     """
                     exec python3 -u -c '
                     import os,signal,time,subprocess
                     signal.signal(signal.SIGCHLD,signal.SIG_IGN)
                     child=subprocess.Popen(["sleep","600"],stdin=subprocess.DEVNULL)
                     os.close(0)
                     print(child.pid)
                     time.sleep(600)'
                     """,
                     fn _port -> :ok end,
                     relay: false
                   )

                 {:os_pid, pid} = Port.info(port, :os_pid)

                 on_exit(fn ->
                   RemoteControl.graceful_kill_tree(pid)
                   File.rm_rf!(workspace)
                 end)

                 send(parent, {:probe_child, port, pid})
                 {:ok, port}
               end,
               initialize_fun: fn port ->
                 assert_receive {^port, {:data, {:eol, child_pid}}}, 5_000
                 send(parent, {:probe_descendant, String.to_integer(child_pid)})
                 Handshake.send_initialize(port)
               end
             )

    assert_receive {:probe_child, port, pid}, 1_000
    assert Port.info(port) == nil
    refute RemoteControl.process_alive?(pid)
    assert_receive {:probe_descendant, child_pid}, 1_000
    refute RemoteControl.process_alive?(child_pid)
    refute File.exists?(workspace)
    assert Process.info(self(), :trap_exit) == {:trap_exit, trapping_exits?}
    refute_receive {:EXIT, ^port, _}, 100
  end

  test "failed child launch removes the probe workspace and restores exit handling" do
    workspace = Aiur.TestSupport.tmp_root!("codex-launch-failure")
    on_exit(fn -> File.rm_rf!(workspace) end)
    trapping_exits? = elem(Process.info(self(), :trap_exit), 1)

    assert {:error, :bash_not_found} =
             CodexProber.fetch_limits("codex",
               workspace: workspace,
               start_port_fun: fn dir, nil, nil, nil ->
                 assert File.dir?(dir)
                 {:error, :bash_not_found}
               end
             )

    refute File.exists?(workspace)
    assert Process.info(self(), :trap_exit) == {:trap_exit, trapping_exits?}
  end

  test "probe_async executes the provider probe and persists its reading" do
    path = Aiur.TestSupport.tmp_root!("aiur-codex-async-probe") <> ".json"
    on_exit(fn -> File.rm(path) end)
    parent = self()
    now = DateTime.utc_now()

    async_call =
      Task.async(fn ->
        CodexProber.probe_async("codex",
          path: path,
          now: now,
          fetch_limits_fun: fn ->
            send(parent, {:provider_probe_started, self()})
            receive do: (:continue_probe -> {:ok, %{"rateLimits" => %{"primary" => %{"usedPercent" => 4, "windowDurationMins" => 60}}}})
          end,
          on_complete_fun: &send(parent, {:probe_result, &1})
        )
      end)

    assert_receive {:provider_probe_started, probe_pid}, 1_000
    async_call_result = Task.yield(async_call, 100)
    send(probe_pid, :continue_probe)
    assert {:ok, :ok} = async_call_result
    assert_receive {:probe_result, result}, 1_000
    assert result == :ok
    assert ModelAvailability.load(path)["backends"]["codex"]["hourly"]["used"] == 4
  end
end
