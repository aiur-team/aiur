defmodule Aiur.RunTelemetry.EpicMembers do
  @moduledoc false
  alias Aiur.GitHub.{Errors, ResourceStore, Transport}

  @merges """
  query FeatureMemberMerge($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) { issue(number: $number) {
      closedByPullRequestsReferences(first: 100, includeClosedPrs: true) {
        nodes { mergedAt mergeCommit { oid } }
        pageInfo { hasNextPage }
      }
    } }
  }
  """

  @spec read(String.t(), integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(repo, number, opts) do
    repo = String.downcase(repo)

    with {:ok, rows} <- get(repo, "/issues/#{number}/sub_issues?per_page=100", Keyword.put(opts, :first_page?, true)),
         opts = Keyword.put(opts, :recent_merges, recent(opts)),
         {members, foreign} <- Enum.split_with(rows, &(String.downcase(&1["repository_url"] || "https://api.github.com/repos/#{repo}") == String.downcase("https://api.github.com/repos/#{repo}"))),
         {:ok, merges} <- merges(repo, members, opts) do
      {:ok,
       %{
         "members" => Enum.map(members, &Map.take(&1, ~w(number state state_reason closed_at))),
         "merges" => merges,
         "member_limit" => length(rows) >= 100,
         "cross_repo_excluded" => Enum.map(foreign, & &1["html_url"])
       }}
    end
  end

  @spec held(String.t(), integer()) :: [integer()]
  def held(repo, number) do
    [owner, name] = String.split(repo, "/")
    for {_key, %{data: %{"present" => true, "parent_issue_number" => ^number, "sub_issue_number" => member}}} <- ResourceStore.list(:sub_issue, owner, name), do: member
  end

  @spec get(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def get(repo, suffix, opts) do
    with {:ok, token} <- Transport.require_token(opts) do
      request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = Transport.base_url() <> "/repos/" <> repo <> suffix
      if opts[:first_page?], do: first_page(request, token, url), else: Transport.fetch_json_list(request, token, url, caller: :experiments_auto)
    end
  end

  # Membership deliberately supports the first 100, unlike complete label discovery.
  defp first_page(request, token, url) do
    case request.(%{method: :get, url: url, token: token, caller: "experiments_auto"}) do
      {:ok, %{status: 200, body: rows}} when is_list(rows) -> {:ok, Enum.take(rows, 100)}
      {:ok, response} -> {:error, Errors.github_status_error(response)}
      {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp merges(repo, rows, opts) do
    rows
    |> Enum.reject(&(&1["state_reason"] == "not_planned"))
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case merge(repo, row, opts) do
        {:ok, facts} -> {:cont, {:ok, acc ++ facts}}
        error -> {:halt, error}
      end
    end)
  end

  defp merge(repo, row, opts) do
    recent = Keyword.fetch!(opts, :recent_merges)
    known = Enum.filter(recent, &(&1.repository == repo and &1.ticket_id == to_string(row["number"])))

    cond do
      known != [] -> {:ok, Enum.map(known, &%{"number" => row["number"], "at" => DateTime.to_iso8601(&1.merged_at), "sha" => &1.merge_commit_sha})}
      row["state"] == "closed" -> linked(repo, row["number"], opts)
      true -> {:ok, []}
    end
  end

  defp recent(opts) do
    source = Keyword.get(opts, :recent_merges, [])
    if is_function(source, 0), do: source.(), else: source
  end

  defp linked(repo, number, opts) do
    [owner, name] = String.split(repo, "/")
    request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

    with {:ok, token} <- Transport.require_token(opts),
         {:ok, data, _response} <- Transport.github_graphql_response(request, token, @merges, %{"owner" => owner, "name" => name, "number" => number}, caller: :experiments_auto),
         %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}} <- get_in(data, ["data", "repository", "issue", "closedByPullRequestsReferences"]) do
      facts = for fact <- nodes, is_binary(fact["mergedAt"]), do: %{"number" => number, "at" => fact["mergedAt"], "sha" => get_in(fact, ["mergeCommit", "oid"])}
      {:ok, facts}
    else
      {:error, reason, _response} -> {:error, reason}
      {:error, _reason} = error -> error
      _incomplete -> {:error, :incomplete_member_merge}
    end
  end
end
