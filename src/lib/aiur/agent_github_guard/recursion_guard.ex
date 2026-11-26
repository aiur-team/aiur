defmodule Aiur.AgentGitHubGuard.RecursionGuard do
  @moduledoc false
  @spec splice(String.t(), String.t()) :: String.t()
  defdelegate splice(script, tool), to: Aiur.GitHub.Access.WrapperRecursion
end
