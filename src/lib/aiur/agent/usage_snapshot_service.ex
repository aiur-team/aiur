defmodule Aiur.Agent.UsageSnapshotService do
  @moduledoc """
  Service for fetching and assembling per-agent cumulative usage snapshots.

  Queries the UsageAggregate at view time (no denormalized storage) and assembles
  a point-in-time snapshot of an agent's lifetime token consumption, including
  scope, freshness, and explicit unknown handling.
  """

  alias Aiur.Agent.UsageSnapshot
  alias Aiur.UsageAggregate

  @doc """
  Fetch the current usage snapshot for an agent.

  Returns `{:ok, snapshot}` with a populated UsageSnapshot struct, or
  `{:error, reason}` if the snapshot cannot be assembled.

  Options:
    - `:run_id` — the run identifier (optional; if provided, scopes query to that run)
    - `:ticket` — the TrackerIdentity struct (optional; if provided, scopes query to that ticket)

  If neither run_id nor ticket are provided, attempts to look up the agent's
  current session from agent state.
  """
  @spec current(String.t(), Keyword.t()) :: {:ok, UsageSnapshot.t()} | {:error, atom()}
  def current(agent_id, opts \\ []) do
    with {:ok, scope_params} <- resolve_scope(agent_id, opts),
         {:ok, cells} <- fetch_aggregate_cells(scope_params),
         {:ok, snapshot} <- assemble_snapshot(agent_id, cells, scope_params) do
      {:ok, snapshot}
    end
  end

  # Resolve the scope (run_id, ticket) for querying the aggregate
  # If not provided in opts, attempts to look up from agent state
  @spec resolve_scope(String.t(), Keyword.t()) ::
    {:ok, %{run_id: String.t() | nil, ticket: any()}} | {:error, atom()}
  defp resolve_scope(agent_id, opts) do
    run_id = Keyword.get(opts, :run_id)
    ticket = Keyword.get(opts, :ticket)

    cond do
      run_id && ticket ->
        {:ok, %{run_id: run_id, ticket: ticket}}

      run_id ->
        {:ok, %{run_id: run_id, ticket: nil}}

      ticket ->
        {:ok, %{run_id: nil, ticket: ticket}}

      true ->
        # Attempt to resolve from agent state
        lookup_agent_scope(agent_id)
    end
  end

  # Look up agent's current run/ticket from agent state
  # This is a placeholder that would integrate with Aiur's agent tracking
  @spec lookup_agent_scope(String.t()) :: {:error, :unable_to_resolve_scope}
  defp lookup_agent_scope(_agent_id) do
    # TODO: Integrate with Aiur.AgentQueue or similar to resolve current scope
    # For now, return error to indicate scope must be provided explicitly
    {:error, :unable_to_resolve_scope}
  end

  # Query UsageAggregate for cells matching the scope
  @spec fetch_aggregate_cells(%{run_id: String.t() | nil, ticket: any()}) ::
    {:ok, list()} | {:error, atom()}
  defp fetch_aggregate_cells(scope_params) do
    query_scope = build_aggregate_query(scope_params)

    try do
      result = UsageAggregate.query(query_scope)

      # UsageAggregate.query returns a map with cells or an error indicator
      case result do
        %{cells: cells} when is_map(cells) and map_size(cells) > 0 ->
          {:ok, cells}

        %{cells: _} ->
          {:error, :no_usage_data}

        _other ->
          {:error, :unable_to_query_aggregate}
      end
    rescue
      _ -> {:error, :aggregate_query_failed}
    end
  end

  # Build the query scope for UsageAggregate.query/1
  defp build_aggregate_query(scope_params) do
    scope = %{}

    scope =
      if scope_params.run_id do
        Map.put(scope, :runs, [scope_params.run_id])
      else
        scope
      end

    scope =
      if scope_params.ticket do
        Map.put(scope, :tickets, [scope_params.ticket])
      else
        scope
      end

    scope
  end

  # Assemble the snapshot from aggregate cells
  # This extracts token dimensions and computes derived values
  @spec assemble_snapshot(String.t(), map(), %{run_id: String.t() | nil, ticket: any()}) ::
    {:ok, UsageSnapshot.t()} | {:error, atom()}
  defp assemble_snapshot(agent_id, cells, scope_params) do
    # Extract cumulative metrics from cells
    # Cells are keyed by their relationship revision and partitions
    # We aggregate across all cells, summing totals and preserving unknowns
    metrics = aggregate_metrics_from_cells(cells)

    # Determine scope and scope_id from the cells
    {scope, scope_id} = extract_scope_info(cells, scope_params)

    # Get freshness from the most recent cell
    observed_at = get_most_recent_timestamp(cells)
    freshness = UsageSnapshot.assess_freshness(observed_at)

    # Infer backend from cells if present
    backend = extract_backend(cells)

    {:ok,
     %UsageSnapshot{
       agent_id: agent_id,
       backend: backend,
       context_occupancy: nil,  # Will be populated separately if needed
       cumulative_metrics: metrics,
       scope: scope,
       scope_id: scope_id,
       observed_at: observed_at,
       freshness_assessment: freshness
     }}
  end

  # Aggregate token dimensions from cells
  # Returns a metrics map with explicit unknown handling
  @spec aggregate_metrics_from_cells(map()) :: UsageSnapshot.cumulative_metrics()
  defp aggregate_metrics_from_cells(cells) do
    # Sum tokens across all cells, preserving unknowns
    input = sum_or_unknown(:input, cells)
    output = sum_or_unknown(:output, cells)
    cached_input = sum_or_unknown(:cached_input, cells)

    # Derive uncached input
    uncached_input = derive_uncached_input(input, cached_input)

    # Calculate cached proportion
    cached_proportion = UsageSnapshot.calculate_cached_proportion(input, cached_input)

    %{
      input: input,
      output: output,
      cached_input: cached_input,
      uncached_input: uncached_input,
      cached_proportion: cached_proportion
    }
  end

  # Sum a token field across all cells, or return :unknown if any cell has unknown
  # This follows the logic: if ANY cell reports unknown, the aggregate is unknown
  @spec sum_or_unknown(atom(), map()) :: non_neg_integer() | {:unknown, atom()}
  defp sum_or_unknown(field, cells) do
    cells
    |> Map.values()
    |> Enum.reduce({:ok, 0}, fn cell, acc ->
      case acc do
        {:error, _reason} = err ->
          err

        {:ok, total} ->
          # Each cell might be a nested map or a direct token value
          # Follow the structure from UsageAggregate
          value = extract_token_field(cell, field)

          case value do
            {:unknown, reason} -> {:error, {:unknown, reason}}
            nil -> {:ok, total}  # Missing field = treat as zero contribution
            n when is_integer(n) and n >= 0 -> {:ok, total + n}
            _ -> {:error, {:unknown, :invalid_value}}
          end
      end
    end)
    |> case do
      {:ok, total} -> total
      {:error, reason} -> reason
    end
  end

  # Extract a token field from a cell
  # Cells may have nested structure depending on aggregate partitioning
  @spec extract_token_field(any(), atom()) :: non_neg_integer() | {:unknown, atom()} | nil
  defp extract_token_field(cell, field) when is_map(cell) do
    # Look for the field directly in the cell
    case cell do
      %{tokens: tokens} when is_map(tokens) ->
        Map.get(tokens, field)

      %{^field => value} ->
        value

      _ ->
        nil
    end
  end

  defp extract_token_field(_cell, _field), do: nil

  # Derive uncached_input = input - cached_input
  @spec derive_uncached_input(
    non_neg_integer() | {:unknown, atom()},
    non_neg_integer() | {:unknown, atom()}
  ) :: non_neg_integer() | {:unknown, atom()}
  defp derive_uncached_input({:unknown, _}, _), do: {:unknown, :missing_input}
  defp derive_uncached_input(_, {:unknown, _}), do: {:unknown, :missing_cached_input}

  defp derive_uncached_input(input, cached_input)
       when is_integer(input) and is_integer(cached_input) and input >= cached_input do
    input - cached_input
  end

  defp derive_uncached_input(_input, _cached_input) do
    {:unknown, :invalid_inputs}
  end

  # Extract scope information from cells
  # Returns {scope, scope_id}
  @spec extract_scope_info(map(), %{run_id: String.t() | nil, ticket: any()}) ::
    {UsageSnapshot.scope(), String.t()}
  defp extract_scope_info(_cells, scope_params) do
    # Determine scope based on what was queried
    scope =
      cond do
        scope_params.ticket -> :ticket
        scope_params.run_id -> :session
        true -> :session
      end

    # Build scope_id
    scope_id =
      cond do
        scope_params.ticket ->
          "#{scope_params.ticket}"

        scope_params.run_id ->
          scope_params.run_id

        true ->
          "unknown"
      end

    {scope, scope_id}
  end

  # Get the most recent timestamp from all cells
  @spec get_most_recent_timestamp(map()) :: DateTime.t() | nil
  defp get_most_recent_timestamp(cells) do
    cells
    |> Map.values()
    |> Enum.filter(fn cell -> is_map(cell) && Map.has_key?(cell, :ingested_at) end)
    |> Enum.map(fn cell -> cell.ingested_at end)
    |> case do
      [] -> nil
      timestamps -> Enum.max(timestamps)
    end
  end

  # Extract backend from cells if present
  @spec extract_backend(map()) :: atom() | String.t()
  defp extract_backend(cells) do
    cells
    |> Map.values()
    |> Enum.find_value(
      :unknown,
      fn cell ->
        if is_map(cell) && Map.has_key?(cell, :backend) do
          cell.backend
        else
          nil
        end
      end
    )
  end
end
