defmodule Aiur.AppServer.Adapter.PortTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.Adapter
  alias Aiur.AppServer.Transport

  test "start_port/2 starts bash in the requested workspace" do
    assert {:ok, port} = Adapter.start_port(File.cwd!(), "printf '%s\\n' ready")
    assert_receive {^port, {:data, {:eol, "ready"}}}, 1_000
  end

  test "start_port does not source a supplied BASH_ENV file" do
    bash_env = Aiur.TestSupport.tmp_root!("aiur-adapter-startup")
    File.write!(bash_env, "printf 'profile-loaded\n'")
    on_exit(fn -> File.rm(bash_env) end)

    assert {:ok, port} =
             Adapter.start_port(File.cwd!(), "printf 'ready\n'", fn _port -> :ok end, env: [{"BASH_ENV", bash_env}])

    assert_receive {^port, {:data, {:eol, "ready"}}}, 1_000
    refute_receive {^port, {:data, {:eol, "profile-loaded"}}}, 100
  end

  test "start_port does not source operator shell startup files" do
    home = Aiur.TestSupport.tmp_root!("aiur-adapter-home")
    File.mkdir_p!(home)
    File.write!(Path.join(home, ".bash_profile"), "printf 'login-profile-loaded\\n'")
    File.write!(Path.join(home, ".bashrc"), "printf 'interactive-rc-loaded\\n'")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(home) end)

    assert {:ok, port} =
             Adapter.start_port(File.cwd!(), "printf 'ready\\n'", fn _port -> :ok end, env: [{"HOME", home}])

    assert_receive {^port, {:data, {:eol, "ready"}}}, 1_000
    refute_receive {^port, {:data, {:eol, "login-profile-loaded"}}}, 100
    refute_receive {^port, {:data, {:eol, "interactive-rc-loaded"}}}, 100
  end

  test "start_port/4 accepts string-valued launch environment" do
    assert {:ok, port} =
             Adapter.start_port(
               File.cwd!(),
               "printf '%s\\n' \"$CLAUDE_CODE_ENABLE_TELEMETRY\"",
               fn _port -> :ok end,
               env: [{"CLAUDE_CODE_ENABLE_TELEMETRY", "1"}]
             )

    assert_receive {^port, {:data, {:eol, "1"}}}, 1_000
  end

  test "registers a spawned port before start_port returns" do
    parent = self()

    assert {:ok, port} =
             Adapter.start_port(File.cwd!(), "sleep 600", fn spawned_port ->
               send(parent, {:port_registered_at_spawn, spawned_port})
               :ok
             end)

    try do
      assert_received {:port_registered_at_spawn, ^port}
    after
      Transport.close(port)
    end
  end

  test "start_port/2 caps schedulers for an agent-launched Mix VM" do
    mix = System.find_executable("mix") || flunk("mix executable unavailable")
    elixir = System.find_executable("elixir") || flunk("elixir executable unavailable")
    path = Path.dirname(elixir) <> ":" <> System.get_env("PATH")
    expression = ~S|IO.puts("#{System.get_env("AIUR_AGENT_MIX_SCHEDULERS")}:#{System.schedulers_online()}")|

    # Exercise the agent cap independently of the parent test VM's scheduler flags.
    assert {:ok, port} =
             Adapter.start_port(
               File.cwd!(),
               "PATH=#{Aiur.Shell.escape(path)} #{Aiur.Shell.escape(mix)} run --no-compile --no-deps-check --no-start -e #{Aiur.Shell.escape(expression)}",
               fn _port -> :ok end,
               env: [{"ERL_FLAGS", false}]
             )

    assert_receive {^port, {:data, {:eol, "4:4"}}}, 20_000
  end
end
