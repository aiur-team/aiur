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
    * 200-API-call budget — defends against pathological graphs that
      would otherwise exhaust the rate limit

  If the budget is exhausted without finding a cycle, return
  `{:error, :rate_limited}` rather than POST optimistically — letting
  the agent know the check was inconclusive is the right call.
  """

  require Logger

  alias Aiur.GitHub.Client

  @max_depth 100
  @max_api_calls 200

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
    * `{:error, {:github_api_status, n}}` — other HTTP failures
  """
  @spec declare(integer() | String.t(), integer() | String.t(), keyword()) ::
          {:ok, map() | :already_present} | {:error, term()}
  def declare(current_number, blocker_number, opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun)
    client_opts = if request_fun, do: [request_fun: request_fun], else: []

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
          {:ok, map()} | {:error, term()}
  def unblock(current_number, blocker_number, opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun)
    client_opts = if request_fun, do: [request_fun: request_fun], else: []

    with {:ok, blocker_issue} <- fetch_blocker(blocker_number, client_opts),
         blocker_id when is_integer(blocker_id) <- Map.get(blocker_issue, "id") do
      case Client.remove_dependency(current_number, blocker_id, client_opts) do
        {:ok, result} -> {:ok, result}
        {:error, {:github_api_status, 404}} -> {:ok, :not_present}
        {:error, {:github_api_status, 403}} -> {:error, :permission_denied}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_blocker(blocker_number, client_opts) do
    case Client.fetch_issue_raw(blocker_number, client_opts) do
      {:ok, issue} -> {:ok, issue}
      {:error, {:github_api_status, 404}} -> {:error, :blocker_not_found}
      {:error, reason} -> {:error, reason}
    end
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
      {:error, {:github_api_status, 403}} -> {:error, :permission_denied}
      {:error, {:github_api_status, 422}} -> {:error, :cycle_detected}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cycle_check(current_number, blocker_number, client_opts) do
    state = %{
      current: to_string(current_number),
      visited: MapSet.new(),
      api_calls: 0
    }

    bfs([{to_string(blocker_number), 0}], state, client_opts)
  end

  defp bfs([], _state, _opts), do: :ok

  defp bfs(_queue, %{api_calls: calls}, _opts) when calls >= @max_api_calls do
    {:error, :rate_limited}
  end

  defp bfs([{_node, depth} | rest], state, opts) when depth > @max_depth do
    bfs(rest, state, opts)
  end

  defp bfs([{node, depth} | rest], state, opts) do
    cond do
      node == state.current -> {:error, :cycle_detected}
      MapSet.member?(state.visited, node) -> bfs(rest, state, opts)
      true -> bfs_expand(node, depth, rest, state, opts)
    end
  end

  defp bfs_expand(node, depth, rest, state, opts) do
    visited_state = %{state | visited: MapSet.put(state.visited, node)}

    case Client.fetch_blocking(node, opts) do
      {:ok, blocking} ->
        next_nodes =
          blocking
          |> Enum.map(&Map.get(&1, "number"))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&{to_string(&1), depth + 1})

        bfs(rest ++ next_nodes, %{visited_state | api_calls: state.api_calls + 1}, opts)

      {:error, {:github_api_status, 404}} ->
        # Issue was deleted from GitHub — no outgoing edges to follow.
        # Treat as a leaf, not an inconclusive cycle check.
        bfs(rest, %{visited_state | api_calls: state.api_calls + 1}, opts)

      {:error, _reason} ->
        # Transient API failure mid-BFS — we can't prove no cycle. Bail
        # out with :cycle_check_inconclusive rather than POST optimistically
        # and trip GitHub's own 422 (or worse, succeed and leave a real
        # cycle hidden in the graph).
        {:error, :cycle_check_inconclusive}
    end
  end
end
