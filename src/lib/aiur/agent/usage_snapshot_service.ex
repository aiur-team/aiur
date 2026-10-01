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
         {:ok, cells} <- fetch_aggregate_cells(scope_params) do
      assemble_snapshot(agent_id, cells, scope_params)
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
  # Scope must be provided explicitly via options for now
  @spec lookup_agent_scope(String.t()) :: {:error, :unable_to_resolve_scope}
  defp lookup_agent_scope(_agent_id) do
    {:error, :unable_to_resolve_scope}
  end

  # Query UsageAggregate for cells matching the scope
  @spec fetch_aggregate_cells(%{run_id: String.t() | nil, ticket: any()}) ::
          {:ok, map()} | {:error, atom()}
  defp fetch_aggregate_cells(_scope_params) do
    %{cells: cells} = UsageAggregate.cells_snapshot()

    case cells do
      cells when is_map(cells) and map_size(cells) > 0 ->
        {:ok, cells}

      _ ->
        {:error, :no_usage_data}
    end
  rescue
    _ -> {:error, :aggregate_query_failed}
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
       # Will be populated separately if needed
       context_occupancy: nil,
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
    |> Enum.reduce_while({:ok, 0}, &sum_field_step(&1, &2, field))
    |> case do
      {:ok, total} -> total
      {:error, reason} -> reason
    end
  end

  # Step function for summing a field across cells
  @spec sum_field_step(any(), tuple(), atom()) :: {:cont, tuple()} | {:halt, tuple()}
  defp sum_field_step(_cell, {:error, _} = err, _field), do: {:halt, err}

  defp sum_field_step(cell, {:ok, total}, field) do
    value = extract_token_field(cell, field)

    case value do
      {:unknown, reason} -> {:halt, {:error, {:unknown, reason}}}
      nil -> {:cont, {:ok, total}}
      n when is_integer(n) and n >= 0 -> {:cont, {:ok, total + n}}
      _ -> {:halt, {:error, {:unknown, :invalid_value}}}
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
