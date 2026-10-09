defmodule Aiur.BuildGateAnalysisTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.{AgentBuildGuard, BuildGate}

  setup do
    root = Path.join(System.tmp_dir!(), "analysis-gate-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    :ok = AgentBuildGuard.install(root)

    write_command(bin, "mix", ~s(printf 'ran:%s\\n' "$*"; if [ -n "${AIUR_BUILD_GATE_LEASE_PATH:-}" ]; then cat "$AIUR_BUILD_GATE_LEASE_PATH"; fi; exit 7))
    write_command(bin, "elixir", ~s(shift 2; exec "#{bin}/mix" "$@"))
    write_command(bin, "mise", ~s|shift; case "$1" in --) shift; exec "$@";; --command=*) eval "${1#--command=}";; *) shift; eval "$1";; esac|)

    env =
      BuildGate.shell_env(
        gate_dir: root,
        slots: 1,
        stagger_seconds: 0,
        min_free_memory_mb: 0,
        max_hold_seconds: 30,
        retain_seconds: 0
      ) ++
        [
          {"AIUR_BUILD_GATE_BIN", AgentBuildGuard.bin_dir(root)},
          {"AIUR_BUILD_GATE_LEASE_PATH", ""},
          {"AIUR_BUILD_GATE_LEASE_TOKEN", ""},
          {"PATH", "#{AgentBuildGuard.bin_dir(root)}:#{bin}:#{System.get_env("PATH")}"}
        ]

    on_exit(fn ->
      File.rm_rf!(root)
      File.chmod(BuildGate.lock_dir(root), 0o755)
      File.rm_rf!(BuildGate.lock_dir(root))
    end)

    %{root: root, bin: bin, env: env}
  end

  test "static analysis acquires leases through shell and PATH entrypoints", %{env: env} do
    for task <- ~w(lint credo dialyzer),
        command <- [
          "mix #{task}",
          "mix do format + #{task}",
          "mix do format, #{task}",
          "elixir -S mix #{task}",
          "mise exec -- mix #{task}",
          "mise exec -c 'mix #{task}'",
          "mise exec --command='mix #{task}'"
        ],
        shell <- ~w(bash sh) do
      assert {output, 7} = System.cmd(shell, ["-c", command], env: env, stderr_to_stdout: true)
      assert output =~ "phase=#{task}", "#{shell}: #{command}\n#{output}"
      assert output =~ "ran:"
      assert length(Regex.scan(~r/aiur_build_gate acquired slot=/, output)) == 1
    end
  end

  # Future-regression guard: cheap commands already bypass admission on main.
  test "cheap Mix tasks bypass admission", %{env: env} do
    assert {output, 7} = System.cmd("sh", ["-c", "mix format"], env: env, stderr_to_stdout: true)
    assert output =~ "ran:format"
    refute output =~ "aiur_build_gate acquired"
  end

  test "review wrapper publishes a live holder and preserves failure", %{root: root, bin: bin, env: env} do
    fifo = Path.join(root, "release")
    assert {"", 0} = System.cmd("mkfifo", [fifo])
    release = File.open!(fifo, [:read, :write])
    write_command(bin, "review-work", ~s(printf 'ready\\n'; read -r release < "#{fifo}"; exit 7))
    script = Path.expand("../../../scripts/build-gate", __DIR__)

    port =
      Port.open({:spawn_executable, String.to_charlist(script)}, [
        :binary,
        :exit_status,
        line: 1_024,
        args: [~c"review-work", ~c"review-work"],
        env: Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
      ])

    try do
      receive_barrier({^port, message})
      assert message == {:data, {:eol, "ready"}}

      assert %{active: 1, holders: [%{phase: "review", command: command}]} =
               BuildGate.status(gate_dir: root, capacity: 1, stagger_seconds: 0, min_free_memory_mb: 0, max_hold_seconds: 30, retain_seconds: 0)

      assert command =~ "review-work"
    after
      IO.write(release, "release\n")
      File.close(release)
    end

    receive_barrier({^port, {:exit_status, 7}})
    assert %{active: 0} = BuildGate.status(gate_dir: root, capacity: 1, stagger_seconds: 0, min_free_memory_mb: 0, max_hold_seconds: 30, retain_seconds: 0)
  end

  defp write_command(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
  end
end
