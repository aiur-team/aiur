defmodule Aiur.Agent.UsageSnapshotService do
  @moduledoc "Builds a truthful Codex thread-usage snapshot for one ticket attempt."

  alias Aiur.Agent.UsageSnapshot
  alias Aiur.{TrackerIdentity, UsageAggregate}
  alias Aiur.Usage.GroupedScopes.Scope
  alias Aiur.Usage.Headless.Codex.ThreadUsage

  @spec current(String.t(), Keyword.t()) :: {:ok, UsageSnapshot.t()} | {:error, atom()}
  def current(agent_id, opts \\ []) do
    cells_snapshot_fun = Keyword.get(opts, :cells_snapshot_fun, &UsageAggregate.cells_snapshot/0)
    ledger_scan_fun = Keyword.get(opts, :ledger_scan_fun, &Aiur.UsageLedger.scan/1)

    with %TrackerIdentity{} = ticket <- Keyword.get(opts, :ticket),
         true <- TrackerIdentity.joinable?(ticket),
         attempt_id <- Keyword.get(opts, :attempt_id),
         true <- is_nil(attempt_id) or is_binary(attempt_id),
         %{cells: cells, metadata: metadata} <- cells_snapshot_fun.() do
      {:ok, scope} = Scope.explicit_ticket_set([ticket])

      selected =
        Enum.filter(cells, fn {{dims, {:token, _dimension}}, _value} ->
          dims.provider == :codex and (is_nil(attempt_id) or dims.attempt_id == attempt_id) and
            dims.relationship_revision == ThreadUsage.relationship_revision() and Scope.matches?(scope, dims)
        end)

      case selected do
        [] ->
          {:error, :no_usage_data}

        selected ->
          observation = attempt_observation(ticket, attempt_id, metadata.source_position, ledger_scan_fun)
          metrics = aggregate_metrics_from_cells(Map.new(selected), observation.reported_dimensions)
          assemble(agent_id, ticket, attempt_id, metrics, observation.observed_at)
      end
    else
      false -> {:error, :unable_to_resolve_scope}
      nil -> {:error, :unable_to_resolve_scope}
      _ -> {:error, :unable_to_resolve_scope}
    end
  rescue
    _error -> {:error, :unknown}
  end

  @doc false
  @spec aggregate_metrics_from_cells(map(), map() | nil) :: UsageSnapshot.cumulative_metrics()
  def aggregate_metrics_from_cells(cells, reported_dimensions \\ nil) do
    revisions = cells |> Map.keys() |> Enum.map(fn {dims, _measure} -> Map.get(dims, :relationship_revision) end) |> Enum.uniq()

    if length(revisions) > 1 do
      unknown_metrics(:multiple_relationship_revisions)
    else
      input = dimension_value(:input, cells, reported_dimensions)
      output = dimension_value(:output, cells, reported_dimensions)
      cached_input = dimension_value(:cached_input, cells, reported_dimensions)

      %{
        input: input,
        output: output,
        cached_input: cached_input,
        uncached_input: derive_uncached_input(input, cached_input),
        cached_proportion: UsageSnapshot.calculate_cached_proportion(input, cached_input)
      }
    end
  end

  defp dimension_value(field, cells, nil), do: value_or_unknown(field, cells)

  defp dimension_value(field, cells, reported_dimensions) do
    if Map.get(reported_dimensions, field) == true do
      case value_or_unknown(field, cells) do
        {:unknown, :not_reported} -> 0
        value -> value
      end
    else
      {:unknown, :incomplete_measurement}
    end
  end

  defp value_or_unknown(field, cells) do
    matches = for {{_dims, {:token, ^field}}, value} <- cells, do: value

    case matches do
      values when values != [] and is_list(values) ->
        if Enum.all?(values, &(is_integer(&1) and &1 >= 0)), do: Enum.sum(values), else: {:unknown, :ambiguous_measurement}

      [] ->
        {:unknown, :not_reported}

      _ ->
        {:unknown, :ambiguous_measurement}
    end
  end

  defp unknown_metrics(reason) do
    unknown = {:unknown, reason}
    %{input: unknown, output: unknown, cached_input: unknown, uncached_input: unknown, cached_proportion: unknown}
  end

  defp derive_uncached_input({:unknown, _}, _), do: {:unknown, :missing_input}
  defp derive_uncached_input(_, {:unknown, _}), do: {:unknown, :missing_cached_input}
  defp derive_uncached_input(input, cached) when is_integer(input) and is_integer(cached) and input >= cached, do: input - cached
  defp derive_uncached_input(_, _), do: {:unknown, :invalid_inputs}

  defp attempt_observation(ticket, attempt_id, source_position, ledger_scan_fun) do
    after_position = max(source_position - 10_000, 0)

    case ledger_scan_fun.(after: after_position, limit: 10_000) do
      {:ok, records} ->
        matching = matching_observations(records, ticket, attempt_id, source_position)
        reported_dimensions = reported_dimensions(records, matching, after_position, source_position)
        observed_at = latest_observation_at(matching)
        %{observed_at: observed_at, reported_dimensions: reported_dimensions}

      _unavailable ->
        %{observed_at: nil, reported_dimensions: %{}}
    end
  rescue
    _error -> %{observed_at: nil, reported_dimensions: %{}}
  end

  defp matching_observations(records, ticket, attempt_id, source_position) do
    ticket_key = TrackerIdentity.github_key(ticket)

    Enum.filter(records, fn record ->
      envelope = record.envelope

      record.position <= source_position and envelope.provider == :codex and
        envelope.relationship_revision == ThreadUsage.relationship_revision() and
        (is_nil(attempt_id) or envelope.attribution.attempt_id == attempt_id) and
        TrackerIdentity.github_key(envelope.attribution.tracker_identity) == ticket_key
    end)
  end

  defp reported_dimensions(records, matching, after_position, source_position) do
    complete_scan? = complete_scan?(records, after_position, source_position)

    Map.new([:input, :output, :cached_input], fn dimension ->
      complete? = complete_scan? and matching != [] and Enum.all?(matching, &is_integer(Map.get(&1.envelope.tokens, dimension)))
      {dimension, complete?}
    end)
  end

  defp complete_scan?(records, after_position, source_position) do
    after_position == 0 and length(records) < 10_000 and
      (records == [] or hd(records).position == 1) and
      (records == [] or List.last(records).position >= source_position)
  end

  defp latest_observation_at(matching) do
    matching |> Enum.map(& &1.envelope.ingested_at) |> Enum.max_by(&DateTime.to_unix/1, fn -> nil end)
  end

  defp assemble(agent_id, ticket, attempt_id, metrics, observed_at) do
    {scope, scope_id} =
      case attempt_id do
        attempt when is_binary(attempt) -> {:attempt, "#{inspect(TrackerIdentity.github_key(ticket))} / #{attempt}"}
        nil -> {:ticket, inspect(TrackerIdentity.github_key(ticket))}
      end

    {:ok,
     %UsageSnapshot{
       agent_id: agent_id,
       backend: :codex,
       context_occupancy: nil,
       cumulative_metrics: metrics,
       scope: scope,
       scope_id: scope_id,
       observed_at: observed_at,
       freshness_assessment: UsageSnapshot.assess_freshness(observed_at)
     }}
  end
end
