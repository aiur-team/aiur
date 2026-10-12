defmodule Aiur.RunTelemetry.WindowEventSources do
  @moduledoc false
  alias Aiur.GitHub.Transport

  @pulls """
  query ExperimentWindowPulls($query: String!, $cursor: String) {
    search(query: $query, type: ISSUE, first: 50, after: $cursor) {
      issueCount pageInfo { hasNextPage endCursor }
      nodes { ... on PullRequest { number title mergedAt url author { login }
        labels(first: 50) { nodes { name } }
        files(first: 50) { nodes { path } }
        closingIssuesReferences(first: 50) { nodes { parent { number } } pageInfo { hasNextPage } }
      } }
    }
  }
  """
  @releases """
  query ExperimentWindowReleases($owner: String!, $name: String!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      releases(first: 100, after: $cursor) { nodes { databaseId name tagName publishedAt url isDraft }
        pageInfo { hasNextPage endCursor } }
    }
  }
  """
  @tags """
  query ExperimentWindowTags($owner: String!, $name: String!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      refs(refPrefix: "refs/tags/", first: 100, after: $cursor) {
        nodes { name target { __typename ... on Commit { committedDate oid }
          ... on Tag { tagger { date } target { __typename ... on Commit { committedDate oid } } } } }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """
  @incidents """
  query ExperimentWindowIncidents($query: String!, $cursor: String) {
    search(query: $query, type: ISSUE, first: 100, after: $cursor) {
      issueCount nodes { ... on Issue { number title createdAt closedAt url labels(first: 50) { nodes { name } } } }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @spec fetch(String.t(), map(), map(), keyword()) :: {map(), [String.t()]}
  def fetch(repo, sources, range, opts) do
    with [owner, name] <- String.split(repo, "/"), {:ok, token} <- Transport.require_token(opts) do
      request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      variables = %{"owner" => owner, "name" => name}
      dates = range.start <> ".." <> range.end
      pulls = "repo:#{repo} is:pr is:merged base:#{sources["base_branch"]} merged:#{dates}"
      incidents = "repo:#{repo} is:issue created:<=#{range.end} label:" <> Enum.map_join(sources["incident_labels"], ",", &Jason.encode!/1)

      reads = [
        {"pulls", fn -> pages(request, token, @pulls, %{"query" => pulls}, ["search"]) end},
        {"releases", fn -> pages(request, token, @releases, variables, ["repository", "releases"]) end},
        {"tags", fn -> pages(request, token, @tags, variables, ["repository", "refs"]) end},
        {"incidents", fn -> if sources["incident_labels"] == [], do: {:ok, []}, else: pages(request, token, @incidents, %{"query" => incidents}, ["search"]) end},
        {"runs", fn -> runs(request, token, repo, sources["base_branch"], range) end}
      ]

      Enum.reduce(reads, {%{}, []}, &collect_source/2)
      |> then(fn {data, missing} -> {data, Enum.uniq(missing)} end)
    else
      _error -> {%{}, ["github"]}
    end
  end

  defp collect_source({source, read}, {data, missing}) do
    case read_source(read) do
      {:ok, rows} -> {Map.put(data, source, rows), missing}
      {:partial, rows} -> {Map.put(data, source, rows), ["github" | missing]}
      {:error, _reason} -> {data, ["github" | missing]}
    end
  end

  defp read_source(read) do
    read.()
  rescue
    _error -> {:error, :source_failed}
  catch
    :exit, _reason -> {:error, :source_failed}
  end

  defp pages(request, token, query, variables, path, rows \\ [], seen \\ []) do
    with {:ok, body, _response} <- Transport.github_graphql_response(request, token, query, variables, caller: "experiment_window_events"),
         %{"nodes" => nodes, "pageInfo" => info} when is_list(nodes) <- get_in(body, ["data" | path]) do
      rows = rows ++ nodes
      count = get_in(body, ["data" | path])["issueCount"] || 0
      next_page(request, token, query, variables, path, rows, seen, Map.put(info, "issueCount", count))
    else
      _error -> if rows == [], do: {:error, :github_unavailable}, else: {:partial, rows}
    end
  end

  defp next_page(request, token, query, variables, path, rows, seen, info) do
    cursor = info["endCursor"]

    cond do
      info["hasNextPage"] == false -> if info["issueCount"] > 1000, do: {:partial, rows}, else: {:ok, rows}
      length(seen) >= 9 or is_nil(cursor) or cursor in seen -> {:partial, rows}
      true -> pages(request, token, query, Map.put(variables, "cursor", cursor), path, rows, [cursor | seen])
    end
  end

  defp runs(request, token, repo, branch, range, page \\ 1, rows \\ []) do
    params = URI.encode_query(%{branch: branch, created: range.start <> ".." <> range.end, per_page: 100, page: page})
    req = %{method: :get, url: Transport.base_url() <> "/repos/#{repo}/actions/runs?" <> params, token: token, caller: "experiment_window_events"}

    case request.(req) do
      {:ok, %{status: 200, body: %{"workflow_runs" => runs, "total_count" => total}}} when is_list(runs) ->
        rows = rows ++ runs

        cond do
          length(rows) >= total -> {:ok, rows}
          page >= 10 or runs == [] -> {:partial, rows}
          true -> runs(request, token, repo, branch, range, page + 1, rows)
        end

      _error ->
        if rows == [], do: {:error, :github_unavailable}, else: {:partial, rows}
    end
  end
end
