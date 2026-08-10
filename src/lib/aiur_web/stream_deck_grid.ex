defmodule AiurWeb.StreamDeckGrid do
  @moduledoc """
  Purpose-shaped Stream Deck projection over one orchestrator snapshot.

  `agents` is already sorted by the canonical Stream Deck bucket order. The
  controller fills the physical 4-column × 2-row grid column-major:
  `agents[(column_offset + column) * rows_per_column + row]`. Paging is thus
  horizontal by column. `total`, `windows`, and `max_column_offset` let a
  client page without re-deriving fleet state.
  """

  alias Aiur.{AgentEvents, AgentList.Summaries, CodingAgent, Orchestrator}

  @columns_per_page 4
  @rows_per_column 2
  @agents_per_page @columns_per_page * @rows_per_column
  @bucket_rank %{alert: 0, stuck: 1, running: 2, paused: 3, queued: 4}

  @spec payload(GenServer.name(), timeout()) :: map()
  def payload(orchestrator, snapshot_timeout_ms) do
    case Orchestrator.dashboard_snapshot(orchestrator, snapshot_timeout_ms) do
      {status, snapshot, freshness} when status in [:current, :stale] ->
        snapshot |> project() |> Map.put(:snapshot_freshness, freshness)

      :snapshot_timeout ->
        %{error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :orchestrator_unavailable ->
        %{error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec project(map()) :: map()
  @spec project(map(), (map() -> boolean())) :: map()
  def project(snapshot, dependency_ready? \\ &dependency_ready?/1)

  def project(%{} = snapshot, dependency_ready?) when is_function(dependency_ready?, 1) do
    agents =
      snapshot
      |> snapshot_agents()
      |> Enum.map(fn entry -> {entry, AgentEvents.streamdeck_bucket(entry)} end)
      |> Enum.filter(fn {_entry, bucket} -> Map.has_key?(@bucket_rank, bucket) end)
      |> Enum.map(fn {entry, bucket} -> agent_payload(entry, bucket, dependency_ready?) end)
      |> stable_rank()

    total = length(agents)

    %{
      agents: agents,
      total: total,
      columns_per_page: @columns_per_page,
      rows_per_column: @rows_per_column,
      agents_per_page: @agents_per_page,
      windows: ceil_div(total, @agents_per_page),
      max_column_offset: max(ceil_div(total, @rows_per_column) - @columns_per_page, 0)
    }
  end

  defp snapshot_agents(snapshot) do
    for {source, entries} <- [running: Map.get(snapshot, :running, []), retrying: Map.get(snapshot, :retrying, []), queued: Map.get(snapshot, :idle, [])],
        entry <- entries,
        do: Map.put(entry, :streamdeck_source, source)
  end

  defp agent_payload(entry, bucket, dependency_ready?) do
    entry
    |> base_agent_payload(bucket)
    |> maybe_put_dependency_ready(entry, bucket, dependency_ready?)
  end

  defp base_agent_payload(entry, bucket) do
    %{
      identifier: Map.get(entry, :identifier),
      title: Map.get(entry, :title),
      vendor: vendor(entry),
      bucket: bucket,
      progress_percent: progress_percent(entry),
      priority: priority?(entry)
    }
  end

  defp maybe_put_dependency_ready(payload, entry, :queued, dependency_ready?),
    do: Map.put(payload, :dependency_ready, dependency_ready?.(entry))

  defp maybe_put_dependency_ready(payload, _entry, _bucket, _dependency_ready?), do: payload

  defp stable_rank(agents) do
    agents
    |> Enum.with_index()
    |> Enum.sort_by(fn {agent, index} -> {sort_key(agent), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp sort_key(%{bucket: bucket, identifier: identifier} = agent) do
    dependency_ready = Map.get(agent, :dependency_ready)
    {@bucket_rank[bucket], if(bucket == :queued and dependency_ready == true, do: 0, else: 1), Summaries.identifier_sort_key(identifier)}
  end

  defp vendor(entry) do
    family = Map.get(entry, :agent_family) || CodingAgent.family_for(Map.get(entry, :backend))

    case CodingAgent.provider_descriptor(family) do
      %{provider: provider} -> Atom.to_string(provider)
      _ -> "unknown"
    end
  end

  defp progress_percent(entry) do
    case Map.get(entry, :progress_percent) do
      percent when is_integer(percent) and percent in 0..100 -> percent
      _ -> 0
    end
  end

  defp priority?(entry), do: is_integer(Map.get(entry, :priority)) and Map.get(entry, :priority) > 0

  defp dependency_ready?(%{streamdeck_source: :queued, waiting_reason: :waiting_for_dependency}), do: false
  defp dependency_ready?(%{streamdeck_source: :queued, waiting_reason: :tracker_unavailable}), do: false
  defp dependency_ready?(%{streamdeck_source: :queued}), do: true

  defp ceil_div(0, _divisor), do: 0
  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)
end
