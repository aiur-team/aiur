defmodule Aiur.GitHub.CIPollBatch do
  @moduledoc false

  require Logger

  alias Aiur.GitHub.Transport
  alias Aiur.TicketBranch

  @targets_per_query 100

  @spec fetch([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(targets, opts \\ []) when is_list(targets) do
    targets = targets |> Enum.map(&to_string/1) |> Enum.uniq()

    if targets == [] do
      {:ok, %{}}
    else
      do_fetch(targets, opts)
    end
  end

  defp do_fetch(targets, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      if length(targets) > @targets_per_query do
        Logger.warning(
          "Github CI GraphQL batch target overflow: targets=#{length(targets)} complete_pull_request_pagination=true"
        )
      end

      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      fetch_target_chunk(request_fun, token, owner, repo, targets)
    end
  end

  defp fetch_target_chunk(request_fun, token, owner, repo, targets) do
    fetch_pages(request_fun, token, owner, repo, targets, nil, [])
  end

  defp fetch_pages(request_fun, token, owner, repo, targets, cursor, pull_requests) do
    case Transport.github_graphql(request_fun, token, query(), %{"owner" => owner, "repo" => repo, "cursor" => cursor}) do
      {:ok, body} ->
        with {:ok, %{nodes: nodes, page_info: page_info}} <- parse_page(body) do
          pull_requests = pull_requests ++ Enum.map(nodes, &normalize_pull_request/1)

          if Map.get(page_info, "hasNextPage") == true do
            Logger.warning("Github CI GraphQL batch overflow: pull_requests_page=true")
            fetch_pages(request_fun, token, owner, repo, targets, Map.get(page_info, "endCursor"), pull_requests)
          else
            {:ok, match_targets(targets, pull_requests)}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query do
    """
    query AiurCIPollBatch($owner: String!, $repo: String!, $cursor: String) {
      repository(owner: $owner, name: $repo) {
        pullRequests(first: 100, states: OPEN, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            number state headRefName headRefOid baseRefName
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    contexts(first: 100) {
                      pageInfo { hasNextPage endCursor }
                      nodes {
                        __typename
                        ... on CheckRun { name status conclusion detailsUrl startedAt completedAt output { summary text } }
                        ... on StatusContext { context state targetUrl createdAt description }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    """
  end

  defp parse_page(body) do
    with %{} = pull_requests <- get_in(body, ["data", "repository", "pullRequests"]),
         nodes when is_list(nodes) <- Map.get(pull_requests, "nodes"),
         %{} = page_info <- Map.get(pull_requests, "pageInfo") do
      {:ok, %{nodes: nodes, page_info: page_info}}
    else
      _ -> {:error, :ci_poll_batch_missing}
    end
  end

  defp match_targets(targets, pull_requests) do
    Enum.reduce(targets, %{}, fn target, acc ->
      pull_request =
        Enum.find(pull_requests, fn pr -> TicketBranch.ticket_branch?(get_in(pr, [:pull_request, "head", "ref"]), target) end)

      if contexts_overflow?(pull_request) do
        Logger.warning("Github CI GraphQL batch overflow: status_contexts target=#{target}")
        acc
      else
        Map.put(acc, target, pull_request || %{pull_request: nil, check_runs: [], commit_status: empty_commit_status()})
      end
    end)
  end

  defp normalize_pull_request(node) do
    {contexts, contexts_overflow} = get_in(node, ["commits", "nodes"]) |> List.wrap() |> List.last() |> status_contexts()
    {check_runs, statuses} = Enum.split_with(contexts, &(Map.get(&1, "__typename") == "CheckRun"))

    %{
      pull_request: %{
        "number" => Map.get(node, "number"),
        "state" => String.downcase(to_string(Map.get(node, "state", "open"))),
        "head" => %{"ref" => Map.get(node, "headRefName"), "sha" => Map.get(node, "headRefOid")},
        "base" => %{"ref" => Map.get(node, "baseRefName")}
      },
      check_runs: Enum.map(check_runs, &normalize_check_run/1),
      commit_status: normalize_commit_status(statuses),
      contexts_overflow: contexts_overflow
    }
  end

  defp status_contexts(nil), do: {[], false}

  defp status_contexts(commit_node) when is_map(commit_node) do
    contexts = get_in(commit_node, ["commit", "statusCheckRollup", "contexts"]) || %{}
    {Map.get(contexts, "nodes", []), get_in(contexts, ["pageInfo", "hasNextPage"]) == true}
  end

  defp status_contexts(_commit_node), do: {[], false}

  defp normalize_check_run(check_run) do
    %{
      "name" => Map.get(check_run, "name"),
      "status" => Map.get(check_run, "status") |> to_string() |> String.downcase(),
      "conclusion" => check_run |> Map.get("conclusion") |> normalize_optional_string(),
      "started_at" => Map.get(check_run, "startedAt"),
      "completed_at" => Map.get(check_run, "completedAt"),
      "output" => Map.get(check_run, "output", %{})
    }
  end

  defp normalize_commit_status(statuses) do
    statuses =
      Enum.map(statuses, fn status ->
        %{
          "context" => Map.get(status, "context"),
          "state" => Map.get(status, "state") |> to_string() |> String.downcase(),
          "created_at" => Map.get(status, "createdAt"),
          "description" => Map.get(status, "description")
        }
      end)

    %{"statuses" => statuses, "state" => combined_state(statuses)}
  end

  defp empty_commit_status, do: %{"statuses" => [], "state" => ""}
  defp combined_state([]), do: ""

  defp combined_state(statuses) when is_list(statuses) do
    states = Enum.map(statuses, &Map.get(&1, "state"))

    cond do
      Enum.any?(states, &(&1 in ["error", "failure"])) -> "failure"
      Enum.all?(states, &(&1 == "success")) -> "success"
      true -> "pending"
    end
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: value |> to_string() |> String.downcase()

  defp contexts_overflow?(%{contexts_overflow: true}), do: true
  defp contexts_overflow?(_pull_request), do: false
end
