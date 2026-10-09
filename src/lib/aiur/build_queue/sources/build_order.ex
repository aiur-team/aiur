defmodule Aiur.BuildQueue.Sources.ProjectionRead do
  @moduledoc "Reads existing Build Order projections without demand, refresh, or upstream requests."
  alias Aiur.BuildOrder.{Catalog, GraphProjection, ProgressRenderer, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildQueue.ReadModel

  @spec read(pos_integer(), integer(), GenServer.server()) :: map()
  def read(root, now, server \\ GraphProjection) do
    with %Snapshot{data: %Catalog{entries: entries}} <- GraphProjection.catalog(server),
         [entry] <- Enum.filter(entries, &(&1.identity && &1.identity.identifier == to_string(root))),
         {:ok, %Snapshot{data: %SelectedRoot{} = data, health: health}} <- GraphProjection.selected(server, entry.identity) do
      completion = ProgressRenderer.json(data.root)

      %{
        source: health(health, now),
        progress: %{
          completed: if(completion["progress"], do: Enum.count(data.members, &(&1.lifecycle.state == :closed and &1.lifecycle.state_reason == :completed))),
          resolved: completion["progress_resolved_count"],
          total: data.root.member_count,
          percent: completion["progress"],
          resolution: completion["progress_resolution"]
        }
      }
    else
      _ -> unavailable(now, :projection_unavailable)
    end
  catch
    :exit, _reason -> unavailable(now, :projection_unavailable)
  end

  defp health(health, now) do
    observed = if health.observed_at, do: DateTime.to_unix(health.observed_at, :millisecond)
    source = ReadModel.source(observed, now, 9_223_372_036_854_775_807, Enum.reject([health.failure], &is_nil/1))

    freshness =
      case health.state do
        :healthy -> if(observed, do: :current, else: :unknown)
        :stale -> :stale
        _ -> :unknown
      end

    %{source | freshness: freshness, partial: not health.complete?, state: if(health.state in [:healthy, :stale], do: :ok, else: :unavailable)}
  end

  defp unavailable(now, reason), do: %{source: ReadModel.source(nil, now, 1, [reason]), progress: %{completed: nil, resolved: nil, total: nil, percent: nil, resolution: :unknown}}
end
