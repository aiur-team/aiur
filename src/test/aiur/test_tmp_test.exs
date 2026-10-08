defmodule Aiur.TestTmpTest do
  use ExUnit.Case, async: true

  setup do
    base = Aiur.TestSupport.tmp_root!("test-tmp-lifecycle")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
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
end
