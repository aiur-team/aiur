defmodule Aiur.GitHub.IssueDependencies do
  @moduledoc """
  Domain module for declaring/removing GitHub native issue dependencies
  with client-side cycle detection.

  ## Why a separate module

  `Aiur.Codex.DynamicTool` stays thin: the `aiur_declare_blocker` and
  `aiur_unblock` tools become 5-line shims that delegate here, the same
  way `execute_linear_graphql/2` delegates to `Aiur.Linear.Client.graphql/3`.

  ## Cycle detection

  GitHub returns 422 if you try to create a dependency that forms a
  cycle, but that's an opaque error from the agent's perspective and
  also wastes an API call. We BFS the existing dependency graph from
  the proposed blocker; if the search reaches `current_issue_number`,
  return `{:error, :cycle_detected}` before posting.

  BFS bounds:
    * Visited-set prevents revisiting nodes (one membership lookup per
      enqueue is the cheap way to keep complexity O(V+E) instead of
      O(V*E))
    * 100-hop depth bound — sane upper limit
    * GraphQL frontier batches — up to 100 issues per request, with
      connection pagination so wide dependency sets remain complete

  If GitHub cannot provide a complete graph, return
  `{:error, :cycle_check_inconclusive}` rather than POST optimistically —
  letting the agent know the check was inconclusive is the right call.
  """

  require Logger

  alias Aiur.GitHub.{Client, Transport}

  @max_depth 100
  @graph_frontier_size 100

  @doc """
  Declares `blocker_number` as blocking `current_number`. Resolves the
  blocker's numeric id, runs a cycle pre-check via BFS, then POSTs via
  the GitHub native Issue Dependencies REST API.

  Returns:

    * `{:ok, blocker_issue_map}` on success
    * `{:ok, :already_present}` if the blocker is already declared (idempotent)
    * `{:error, :blocker_not_found}` — fetch returns 404
    * `{:error, :cycle_detected}` — BFS pre-check found a cycle
    * `{:error, :rate_limited}` — BFS budget exhausted
    * `{:error, :permission_denied}` — token lacks Issues:write (403)
    * `{:error, {:github, :http, %{status: n}}}` — other HTTP failures
  """
  @spec declare(integer() | String.t(), integer() | String.t(), keyword()) ::
          {:ok, map() | :already_present} | {:error, term()}
  def declare(current_number, blocker_number, opts \\ []) do
    client_opts = Keyword.take(opts, [:request_fun, :graph_request_fun])

    with {:ok, blocker_issue} <- fetch_blocker(blocker_number, client_opts),
         blocker_id when is_integer(blocker_id) <- Map.get(blocker_issue, "id"),
         :ok <- check_not_already_present(current_number, blocker_id, client_opts),
         :ok <- cycle_check(current_number, blocker_number, client_opts),
         {:ok, result} <- post_dependency(current_number, blocker_id, client_opts) do
      {:ok, result}
    else
      :already_present -> {:ok, :already_present}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  @doc """
  Removes `blocker_number` from `current_number`'s blocked-by list.
  """
  @spec unblock(integer() | String.t(), integer() | String.t(), keyword()) ::
          {:ok, :removed | :not_present} | {:error, term()}
  def unblock(current_number, blocker_number, opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun)
    client_opts = if request_fun, do: [request_fun: request_fun], else: []

    with {:ok, blocker_issue} <- fetch_blocker(blocker_number, client_opts),
         blocker_id when is_integer(blocker_id) <- Map.get(blocker_issue, "id") do
      case Client.remove_dependency(current_number, blocker_id, client_opts) do
        {:ok, :removed} -> verify_unblocked(current_number, blocker_id, :removed, client_opts)
        {:error, reason} -> unblock_error(reason, current_number, blocker_id, client_opts)
      end
    end
  end

  @doc "Checks the authoritative GitHub dependency state."
  @spec declared?(integer() | String.t(), integer() | String.t(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def declared?(current_number, blocker_number, opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun)
    client_opts = if request_fun, do: [request_fun: request_fun], else: []

    with {:ok, blocker_issue} <- fetch_blocker(blocker_number, client_opts),
         blocker_id when is_integer(blocker_id) <- Map.get(blocker_issue, "id"),
         {:ok, dependencies} <- Client.fetch_blocked_by(current_number, client_opts) do
      {:ok, Enum.any?(dependencies, &(Map.get(&1, "id") == blocker_id))}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  defp fetch_blocker(blocker_number, client_opts) do
    case Client.fetch_issue_raw(blocker_number, client_opts) do
      {:ok, issue} -> {:ok, issue}
      {:error, reason} -> fetch_blocker_error(reason)
    end
  end

  defp fetch_blocker_error(reason) do
    if github_status?(reason, 404), do: {:error, :blocker_not_found}, else: {:error, reason}
  end

  defp check_not_already_present(current_number, blocker_id, client_opts) do
    case Client.fetch_blocked_by(current_number, client_opts) do
      {:ok, existing} -> presence_for(existing, blocker_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp presence_for(existing, blocker_id) do
    if Enum.any?(existing, &(Map.get(&1, "id") == blocker_id)),
      do: :already_present,
      else: :ok
  end

  defp post_dependency(current_number, blocker_id, client_opts) do
    case Client.add_dependency(current_number, blocker_id, client_opts) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> post_dependency_error(reason)
    end
  end

  defp post_dependency_error(reason) do
    cond do
      github_rate_limited?(reason) -> {:error, :rate_limited}
      github_http_status?(reason, 403) -> {:error, :permission_denied}
      github_http_status?(reason, 422) -> {:error, :cycle_detected}
      true -> {:error, reason}
    end
  end

  defp unblock_error(reason, current_number, blocker_id, client_opts) do
    cond do
      github_rate_limited?(reason) -> {:error, :rate_limited}
      github_http_status?(reason, 404) -> verify_unblocked(current_number, blocker_id, :not_present, client_opts)
      github_http_status?(reason, 403) -> {:error, :permission_denied}
      true -> {:error, reason}
    end
  end

  defp verify_unblocked(current_number, blocker_id, result, client_opts) do
    case Client.fetch_blocked_by(current_number, client_opts) do
      {:ok, dependencies} ->
        if Enum.any?(dependencies, &(Map.get(&1, "id") == blocker_id)),
          do: {:error, :dependency_still_present},
          else: {:ok, result}

      {:error, reason} ->
        {:error, {:postcondition_check_failed, reason}}
    end
  end

  defp cycle_check(current_number, blocker_number, client_opts) do
    state = %{
      current: to_string(current_number),
      visited: MapSet.new()
    }

    queue = [{to_string(blocker_number), 0}]

    cond do
      Keyword.has_key?(client_opts, :graph_request_fun) -> graph_bfs(queue, state, client_opts)
      Keyword.has_key?(client_opts, :request_fun) -> rest_bfs(queue, Map.put(state, :api_calls, 0), client_opts)
      true -> graph_bfs(queue, state, client_opts)
    end
  end

  # The request-function seam deliberately keeps the REST traversal available
  # for deterministic unit tests and callers that provide a REST-only adapter.
  # Production calls use the GraphQL frontier batch above.
  defp rest_bfs([], _state, _opts), do: :ok
  defp rest_bfs(_queue, %{api_calls: calls}, _opts) when calls >= 200, do: {:error, :rate_limited}
  defp rest_bfs([{_node, depth} | rest], state, opts) when depth > @max_depth, do: rest_bfs(rest, state, opts)

  defp rest_bfs([{node, depth} | rest], state, opts) do
    cond do
      node == state.current ->
        {:error, :cycle_detected}

      MapSet.member?(state.visited, node) ->
        rest_bfs(rest, state, opts)

      true ->
        state = %{state | visited: MapSet.put(state.visited, node)}

        case Client.fetch_blocking(node, opts) do
          {:ok, blocking} ->
            next = blocking |> Enum.map(&Map.get(&1, "number")) |> Enum.filter(&is_integer/1) |> Enum.map(&{to_string(&1), depth + 1})
            rest_bfs(rest ++ next, %{state | api_calls: state.api_calls + 1}, opts)

          {:error, reason} ->
            if github_http_status?(reason, 404),
              do: rest_bfs(rest, %{state | api_calls: state.api_calls + 1}, opts),
              else: {:error, :cycle_check_inconclusive}
        end
    end
  end

  defp graph_bfs([], _state, _opts), do: :ok

  defp graph_bfs(queue, state, opts) do
    {current_depth, later} = Enum.split_while(queue, fn {_node, depth} -> depth == elem(hd(queue), 1) end)
    depth = current_depth |> hd() |> elem(1)

    nodes =
      current_depth
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&MapSet.member?(state.visited, &1))
      |> Enum.uniq()

    cond do
      Enum.any?(nodes, &(&1 == state.current)) ->
        {:error, :cycle_detected}

      depth > @max_depth or nodes == [] ->
        graph_bfs(later, state, opts)

      true ->
        graph_bfs_frontiers(nodes, depth, later, %{state | visited: MapSet.union(state.visited, MapSet.new(nodes))}, opts)
    end
  end

  defp graph_bfs_frontiers(nodes, depth, later, state, opts) do
    nodes
    |> Enum.chunk_every(@graph_frontier_size)
    |> Enum.reduce_while({:ok, []}, fn frontier, {:ok, acc} ->
      case fetch_blocking_graph(frontier, opts) do
        {:ok, edges} -> {:cont, {:ok, acc ++ edges}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, edges} -> graph_bfs(later ++ Enum.map(edges, &{&1, depth + 1}), state, opts)
      {:error, _reason} -> {:error, :cycle_check_inconclusive}
    end
  end

  defp fetch_blocking_graph(nodes, opts) do
    fetch_blocking_graph_pages(nodes, %{}, [], opts)
  end

  defp fetch_blocking_graph_pages([], _cursors, edges, _opts), do: {:ok, edges}

  defp fetch_blocking_graph_pages(nodes, cursors, edges, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :graph_request_fun, Keyword.get(opts, :request_fun, &Transport.default_request_fun/1))
      variables = Map.merge(%{"owner" => owner, "repo" => repo}, cursors)

      case Transport.github_graphql(request_fun, token, blocking_query(nodes), variables) do
        {:ok, body} ->
          with {:ok, {page_edges, next_cursors}} <- blocking_page(body, nodes) do
            fetch_blocking_graph_pages(Map.keys(next_cursors), next_cursors, edges ++ page_edges, opts)
          end

        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp blocking_query(nodes) do
    variables = Enum.map_join(nodes, ", ", fn node -> "$after_#{node}: String" end)

    aliases =
      Enum.map_join(nodes, "\n", fn node ->
        "issue_#{node}: issue(number: #{node}) { blocking(first: 100, after: $after_#{node}) { nodes { number } pageInfo { hasNextPage endCursor } } }"
      end)

    "query AiurDependencyClosure($owner: String!, $repo: String!, #{variables}) { repository(owner: $owner, name: $repo) { #{aliases} } }"
  end

  defp blocking_page(body, nodes) do
    repository = get_in(body, ["data", "repository"])

    if is_map(repository) do
      nodes
      |> Enum.reduce_while({:ok, {[], %{}}}, fn node, {:ok, {edges, cursors}} ->
        case get_in(repository, ["issue_#{node}", "blocking"]) do
          nil ->
            {:cont, {:ok, {edges, cursors}}}

          %{"nodes" => blocking, "pageInfo" => %{"hasNextPage" => has_next, "endCursor" => cursor}}
          when is_list(blocking) and is_boolean(has_next) ->
            next_edges =
              blocking
              |> Enum.map(&Map.get(&1, "number"))
              |> Enum.filter(&is_integer/1)
              |> Enum.map(&to_string/1)

            next_cursors =
              if has_next and is_binary(cursor), do: Map.put(cursors, "after_#{node}", cursor), else: cursors

            if has_next and not is_binary(cursor) do
              {:halt, {:error, :dependency_graph_pagination_missing_cursor}}
            else
              {:cont, {:ok, {edges ++ next_edges, next_cursors}}}
            end

          _other ->
            {:halt, {:error, :dependency_graph_missing}}
        end
      end)
    else
      {:error, :dependency_graph_missing}
    end
  end

  defp github_status?({:github, _class, %{status: status}}, status), do: true
  defp github_status?(_reason, _status), do: false

  defp github_http_status?({:github, :http, %{status: status}}, status), do: true
  defp github_http_status?(_reason, _status), do: false

  defp github_rate_limited?({:github, :rate_limited, _details}), do: true
  defp github_rate_limited?(_reason), do: false
end
