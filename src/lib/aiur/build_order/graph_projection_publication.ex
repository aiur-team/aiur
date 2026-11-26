defmodule Aiur.BuildOrder.GraphProjection.Publication do
  @moduledoc false

  # Snapshots of the held entries and their PubSub broadcast.
  # Runs inside the projection process: every `self()` here is the GenServer.

  alias Aiur.BuildOrder.GraphProjection.{CapabilityReader, Policy, Schedule, Snapshot}

  @reset_topic "build_order:graph:reset"

  @spec reset_topic() :: String.t()
  def reset_topic, do: @reset_topic

  @spec catalog_snapshot(map()) :: Snapshot.t()
  def catalog_snapshot(state),
    do: Policy.snapshot(state.catalog, state.active_repository, state.authority_epoch, Schedule.now_ms(state), Schedule.catalog_bound_ms(state))

  # The window after which a selected root is *displayed* as ageing. It is not a
  # refresh trigger — nothing reads this to decide whether to spend — it only
  # decides what the page tells the operator about the age of what it is showing.
  #
  # Re-based from `catalog_refresh_ms` (#2313): the catalog is event-sourced, so
  # the old justification — "the catalog reconciliation is the daemon-owned
  # writer that would next notice this root changing" — no longer holds. The
  # real bound on how stale a watched root can be without anyone finding out is
  # delivery latency: a gap longer than `webhooks.silence_threshold_seconds`
  # degrades delivery mode and triggers the reconciliation that re-reads watched
  # roots. So the display age is that threshold.
  defp selected_staleness_ms(state), do: state.policy.delivery_staleness_ms

  @spec selected_snapshot(map(), Aiur.TrackerIdentity.t()) :: Snapshot.t()
  def selected_snapshot(state, identity) do
    case Map.get(state.selected, Policy.root_key(identity)) do
      nil ->
        identity
        |> then(&Policy.unavailable_entry({:selected, &1}, Schedule.now_ms(state)))
        |> Policy.snapshot(state.active_repository, state.authority_epoch, Schedule.now_ms(state), selected_staleness_ms(state))

      entry ->
        Policy.snapshot(entry, state.active_repository, state.authority_epoch, Schedule.now_ms(state), selected_staleness_ms(state))
    end
  end

  @spec snapshot_for_entry(map(), map()) :: Snapshot.t()
  def snapshot_for_entry(%{scope: :catalog}, state), do: catalog_snapshot(state)
  def snapshot_for_entry(%{scope: {:selected, identity}}, state), do: selected_snapshot(state, identity)

  @spec broadcast_all(map(), [tuple()]) :: :ok
  def broadcast_all(state, events) do
    CapabilityReader.publish(state, Schedule.catalog_bound_ms(state))
    Enum.each(events, &broadcast(state, &1))
  end

  defp broadcast(state, {:reset, generation}) do
    publish(@reset_topic, {:graph_projection_reset, generation})
    after_broadcast(state, {:graph_projection_reset, generation})
  end

  defp broadcast(state, {kind, %Snapshot{} = snapshot}) when kind in [:generation, :health] do
    event =
      case kind do
        :generation -> {:graph_projection_generation, snapshot}
        :health -> {:graph_projection_health, snapshot}
      end

    publish(topic(snapshot), event)
    after_broadcast(state, event)
  end

  defp publish(topic, event) do
    if Process.whereis(Aiur.PubSub), do: Phoenix.PubSub.broadcast(Aiur.PubSub, topic, event)
  end

  defp topic(%Snapshot{scope: :catalog, repository: repository}), do: Policy.catalog_topic(repository)
  defp topic(%Snapshot{scope: {:selected, identity}}), do: Policy.selected_topic(identity)

  defp after_broadcast(state, event) do
    state.after_broadcast.(event)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @spec subscribe_scope((-> term())) :: :ok | {:error, term()}
  def subscribe_scope(topic_fun) do
    with :ok <- Phoenix.PubSub.subscribe(Aiur.PubSub, @reset_topic),
         {:ok, topic} <- topic_fun.() do
      Phoenix.PubSub.subscribe(Aiur.PubSub, topic)
    end
  end
end
