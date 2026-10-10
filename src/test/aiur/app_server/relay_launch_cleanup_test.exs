defmodule Aiur.AppServer.RelayLaunchCleanupTest do
  use Aiur.TestSupport

  alias Aiur.AppServer.RelayPort
  alias Aiur.Config.Paths

  test "failed launcher receives only runtime variables and explicit overrides, then removes its spec and directory" do
    root = Aiur.TestSupport.tmp_root!("relay-failed-launch")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    observed = Path.join(root, "observed.json")
    script = Path.join(root, "failed.py")

    File.write!(script, """
    import json,sys
    from pathlib import Path
    spec=json.loads(Path(sys.argv[sys.argv.index('--spec')+1]).read_text())
    Path(#{Jason.encode!(observed)}).write_text(json.dumps(spec['env']))
    sys.exit(7)
    """)

    previous = System.get_env("DAEMON_RELAY_SECRET_TEST")
    System.put_env("DAEMON_RELAY_SECRET_TEST", "must-not-be-serialized")

    try do
      assert {:error, {:relay_launch_failed, 7, _}} =
               RelayPort.start(File.cwd!(), "exec cat", [{"CLAUDE_CODE_ENABLE_TELEMETRY", "1"}], relay_script: script)

      env = observed |> File.read!() |> Jason.decode!()
      refute Map.has_key?(env, "DAEMON_RELAY_SECRET_TEST")
      assert env["PATH"] == System.get_env("PATH")
      assert env["HOME"] == System.get_env("HOME")
      assert env["CLAUDE_CODE_ENABLE_TELEMETRY"] == "1"
      assert_no_launch_artifacts()
    after
      if previous, do: System.put_env("DAEMON_RELAY_SECRET_TEST", previous), else: System.delete_env("DAEMON_RELAY_SECRET_TEST")
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
