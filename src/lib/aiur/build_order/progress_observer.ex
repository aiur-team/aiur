defmodule Aiur.BuildOrder.ProgressObserver do
  @moduledoc "Publishes catalog progress without demanding any upstream reads."
  use GenServer

  alias Aiur.BuildOrder.{Catalog, GraphProjection, ProviderHealth, RootSummary}
  alias Aiur.BuildOrder.GraphProjection.{Failure, Snapshot}
  alias Aiur.{BuildProgress, TrackerIdentity}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{projection: Keyword.get(opts, :projection, GraphProjection), progress: Keyword.get(opts, :progress, BuildProgress)}
    observe(state)
    {:ok, state}
  end

  @impl true
  def handle_info({kind, %Snapshot{scope: :catalog} = snapshot}, state) when kind in [:graph_projection_generation, :graph_projection_health] do
    publish(snapshot, state)
    {:noreply, state}
  end

  def handle_info({:graph_projection_reset, _generation}, state) do
    observe(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp observe(state) do
    case GraphProjection.subscribe_catalog(state.projection) do
      :ok -> publish(GraphProjection.catalog(state.projection), state)
      {:error, %Failure{kind: :configuration}} -> :ok
    end
  end

  defp publish(%Snapshot{data: %Catalog{entries: entries}, health: health}, state) do
    Enum.each(entries, &publish_root(&1, health, state.progress))
  end

  defp publish(_snapshot, _state), do: :ok

  defp publish_root(%RootSummary{identity: %TrackerIdentity{identifier: identifier}} = root, health, progress) when is_binary(identifier) do
    {number, ""} = Integer.parse(identifier)

    :ok =
      BuildProgress.put_build_order_fact(
        %{
          scope: {:build_order, number},
          percent: root.progress,
          resolution: root.progress_resolution,
          completed: nil,
          resolved: root.progress_resolved_count,
          total: root.member_count,
          freshness: if(ProviderHealth.usable?(health), do: :current, else: :stale),
          observed_at: health.observed_at || DateTime.utc_now()
        },
        progress
      )
  end

  defp publish_root(_root, _health, _progress), do: :ok
end
