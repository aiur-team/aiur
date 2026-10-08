defmodule Aiur.TestTmpTest do
  use ExUnit.Case, async: true

  setup do
    base = Aiur.TestSupport.tmp_root!("test-tmp-lifecycle")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  test "startup removes stale runs and legacy workflows but preserves fresh and unrelated paths", %{base: base} do
    now = System.os_time(:second)
    stale = Path.join(base, "run-1-2-3")
    legacy = Path.join(base, "workflow-2-3")
    fresh = Path.join(base, "run-4-5-6")
    unrelated = Path.join(base, "other")

    for path <- [stale, legacy, fresh, unrelated] do
      File.mkdir!(path)
      File.write!(Path.join(path, "fixture"), "keep unless stale")
    end

    for path <- [stale, legacy, unrelated], do: File.touch!(path, now - 6 * 60 * 60 - 1)
    File.ln_s!(unrelated, Path.join(base, "run-7-8-9"))
    Aiur.TestTmp.start!(base)

    refute File.exists?(stale)
    refute File.exists?(legacy)
    assert File.read!(Path.join(fresh, "fixture")) == "keep unless stale"
    assert File.read!(Path.join(unrelated, "fixture")) == "keep unless stale"
    assert {:ok, ^unrelated} = File.read_link(Path.join(base, "run-7-8-9"))
  end

  test "sweep leaves directories belonging to another owner", %{base: base} do
    stale = Path.join(base, "run-1-2-3")
    File.mkdir!(stale)
    File.touch!(stale, 0)
    owner = File.stat!(stale).uid
    Aiur.TestTmp.sweep!(base, owner + 1, System.os_time(:second))
    assert File.dir?(stale)
  end

  test "suite completion removes the entire run directory on success and failure", %{base: base} do
    support = Path.expand("../support/test_tmp.exs", __DIR__)

    for fail? <- [false, true] do
      script = """
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
