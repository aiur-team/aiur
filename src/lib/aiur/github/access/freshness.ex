defmodule Aiur.GitHub.Access.Freshness do
  @moduledoc """
  Port answering how long a repository's cached reads can be trusted.

  A `:webhook` repository has every mutation covered by a delivery and earns the
  long read-cache TTL; `:polling` keeps the short one. Settings without a port
  answer `:polling`, the fail-safe.
  """

  @type transport :: :webhook | :polling

  @doc "The delivery transport for an `owner/repo` slug."
  @callback transport(repo :: String.t()) :: transport()

  @doc "The transport for repository-configuration reads, given the repo's `transport/1` answer."
  @callback repo_config_transport(repo :: String.t(), transport()) :: transport()
end
