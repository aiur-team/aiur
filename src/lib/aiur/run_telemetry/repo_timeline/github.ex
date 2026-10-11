defmodule Aiur.RunTelemetry.RepoTimeline.GitHub do
  @moduledoc false
  alias Aiur.GitHub.Transport

  @query """
  query AnalyticsRepoTimeline($owner: String!, $name: String!, $branch: String!, $since: GitTimestamp, $historyCursor: String, $tagCursor: String) {
    repository(owner: $owner, name: $name) {
      ref(qualifiedName: $branch) { target { ... on Commit {
        history(first: 100, since: $since, after: $historyCursor) {
          nodes { oid committedDate message messageHeadline statusCheckRollup { state }
            associatedPullRequests(first: 1) { nodes { number headRefName title } } }
          pageInfo { hasNextPage endCursor }
        }
      } } }
      refs(refPrefix: "refs/tags/", first: 100, after: $tagCursor) {
        nodes { name target { __typename oid ... on Commit { committedDate }
          ... on Tag { target { __typename oid ... on Commit { committedDate } } } } }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """

  @spec fetch(String.t(), String.t(), String.t() | nil, keyword()) :: {:ok, [map()], [map()]} | {:error, term()}
  def fetch(repo, branch, since, opts) do
    with [owner, name] <- String.split(repo, "/"),
         {:ok, token} <- Transport.require_token(opts) do
      variables = %{"owner" => owner, "name" => name, "branch" => "refs/heads/" <> branch, "since" => since, "historyCursor" => nil, "tagCursor" => nil}
      request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

      with {:ok, commits, tags} <- pages(request, token, variables, [], [], MapSet.new()),
           {:ok, tags} <- resolve_tags(tags, request, token, variables),
           {:ok, commits} <- resolve_reverts(commits, request, token, variables) do
        {:ok, commits, tags}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_repo}
    end
  end

  defp pages(request, token, variables, commits, tags, seen) do
    with {:ok, data, _response} <- Transport.github_graphql_response(request, token, @query, variables, caller: "analytics_repo_timeline"),
         %{"nodes" => nodes, "pageInfo" => history_info} <- get_in(data, ["data", "repository", "ref", "target", "history"]),
         %{"nodes" => tag_nodes, "pageInfo" => tag_info} <- get_in(data, ["data", "repository", "refs"]) do
      next = {next_cursor(history_info), next_cursor(tag_info)}
      continue(next, request, token, variables, commits ++ nodes, tags ++ tag_nodes, seen)
    else
      {:error, reason, _response} -> {:error, reason}
      _ -> {:error, :invalid_response}
    end
  end

  defp next_cursor(%{"hasNextPage" => false}), do: nil
  defp next_cursor(%{"hasNextPage" => true, "endCursor" => cursor}) when is_binary(cursor) and cursor != "", do: cursor
  defp next_cursor(_), do: :invalid

  defp continue({nil, nil}, _request, _token, _variables, commits, tags, _seen), do: {:ok, commits, tags}

  defp continue({history, tags_cursor} = next, request, token, variables, commits, tags, seen) do
    if history == :invalid or tags_cursor == :invalid or MapSet.member?(seen, next) do
      {:error, :pagination_cycle}
    else
      # Retain a finished connection's final cursor; rereading its final page is deduped locally.
      variables = variables |> advance("historyCursor", history) |> advance("tagCursor", tags_cursor)
      pages(request, token, variables, commits, tags, MapSet.put(seen, next))
    end
  end

  @target_query """
  query AnalyticsTimelineTag($owner: String!, $name: String!, $oid: GitObjectID!) {
    repository(owner: $owner, name: $name) { object(oid: $oid) {
      ... on Tag { target { __typename oid ... on Commit { committedDate } } }
    } }
  }
  """

  defp resolve_tags(tags, request, token, variables) do
    Enum.reduce_while(tags, {:ok, []}, fn tag, {:ok, resolved} ->
      case resolve_target(tag["target"], request, token, variables, MapSet.new()) do
        {:ok, target} -> {:cont, {:ok, [%{tag | "target" => target} | resolved]}}
        error -> {:halt, error}
      end
    end)
  end

  defp resolve_target(%{"__typename" => "Tag", "target" => target}, request, token, variables, seen),
    do: resolve_target(target, request, token, variables, seen)

  defp resolve_target(%{"__typename" => "Tag", "oid" => oid}, request, token, variables, seen) do
    if MapSet.member?(seen, oid) do
      {:error, :tag_cycle}
    else
      args = Map.take(variables, ["owner", "name"]) |> Map.put("oid", oid)

      with {:ok, data, _} <- Transport.github_graphql_response(request, token, @target_query, args, caller: "analytics_repo_timeline"),
           %{} = target <- get_in(data, ["data", "repository", "object", "target"]) do
        resolve_target(target, request, token, variables, MapSet.put(seen, oid))
      else
        {:error, reason, _} -> {:error, reason}
        _ -> {:error, :invalid_tag}
      end
    end
  end

  defp resolve_target(target, _request, _token, _variables, _seen), do: {:ok, target}

  @revert_query """
  query AnalyticsTimelineRevert($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) { pullRequest(number: $number) { mergeCommit { oid } } }
  }
  """

  defp resolve_reverts(commits, request, token, variables) do
    Enum.reduce_while(commits, {:ok, []}, fn commit, {:ok, resolved} ->
      case revert_pr(commit) do
        nil -> {:cont, {:ok, [commit | resolved]}}
        number -> resolve_revert(commit, number, resolved, request, token, variables)
      end
    end)
  end

  defp revert_pr(commit) do
    headline = commit["messageHeadline"] || ""
    message = commit["message"] || ""

    if String.starts_with?(headline, "Revert \"") and not String.contains?(message, "This reverts commit ") do
      case Regex.run(~r/\(#(\d+)\)/, headline) do
        [_, number] -> String.to_integer(number)
        _ -> nil
      end
    end
  end

  defp resolve_revert(commit, number, resolved, request, token, variables) do
    args = Map.take(variables, ["owner", "name"]) |> Map.put("number", number)

    case Transport.github_graphql_response(request, token, @revert_query, args, caller: "analytics_repo_timeline") do
      {:ok, data, _} ->
        commit = Map.put(commit, "revertOid", get_in(data, ["data", "repository", "pullRequest", "mergeCommit", "oid"]))
        {:cont, {:ok, [commit | resolved]}}

      {:error, reason, _} ->
        {:halt, {:error, reason}}
    end
  end

  defp advance(variables, _key, nil), do: variables
  defp advance(variables, key, cursor), do: Map.put(variables, key, cursor)
end
