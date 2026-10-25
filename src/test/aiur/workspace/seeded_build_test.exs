defmodule Aiur.Workspace.SeededBuildTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.SeededBuild

  setup do
    tmp = Aiur.TestSupport.tmp_root!("seeded_build")
    File.mkdir_p!(tmp)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "drops only first-party beams that embed the seed root and touches their sources", %{tmp: tmp} do
    seed = Path.join(tmp, "seed")
    checkout = Path.join(tmp, "checkout")

    compile!(seed, "src/lib/path_sensitive.ex", "app", "defmodule SeededBuildFixture.PathSensitive do\n  def dir, do: __DIR__\nend\n")
    compile!(seed, "src/lib/plain.ex", "app", "defmodule SeededBuildFixture.Plain do\n  def dir, do: \"lib\"\nend\n")
    compile!(seed, "src/deps/dep/lib/dep.ex", "dep", "defmodule SeededBuildFixture.Dep do\n  def dir, do: __DIR__\nend\n")

    assert {_, 0} = System.cmd("cp", ["-a", seed, checkout])
    source = Path.join(checkout, "src/lib/path_sensitive.ex")
    File.touch!(source, 0)

    assert :ok = SeededBuild.invalidate_path_sensitive(seed, checkout)

    refute File.exists?(beam(checkout, "app", SeededBuildFixture.PathSensitive))
    assert File.stat!(source, time: :posix).mtime > 0
    assert File.exists?(beam(checkout, "app", SeededBuildFixture.Plain))
    assert File.exists?(beam(checkout, "dep", SeededBuildFixture.Dep))
    assert File.exists?(beam(seed, "app", SeededBuildFixture.PathSensitive))
  end

  defp compile!(root, relative, app, code) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, code)
    ebin = Path.join(root, "src/_build/test/lib/#{app}/ebin")
    File.mkdir_p!(ebin)
    {:ok, [module], _} = Kernel.ParallelCompiler.compile_to_path([path], ebin, return_diagnostics: true)
    :code.purge(module)
    :code.delete(module)
  end

  defp beam(root, app, module), do: Path.join(root, "src/_build/test/lib/#{app}/ebin/#{module}.beam")
end
