defmodule Aiur.Experiments.StatsRunnerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Aiur.Experiments.StatsRunner

  @tools Path.expand("../../../../analytics", __DIR__)
  @fixtures Path.join(@tools, "tests/fixtures/stats/experiments")

  setup do
    root = Aiur.TestSupport.tmp_root!("stats-runner")
    File.mkdir_p!(root)
    server = start_supervised!({StatsRunner, name: :stats_runner_test})
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root, opts: [server: server, reduce_dir: @tools]}
  end

  test "real fixture writes a reproducible result", %{root: root, opts: opts} do
    for kind <- ["spec", "snapshot"], do: File.cp!(Path.join(@fixtures, "shift-#{kind}.json"), Path.join(root, "#{kind}.json"))
    assert StatsRunner.recompute(root, opts) == :ok
    assert {:ok, %{"body" => %{"experiment_id" => "shift", "engine" => %{"name" => "experiment-stats"}}}} = root |> Path.join("result.json") |> File.read!() |> Jason.decode()
    assert {"experiment result body matches\n", 0} = System.cmd(Path.join(@tools, "experiment-stats"), ["--experiment-dir", root, "--check"])
  end

  test "exit 2 maps to invalid input with diagnostics", %{root: root, opts: opts} do
    tools = tool(root, "import sys\nprint('bad snapshot', file=sys.stderr)\nsys.exit(2)")

    assert capture_log(fn ->
             assert StatsRunner.recompute(root, Keyword.put(opts, :reduce_dir, tools)) == {:error, :invalid_input}
           end) =~ "bad snapshot"
  end

  test "timeout kills the tool before returning", %{root: root, opts: opts} do
    pidfile = Path.join(root, "pid")
    tools = tool(root, "import os, time\nopen(#{inspect(pidfile)}, 'w').write(str(os.getpid()))\ntime.sleep(60)")
    assert StatsRunner.recompute(root, Keyword.merge(opts, reduce_dir: tools, timeout_ms: 1000)) == {:error, :timeout}
    pid = File.read!(pidfile)
    assert {_output, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0
  end

  test "concurrent calls run sequentially even across directories", %{root: root, opts: opts} do
    lock = Path.join(root, "lock")
    events = Path.join(root, "events")

    tools =
      tool(
        root,
        "import os, time\nos.mkdir(#{inspect(lock)})\nf = open(#{inspect(events)}, 'a')\nf.write('start\\n'); f.flush()\ntime.sleep(0.15)\nf.write('end\\n'); f.close()\nos.rmdir(#{inspect(lock)})"
      )

    opts = Keyword.put(opts, :reduce_dir, tools)
    tasks = for dir <- [root, root <> "-other"], do: Task.async(fn -> StatsRunner.recompute(dir, opts) end)
    assert Enum.map(tasks, &Task.await(&1, 5000)) == [:ok, :ok]
    assert File.read!(events) == "start\nend\nstart\nend\n"
  end

  test "missing python returns unavailable explicitly", %{root: root, opts: opts} do
    path = System.fetch_env!("PATH")
    System.put_env("PATH", root)
    on_exit(fn -> System.put_env("PATH", path) end)

    assert capture_log(fn -> assert StatsRunner.recompute(root, opts) == {:error, :unavailable} end) =~ "python3 not found"
  end

  test "unexpected exit and missing runner fail open", %{root: root, opts: opts} do
    tools = tool(root, "raise SystemExit(1)")
    assert StatsRunner.recompute(root, Keyword.put(opts, :reduce_dir, tools)) == {:error, :unavailable}
    assert StatsRunner.recompute(root, server: :absent_stats_runner) == {:error, :unavailable}
  end

  defp tool(root, body) do
    tools = Path.join(root, "tools")
    File.mkdir_p!(tools)
    script = Path.join(tools, "experiment-stats")
    File.write!(script, "#!/usr/bin/env python3\n" <> body <> "\n")
    File.chmod!(script, 0o755)
    tools
  end
end
