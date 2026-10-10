defmodule Aiur.AppServer.RelayLaunchCleanupTest do
  use Aiur.TestSupport

  alias Aiur.AppServer.{Adapter, RelayPort, Transport}
  alias Aiur.Config.Paths

  test "failed launcher inherits toolchain variables, applies overrides and removes its spec and directory" do
    root = Aiur.TestSupport.tmp_root!("relay-failed-launch")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    observed = Path.join(root, "observed.json")
    script = Path.join(root, "failed.py")

    File.write!(script, """
    import json,sys
    from pathlib import Path
    spec=json.loads(Path(sys.argv[sys.argv.index('--spec')+1]).read_text())
    Path(#{Jason.encode!(observed)}).write_text(json.dumps({name: spec['env'].get(name) for name in ['AIUR_RELAY_TOOLCHAIN_TEST', 'AIUR_RELAY_OVERRIDE_TEST', 'AIUR_RELAY_REMOVE_TEST']}))
    sys.exit(7)
    """)

    previous = Map.take(System.get_env(), ~w(AIUR_RELAY_TOOLCHAIN_TEST AIUR_RELAY_OVERRIDE_TEST AIUR_RELAY_REMOVE_TEST))
    System.put_env(%{"AIUR_RELAY_TOOLCHAIN_TEST" => "inherited", "AIUR_RELAY_OVERRIDE_TEST" => "original", "AIUR_RELAY_REMOVE_TEST" => "remove"})

    try do
      assert {:error, {:relay_launch_failed, 7, _}} =
               RelayPort.start(File.cwd!(), "exec cat", [{"AIUR_RELAY_OVERRIDE_TEST", "overridden"}, {"AIUR_RELAY_REMOVE_TEST", false}], relay_script: script)

      env = observed |> File.read!() |> Jason.decode!()
      assert env == %{"AIUR_RELAY_TOOLCHAIN_TEST" => "inherited", "AIUR_RELAY_OVERRIDE_TEST" => "overridden", "AIUR_RELAY_REMOVE_TEST" => nil}
      assert_no_launch_artifacts()
    after
      Enum.each(~w(AIUR_RELAY_TOOLCHAIN_TEST AIUR_RELAY_OVERRIDE_TEST AIUR_RELAY_REMOVE_TEST), &restore_env(&1, previous[&1]))
    end
  end

  test "direct and relay providers inherit toolchain variables while removing API keys" do
    names = ~w(AIUR_RELAY_TOOLCHAIN_TEST AIUR_RELAY_TEST_API_KEY)
    previous = Map.take(System.get_env(), names)
    System.put_env(%{"AIUR_RELAY_TOOLCHAIN_TEST" => "inherited", "AIUR_RELAY_TEST_API_KEY" => "synthetic-secret"})

    try do
      for relay? <- [false, true] do
        command = ~S|printf '%s:%s\n' "$AIUR_RELAY_TOOLCHAIN_TEST" "${AIUR_RELAY_TEST_API_KEY-unset}"; read line|
        assert {:ok, provider} = Adapter.start_port(File.cwd!(), command, fn _ -> :ok end, relay: relay?)

        try do
          assert is_pid(provider) == relay?

          if relay? do
            directory = Transport.metadata(provider).directory
            refute File.exists?(Path.join(directory, "spawn.json"))
          end

          assert_receive {^provider, {:data, {:eol, "inherited:unset"}}}, 5_000
        after
          Transport.close(provider)
        end
      end
    after
      Enum.each(names, &restore_env(&1, previous[&1]))
    end
  end

  test "missing interpreter removes its spec and directory before returning a handled launch error" do
    root = Aiur.TestSupport.tmp_root!("relay-missing-python")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    File.ln_s!(System.find_executable("bash"), Path.join(root, "bash"))
    previous = System.get_env("PATH")
    System.put_env("PATH", root)

    try do
      assert {:error, {:relay_launch_failed, _}} = RelayPort.start(File.cwd!(), "exec cat", [])
      assert_no_launch_artifacts()
    after
      System.put_env("PATH", previous)
    end
  end

  defp assert_no_launch_artifacts do
    {:ok, root} = Paths.runtime_state_dir()
    assert Path.wildcard(Path.join([root, "agent-relays", "*"])) == []
  end
end
