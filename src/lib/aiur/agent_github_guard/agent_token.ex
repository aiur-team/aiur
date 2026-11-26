defmodule Aiur.AgentGitHubGuard.AgentToken do
  @moduledoc false
  @spec path() :: Path.t()
  defdelegate path(), to: Aiur.GitHub.Access.WrapperToken
  @spec ensure(keyword()) :: :ok | :no_credential | {:error, term()}
  defdelegate ensure(opts \\ []), to: Aiur.GitHub.Access.WrapperToken
  @spec resolve_credential(keyword()) :: String.t() | nil
  defdelegate resolve_credential(opts), to: Aiur.GitHub.Access.WrapperToken
end
