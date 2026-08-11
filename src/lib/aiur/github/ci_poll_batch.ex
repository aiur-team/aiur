defmodule Aiur.GitHub.CIPollBatch do
  @moduledoc false

  require Logger

  alias Aiur.GitHub.Transport
  alias Aiur.TicketBranch

  # Up to two headRefName-keyed aliases per target (the generated
  # `aiur/<id>-<slug>` branch and the legacy `aiur/<id>` one) keeps every query
  # bounded by the requested targets instead of scanning the repository's open
  # PR list, while staying at or under 100 aliases per call.
  @targets_per_query 50
  @pull_requests_per_branch 5

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
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      chunks = targets |> Enum.map(&target_entry(&1, opts)) |> Enum.chunk_every(@targets_per_query)

      if length(chunks) > 1 do
        Logger.warning("Github CI GraphQL batch alias overflow: targets=#{length(targets)} calls=#{length(chunks)}")
      end

      Enum.reduce_while(chunks, {:ok, %{}}, fn chunk, {:ok, acc} ->
        reduce_ci_chunk(request_fun, token, owner, repo, chunk, acc)
      end)
    end
  end

  defp reduce_ci_chunk(request_fun, token, owner, repo, chunk, acc) do
    case fetch_chunk(request_fun, token, owner, repo, chunk) do
      {:ok, batch} -> {:cont, {:ok, Map.merge(acc, batch)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp target_entry(target, opts) do
    case known_branch(target, opts) do
      nil -> %{target: target, branches: guessed_branches(target, opts), known_branch: false}
      branch -> %{target: target, branches: [branch], known_branch: true}
    end
  end

  # GitHub issues carry no branch name (`Issues.normalize_issue/5` sets
  # `branch_name: nil`), so without the title-derived candidate every target
  # would guess the legacy `aiur/<id>` branch, miss the real
  # `aiur/<id>-<slug>` one, and fall back to the full REST fan-out — paying a
  # GraphQL call on top of the reads this batch exists to remove.
  defp guessed_branches(target, opts) do
    title = opts |> Keyword.get(:titles_by_target, %{}) |> Map.get(target)
    legacy = TicketBranch.legacy_branch_name(target)

    case TicketBranch.branch_name(target, title) do
      ^legacy -> [legacy]
      generated -> [generated, legacy]
    end
  end

  defp known_branch(target, opts) do
    branch =
      opts |> Keyword.get(:branch_names_by_target, %{}) |> Map.get(target) ||
        opts |> Keyword.get(:open_pull_requests_by_target, %{}) |> open_pull_request_head_ref(target)

    if is_binary(branch) and branch != "", do: branch, else: nil
  end

  defp open_pull_request_head_ref(%{} = open_pull_requests, target) do
    case Map.get(open_pull_requests, target) do
      %{} = pull_request -> get_in(pull_request, ["head", "ref"])
      _other -> nil
    end
  end

  defp open_pull_request_head_ref(_open_pull_requests, _target), do: nil

  defp fetch_chunk(request_fun, token, owner, repo, entries) do
    indexed = Enum.with_index(entries)

    case Transport.github_graphql(request_fun, token, query(indexed), %{"owner" => owner, "repo" => repo}) do
      {:ok, body} ->
        case get_in(body, ["data", "repository"]) do
          %{} = repository -> {:ok, match_entries(indexed, repository)}
          _other -> {:error, :ci_poll_batch_missing}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query(indexed) do
    aliases = Enum.map_join(indexed, "\n", fn {entry, index} -> branch_aliases(entry, index) end)

    """
    query AiurCIPollBatch($owner: String!, $repo: String!) {
      rateLimit { cost }
      repository(owner: $owner, name: $repo) {
        #{aliases}
      }
    }
    """
  end

  defp branch_aliases(%{branches: branches}, index) do
    branches
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {branch, candidate} -> branch_alias(branch, index, candidate) end)
  end

  defp branch_alias(branch, index, candidate) do
    """
    branch_#{index}_#{candidate}: pullRequests(headRefName: "#{escape_graphql_string(branch)}", states: OPEN, orderBy: {field: CREATED_AT, direction: DESC}, first: #{@pull_requests_per_branch}) {
      pageInfo { hasNextPage }
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
    """
  end

  defp escape_graphql_string(value) do
    value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
  end

  defp match_entries(indexed, repository) do
    Enum.reduce(indexed, %{}, fn {entry, index}, acc ->
      case candidate_connections(entry, repository, index) do
        {:ok, connections} ->
          match_candidates(acc, entry, connections)

        :missing ->
          Logger.warning("Github CI GraphQL batch alias missing: target=#{entry.target}")
          acc
      end
    end)
  end

  defp candidate_connections(entry, repository, index) do
    connections =
      entry.branches
      |> Enum.with_index()
      |> Enum.map(fn {_branch, candidate} -> Map.get(repository, "branch_#{index}_#{candidate}") end)

    if Enum.all?(connections, &match?(%{"nodes" => nodes} when is_list(nodes), &1)),
      do: {:ok, connections},
      else: :missing
  end

  # The first candidate branch that resolves to an open PR wins. Only when no
  # candidate matched does the "no open PR" answer stand — and then only for a
  # branch orchestration actually knows.
  defp match_candidates(acc, entry, connections) do
    case Enum.find(connections, fn %{"nodes" => nodes} -> nodes != [] end) do
      nil ->
        [connection | _rest] = connections
        put_entry_result(acc, entry, [], Map.get(connection, "pageInfo") || %{})

      connection ->
        put_entry_result(acc, entry, Map.get(connection, "nodes"), Map.get(connection, "pageInfo") || %{})
    end
  end

  defp put_entry_result(acc, entry, nodes, page_info) do
    if Map.get(page_info, "hasNextPage") == true do
      # More open PRs share the head branch than one page covers; leave the
      # target to REST fallback so the truncated listing is never trusted.
      Logger.warning("Github CI GraphQL batch overflow: head_ref_pull_requests target=#{entry.target}")
      acc
    else
      put_first_pull_request(acc, entry, List.first(nodes))
    end
  end

  # The legacy `aiur/<id>` branch guess found nothing. The ticket may use a
  # suffixed branch this cycle does not know, so leave the target to REST
  # fallback rather than claiming no PR exists.
  defp put_first_pull_request(acc, %{known_branch: false}, nil), do: acc

  defp put_first_pull_request(acc, entry, nil) do
    Map.put(acc, entry.target, %{pull_request: nil, check_runs: [], commit_status: empty_commit_status()})
  end

  defp put_first_pull_request(acc, entry, node) do
    result = normalize_pull_request(node)

    if Map.get(result, :contexts_overflow) do
      Logger.warning("Github CI GraphQL batch overflow: status_contexts target=#{entry.target}")
      acc
    else
      Map.put(acc, entry.target, result)
    end
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
end
