defmodule Aiur.TestTmpTest do
  use ExUnit.Case, async: true

  setup do
    base = Aiur.TestSupport.tmp_root!("test-tmp-lifecycle")
    File.mkdir_p!(base)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(base) end)
    %{base: base}
  end

  test "startup removes dead runs immediately but preserves live runs regardless of age", %{base: base} do
    now = System.os_time(:second)
    {output, 0} = System.cmd("sh", ["-c", "echo $$"])
    dead_pid = output |> String.trim() |> String.to_integer()
    refute Aiur.ProcessIdentity.alive?(dead_pid)
    stale = Path.join(base, "run-1-#{dead_pid}-3")
    legacy = Path.join(base, "workflow-#{dead_pid}-3")
    fresh = Path.join(base, "run-4-#{System.pid()}-6")
    old_live = Path.join(base, "workflow-#{System.pid()}-7")
    unrelated = Path.join(base, "other")

    for path <- [stale, legacy, fresh, old_live, unrelated] do
      File.mkdir!(path)
      File.write!(Path.join(path, "fixture"), "keep unless stale")
    end

    for path <- [stale, old_live, unrelated], do: File.touch!(path, now - 7 * 60 * 60)
    File.ln_s!(unrelated, Path.join(base, "run-7-#{dead_pid}-9"))
    Aiur.TestTmp.start!(base)

    refute File.exists?(stale)
    refute File.exists?(legacy)
    assert File.read!(Path.join(fresh, "fixture")) == "keep unless stale"
    assert File.read!(Path.join(old_live, "fixture")) == "keep unless stale"
    assert File.read!(Path.join(unrelated, "fixture")) == "keep unless stale"
    assert {:ok, ^unrelated} = File.read_link(Path.join(base, "run-7-#{dead_pid}-9"))
  end

  test "sweep removes a dead run holding read-only hook snapshot directories", %{base: base} do
    {output, 0} = System.cmd("sh", ["-c", "echo $$"])
    dead_pid = output |> String.trim() |> String.to_integer()
    refute Aiur.ProcessIdentity.alive?(dead_pid)
    stale = Path.join(base, "run-1-#{dead_pid}-3")
    snapshot = Path.join([stale, "hooks", "snapshot"])
    File.mkdir_p!(snapshot)
    File.write!(Path.join(snapshot, "hook"), "read-only")
    File.chmod!(snapshot, 0o555)
    File.chmod!(Path.join(stale, "hooks"), 0o555)
    Aiur.TestTmp.sweep!(base, File.stat!(stale).uid)
    refute File.exists?(stale)
  end

  test "sweep keeps a run when its process liveness probe times out", %{base: base} do
    {output, 0} = System.cmd("sh", ["-c", "echo $$"])
    pid = output |> String.trim() |> String.to_integer()
    stale = Path.join(base, "run-1-#{pid}-3")
    File.mkdir!(stale)
    test_pid = self()

    blocking_probe = fn probed_pid ->
      send(test_pid, {:liveness_probe_started, probed_pid})

      receive do
        :release -> false
      end
    end

    probe_key = {Aiur.TestTmp, :alive_probe}
    previous_probe = Process.put(probe_key, blocking_probe)

    warning =
      try do
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Aiur.TestTmp.sweep!(base, File.stat!(stale).uid)
        end)
      after
        if previous_probe, do: Process.put(probe_key, previous_probe), else: Process.delete(probe_key)
      end

    assert_receive {:liveness_probe_started, ^pid}, 1_000
    assert warning =~ "liveness probe timed out"
    assert File.dir?(stale)
  end

  test "sweep warns and continues past a dead run it cannot remove", %{base: base} do
    {output, 0} = System.cmd("sh", ["-c", "echo $$"])
    dead_pid = output |> String.trim() |> String.to_integer()
    refute Aiur.ProcessIdentity.alive?(dead_pid)
    stuck = Path.join(base, "run-1-#{dead_pid}-3")
    stale = Path.join(base, "run-2-#{dead_pid}-4")
    for path <- [stuck, stale], do: File.mkdir!(path)

    rm = fn
      ^stuck -> {:error, :eacces, Path.join(stuck, "foreign")}
      path -> File.rm_rf(path)
    end

    warning = ExUnit.CaptureIO.capture_io(:stderr, fn -> Aiur.TestTmp.sweep!(base, File.stat!(stuck).uid, rm) end)
    assert warning =~ stuck
    assert warning =~ "permission denied"
    assert File.dir?(stuck)
    refute File.exists?(stale)
  end

  test "sweep leaves directories belonging to another owner", %{base: base} do
    {output, 0} = System.cmd("sh", ["-c", "echo $$"])
    dead_pid = output |> String.trim() |> String.to_integer()
    refute Aiur.ProcessIdentity.alive?(dead_pid)
    stale = Path.join(base, "run-1-#{dead_pid}-3")
    File.mkdir!(stale)
    File.touch!(stale, 0)
    owner = File.stat!(stale).uid
    Aiur.TestTmp.sweep!(base, owner + 1)
    assert File.dir?(stale)
  end

  test "suite completion removes the entire run directory on success and failure", %{base: base} do
    support = Path.expand("../support/test_tmp.exs", __DIR__)
    process_identity = Path.expand("../../lib/aiur/process_identity.ex", __DIR__)

    for fail? <- [false, true] do
      script = """
      Code.require_file(#{inspect(process_identity)})
      Code.require_file(#{inspect(support)})
      ExUnit.start()
      root = Aiur.TestTmp.start!(#{inspect(base)})
      File.write!(Path.join(root, "late-fixture"), "leftover")
      IO.puts("RUN_ROOT=" <> root)
      defmodule LifecycleProbe do
        use ExUnit.Case
        test "completion", do: assert(#{inspect(!fail?)})
      end
      """

      {output, status} = System.cmd("elixir", ["--erl", "+S 2:2", "-e", script], stderr_to_stdout: true)
      assert status == if(fail?, do: 2, else: 0), output
      [_, root] = Regex.run(~r/RUN_ROOT=(.+)/, output)
      refute File.exists?(root)
    end
  end

  test "repeat-until-failure keeps the run root until the last round", %{base: base} do
    support = Path.expand("../support/test_tmp.exs", __DIR__)
    process_identity = Path.expand("../../lib/aiur/process_identity.ex", __DIR__)

    script = """
    Code.require_file(#{inspect(process_identity)})
    Code.require_file(#{inspect(support)})
    ExUnit.start(repeat_until_failure: 2)
    root = Aiur.TestTmp.start!(#{inspect(base)})
    IO.puts("RUN_ROOT=" <> root)
    Application.put_env(:repeat_probe, :root, root)
    defmodule RepeatProbe do
      use ExUnit.Case
      test "root survives earlier rounds", do: assert(File.dir?(Application.fetch_env!(:repeat_probe, :root)))
    end
    """

    {output, status} = System.cmd("elixir", ["--erl", "+S 2:2", "-e", script], stderr_to_stdout: true)
    assert status == 0, output
    assert length(Regex.scan(~r/1 test, 0 failures/, output)) == 3, output
    [_, root] = Regex.run(~r/RUN_ROOT=(.+)/, output)
    refute File.exists?(root)
  end

  test "a late writer at suite end leaves the run root but the green suite still exits 0", %{base: base} do
    support = Path.expand("../support/test_tmp.exs", __DIR__)
    process_identity = Path.expand("../../lib/aiur/process_identity.ex", __DIR__)

    script = """
    Code.require_file(#{inspect(process_identity)})
    Code.require_file(#{inspect(support)})
    ExUnit.start()
    root = Aiur.TestTmp.start!(#{inspect(base)})
    IO.puts("RUN_ROOT=" <> root)
    spawn(fn ->
      Stream.repeatedly(fn ->
        File.mkdir_p(root)
        File.write(Path.join(root, "late-\#{System.unique_integer([:positive])}"), "x")
      end)
      |> Stream.run()
    end)
    defmodule LateWriterProbe do
      use ExUnit.Case
      test "completion", do: assert(true)
    end
    """

    {output, status} = System.cmd("elixir", ["--erl", "+S 2:2", "-e", script], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "1 test, 0 failures"
    refute output =~ "File.Error"
  end

  test "suite-end removal names the late writer even when a retry succeeds, and never raises", %{base: base} do
    root = Path.join(base, "run-root")
    File.mkdir_p!(Path.join(root, "late"))
    File.write!(Path.join([root, "late", "writer.log"]), "x")
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    flaky = fn path ->
      case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
        0 -> {:error, :eexist, Path.join(path, "late")}
        _ -> File.rm_rf(path)
      end
    end

    stderr = ExUnit.CaptureIO.capture_io(:stderr, fn -> assert :ok = Aiur.TestTmp.remove_run_root(root, flaky, 3) end)
    refute File.exists?(root)
    assert Agent.get(attempts, & &1) == 2
    assert stderr =~ ":eexist at #{root}/late"
    assert stderr =~ "late/writer.log"
    refute stderr =~ "left test run root"

    File.mkdir_p!(Path.join(root, "late"))
    File.write!(Path.join([root, "late", "writer.log"]), "x")

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert :ok = Aiur.TestTmp.remove_run_root(root, fn path -> {:error, :eexist, path} end, 2)
      end)

    assert stderr =~ "left test run root #{root}"
    assert stderr =~ "late/writer.log"
    assert File.dir?(root)
  end
end
