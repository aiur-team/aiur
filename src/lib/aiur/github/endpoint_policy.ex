defmodule Aiur.GitHub.EndpointPolicy do
  @moduledoc """
  One enumerated table for how Aiur classifies GitHub endpoints.

  `Aiur.GitHub.Budget` (the admission ledger) and `Aiur.GitHub.Quota` (the cost
  meter) both read this single table, so an endpoint cannot be free in one
  subsystem and billable in the other — the shape that recorded every daemon
  `/rate_limit` poll as a billable Core admission while `Quota` exempted it
  from preflight and attribution (#2353).

  Each family row answers three questions at once:

    * **family** — the ledger's endpoint family (`rate_limit`, `graphql`,
      `pulls`, ...).
    * **resource** — the GitHub quota pool the call consumes (`core`,
      `graphql`, `search`), or `none` for endpoints GitHub does not meter at
      all (`/rate_limit`). A `none` resource is still admitted for ordering,
      but is never counted against a per-actor pool.
    * **billable?** — whether GitHub charges quota for the response. `false`
      means the ledger must never report the admission as spend.

  `endpoint_policy_test.exs` walks the table and fails when a family is added
  without a resource and billable decision, or when the two subsystems
  disagree about whether an endpoint is free — so the next family is added as a
  row here, not as another hand-written `case` arm.
  """

  # family -> {resource, billable?}
  @families [
    {"rate_limit", "none", false},
    {"graphql", "graphql", true},
    {"search", "search", true},
    {"pulls", "core", true},
    {"issues", "core", true},
    {"actions", "core", true},
    {"labels", "core", true},
    {"comments", "core", true},
    {"reviews", "core", true},
    {"rest", "core", true}
  ]

  @known_resources ["core", "graphql", "search", "none"]

  @doc "The enumerated family -> {resource, billable?} classification table."
  @spec families() :: [{String.t(), String.t(), boolean()}]
  def families, do: @families

  @doc "The ledger endpoint family for a request URL."
  @spec endpoint_family(String.t()) :: String.t()
  def endpoint_family(url) when is_binary(url) do
    case URI.parse(url).path do
      "/rate_limit" -> "rate_limit"
      "/graphql" -> "graphql"
      "/repos/" <> path -> path |> String.split("/", trim: true) |> Enum.at(2, "rest")
      _path -> "rest"
    end
  end

  def endpoint_family(_url), do: "rest"

  @doc "The GitHub quota pool a request URL consumes (`core`, `graphql`, `search`, or `none`)."
  @spec resource(String.t()) :: String.t()
  def resource(url), do: url |> endpoint_family() |> resource_for()

  @doc "Whether GitHub charges quota for a request URL's response."
  @spec billable?(String.t()) :: boolean()
  def billable?(url), do: url |> endpoint_family() |> billable_for()

  @doc "The shared free-endpoint predicate: GitHub charges no quota for this request."
  @spec free_endpoint?(String.t()) :: boolean()
  def free_endpoint?(url), do: not billable?(url)

  @doc "The quota pool for a ledger family, from the table."
  @spec resource_for(String.t()) :: String.t()
  def resource_for(family) when is_binary(family) do
    case Enum.find(@families, fn {f, _, _} -> f == family end) do
      {_, resource, _} -> resource
      _unknown -> "core"
    end
  end

  @doc "The billable decision for a ledger family, from the table."
  @spec billable_for(String.t()) :: boolean()
  def billable_for(family) when is_binary(family) do
    case Enum.find(@families, fn {f, _, _} -> f == family end) do
      {_, _, billable} -> billable
      _unknown -> true
    end
  end

  @doc false
  @spec known_resources() :: [String.t()]
  def known_resources, do: @known_resources
end
