defmodule Aiur.GitHub.RouteShape do
  @moduledoc """
  Maps a GitHub request URL onto a small, closed vocabulary of route shapes.

  `log_shape/1` is a **closed-vocabulary allowlist** for the durable request
  log. It matches a URL against a fixed set of known templates and returns a
  constant for anything unrecognised. Written that way, **no input byte can
  reach the output** — the result is always a member of the small finite set
  `known_shapes/0` — which is provable by construction. An escaping or
  redaction approach gives no such guarantee, and this log will contain URLs
  from a credentialed client (a query string can carry a token), so a later
  "simplification" back to sanitising or echoing path segments would be a
  security regression, not a cleanup.
  """

  # The unrecognised constant: any URL that matches no known template collapses
  # here, so the output vocabulary stays finite.
  @unrecognised "other"

  # Ordered most-specific first: the first pattern that matches wins, so a
  # numbered read is a different shape from the collection that contains it.
  # Every value is a fixed literal — the URL's own bytes never appear in it.
  @shapes [
    {~r{^/repos/[^/]+/[^/]+/issues/\d+/timeline}, "issue_timeline"},
    {~r{^/repos/[^/]+/[^/]+/issues/\d+/comments}, "issue_comments"},
    {~r{^/repos/[^/]+/[^/]+/issues/\d+$}, "issue"},
    {~r{^/repos/[^/]+/[^/]+/issues/comments}, "comment_stream"},
    {~r{^/repos/[^/]+/[^/]+/issues}, "issues"},
    {~r{^/repos/[^/]+/[^/]+/pulls/\d+/files}, "pull_files"},
    {~r{^/repos/[^/]+/[^/]+/pulls/\d+/comments}, "pull_comments"},
    {~r{^/repos/[^/]+/[^/]+/pulls/\d+$}, "pull"},
    {~r{^/repos/[^/]+/[^/]+/pulls/comments}, "comment_stream"},
    {~r{^/repos/[^/]+/[^/]+/pulls}, "pulls"},
    {~r{^/repos/[^/]+/[^/]+/events}, "repo_events"},
    {~r{^/repos/[^/]+/[^/]+/branches/[^/]+/protection}, "branch_protection"},
    {~r{^/repos/[^/]+/[^/]+/branches}, "branches"},
    {~r{^/repos/[^/]+/[^/]+/contents/}, "contents"},
    {~r{^/repos/[^/]+/[^/]+/actions/workflows}, "actions_workflows"},
    {~r{^/repos/[^/]+/[^/]+/rulesets}, "rulesets"},
    {~r{^/repos/[^/]+/[^/]+$}, "repo"},
    # Any other path under `/repos/` the daemon does not yet name — still a
    # constant, never the URL.
    {~r{^/repos/}, "repos_other"},
    {~r{^/orgs/}, "orgs"},
    {~r{^/graphql$}, "graphql"},
    {~r{^/rate_limit$}, "rate_limit"},
    {~r{^/user$}, "user"}
  ]

  @doc """
  The finite output vocabulary of `log_shape/1`, for tests and for the moduledoc
  claim that the set is closed.
  """
  @spec known_shapes() :: [String.t()]
  def known_shapes do
    @shapes |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort() |> Kernel.++([@unrecognised])
  end

  @doc """
  The closed-vocabulary route shape for a request or URL.

  Accepts either a request map (`%{url: url}`) or a bare URL string. The result
  is always a member of `known_shapes/0`; for any URL matching no known
  template it is `"other"`. No input byte can appear in the result.
  """
  @spec log_shape(map() | String.t()) :: String.t()
  def log_shape(%{url: url}) when is_binary(url), do: log_shape(url)

  def log_shape(url) when is_binary(url) do
    path = url |> URI.parse() |> Map.get(:path) |> Kernel.||("/")

    Enum.find_value(@shapes, @unrecognised, fn {pattern, shape} ->
      if Regex.match?(pattern, path), do: shape
    end)
  rescue
    _unparsable -> @unrecognised
  end

  def log_shape(_other), do: @unrecognised
end
