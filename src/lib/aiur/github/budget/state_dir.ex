defmodule Aiur.GitHub.Budget.StateDir do
  @moduledoc false

  @spec resolve(keyword()) :: Path.t()
  def resolve(opts) do
    case System.get_env("AIUR_DEV_TEST_TICKET_IDS") do
      scope when is_binary(scope) ->
        sandbox_budget_dir(scope)

      _ ->
        configured = Keyword.get(opts, :state_dir) || Application.get_env(:aiur, :github_budget_dir)
        if nonblank?(configured), do: Path.expand(configured), else: Path.join(System.user_home!(), ".aiur/github-budget")
    end
  end

  defp sandbox_budget_dir(_scope) do
    case System.get_env("AIUR_GITHUB_BUDGET_DIR") do
      path when is_binary(path) and path != "" ->
        Path.expand(path)

      _ ->
        raise ArgumentError, "AIUR_GITHUB_BUDGET_DIR must name a per-launch sandbox budget directory"
    end
  end

  defp nonblank?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank?(_value), do: false
end
