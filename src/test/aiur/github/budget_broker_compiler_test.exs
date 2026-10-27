defmodule Aiur.GitHub.BudgetBrokerCompilerTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.BudgetBrokerSource

  alias Mix.Tasks.Compile.GithubBudget

  @moduletag :tmp_dir

  test "configured compiler assembles missing release artifact and repairs stale bytes", %{tmp_dir: root} do
    compilers = Mix.Project.config()[:compilers]
    assert List.last(compilers) == :github_budget

    File.write!(Path.join(root, "mix.exs"), """
    defmodule BrokerAssemblyFixture.MixProject do
      use Mix.Project
      def project, do: [app: :broker_assembly_fixture, version: "0.0.0", compilers: [:github_budget]]
    end
    """)

    Mix.Project.in_project(:broker_assembly_fixture, root, fn _ ->
      path = Path.join([Mix.Project.app_path(), "priv", "github_budget.py"])
      refute File.exists?(path)
      assert {:ok, []} = GithubBudget.run([])
      assert File.read!(path) == BudgetBrokerSource.text()
      File.write!(path, "stale")
      assert {:ok, []} = GithubBudget.run([])
      assert File.read!(path) == BudgetBrokerSource.text()
    end)
  end
end
