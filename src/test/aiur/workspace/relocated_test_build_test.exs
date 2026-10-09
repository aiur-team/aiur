defmodule Aiur.Workspace.RelocatedTestBuildTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "copied test build recompiles changed sources while retaining unchanged beams", %{tmp_dir: root} do
    base = Path.join(root, "base")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(Path.join(base, "lib"))
    options = Keyword.get(Mix.Project.config(), :elixirc_options, [])

    File.write!(Path.join(base, "mix.exs"), """
    defmodule WarmFixture.MixProject do
      use Mix.Project
      def project, do: [app: :warm_fixture, version: "0.1.0", elixirc_options: #{inspect(options)}]
    end
    """)

    File.write!(Path.join(base, "lib/changed.ex"), "defmodule WarmFixture.Changed do\n def value, do: 1\nend\n")
    File.write!(Path.join(base, "lib/unchanged.ex"), "defmodule WarmFixture.Unchanged do\n def value, do: 42\nend\n")
    env = [{"MIX_ENV", "test"}]
    {output, status} = System.cmd("mix", ["compile"], cd: base, env: env, stderr_to_stdout: true)
    assert status == 0, output
    beam = "_build/test/lib/warm_fixture/ebin/Elixir.WarmFixture.Unchanged.beam"
    unchanged = File.read!(Path.join(base, beam))
    {_, 0} = System.cmd("cp", ["-a", Path.join(base, "."), workspace])
    File.write!(Path.join(workspace, "lib/changed.ex"), "defmodule WarmFixture.Changed do\n def value, do: 200\nend\n")

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", "IO.inspect({WarmFixture.Changed.value(), WarmFixture.Unchanged.value()})"],
        cd: workspace,
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "{200, 42}"
    assert output =~ "Compiling 1 file (.ex)"
    assert File.read!(Path.join(workspace, beam)) == unchanged
  end
end
