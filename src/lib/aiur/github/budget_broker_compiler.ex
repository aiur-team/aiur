defmodule Mix.Tasks.Compile.GithubBudget do
  use Mix.Task.Compiler

  alias Aiur.GitHub.BudgetBrokerSource

  @moduledoc "Assembles the embedded broker into priv for development and releases."

  @impl Mix.Task.Compiler
  def run(_args) do
    BudgetBrokerSource.install!(Path.join(Mix.Project.app_path(), "priv"))
    {:ok, []}
  end
end
