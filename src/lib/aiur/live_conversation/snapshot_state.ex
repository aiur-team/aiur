defmodule Aiur.LiveConversation.SnapshotState do
  @moduledoc """
  Pure snapshot construction, lifecycle transitions and retention for
  `Aiur.LiveConversation`. Nothing here touches a process, a topic or a clock.
  """

  alias Aiur.LiveConversation.{Normalizer, Retention, Source}

  @version 1

  @spec version() :: pos_integer()
  def version, do: @version

  @spec fresh_snapshot(term(), DateTime.t(), String.t() | nil, String.t()) :: map()
  def fresh_snapshot(source, now, handle, projection_epoch) do
    %{
      version: @version,
      projection_epoch: projection_epoch,
      revision: 0,
      source_revision: 0,
      generation_handle: handle,
      source: source,
      state: :known_empty,
      health: :healthy,
      freshness: :current,
      messages: [],
      seen: %{},
      replay_tombstones: %{},
      observed_at: now,
      diagnostic_counts: %{},
      truncated?: false,
      evicted_count: 0
    }
  end

  @spec restart_unknown_snapshot(term(), DateTime.t(), String.t(), String.t() | nil) :: map()
  def restart_unknown_snapshot(source, now, projection_epoch, handle \\ nil) do
    source
    |> fresh_snapshot(now, handle, projection_epoch)
    |> restart_unknown()
  end

  @spec restart_unknown(map()) :: map()
  def restart_unknown(snapshot) do
    %{snapshot | state: :restart_unknown, health: :unknown, freshness: :unknown}
  end

  @spec unavailable_snapshot(DateTime.t(), String.t(), atom()) :: map()
  def unavailable_snapshot(now, projection_epoch, reason) do
    %{
      version: @version,
      projection_epoch: projection_epoch,
      revision: 0,
      source_revision: 0,
      generation_handle: nil,
      source: nil,
      state: :unavailable,
      health: :unavailable,
      freshness: :unknown,
      messages: [],
      observed_at: now,
      diagnostic_counts: %{reason => 1},
      truncated?: false,
      evicted_count: 0
    }
  end

  @spec activate_snapshot(map(), DateTime.t(), boolean(), boolean()) :: map()
  def activate_snapshot(%{state: :ended} = snapshot, _now, _created?, _history_known?),
    do: snapshot

  def activate_snapshot(snapshot, now, _created?, false) do
    snapshot
    |> restart_unknown()
    |> Map.put(:observed_at, now)
  end

  def activate_snapshot(snapshot, now, _created?, _history_known?) do
    next_state = if snapshot.messages == [], do: :known_empty, else: :live

    snapshot
    |> Map.merge(%{
      state: next_state,
      health: :healthy,
      freshness: :current,
      observed_at: now
    })
  end

  @spec state_transition(atom(), map()) :: {atom(), atom(), atom()}
  def state_transition(:degraded, %{messages: []}),
    do: {:unavailable, :unavailable, :unknown}

  def state_transition(:degraded, _snapshot),
    do: {:stale, :unavailable, :stale}

  # Ending a generation is authoritative about lifecycle, not about source
  # recovery. Preserve any unavailable/stale health so an incomplete
  # conversation cannot become healthy merely because its run stopped.
  def state_transition(:ended, snapshot),
    do: {:ended, snapshot.health, snapshot.freshness}

  def state_transition(state, _snapshot),
    do: {state, health_for(state), freshness_for(state)}

  defp health_for(:unavailable), do: :unavailable
  defp health_for(_state), do: :healthy

  defp freshness_for(:stale), do: :stale
  defp freshness_for(:unavailable), do: :unknown
  defp freshness_for(_state), do: :current

  @spec public(map()) :: map()
  def public(snapshot) do
    snapshot
    |> Map.take([
      :version,
      :projection_epoch,
      :revision,
      :source_revision,
      :generation_handle,
      :source,
      :state,
      :health,
      :freshness,
      :messages,
      :observed_at,
      :diagnostic_counts,
      :truncated?,
      :evicted_count
    ])
    |> Map.update!(:messages, fn messages ->
      Enum.map(messages, &Normalizer.public_message/1)
    end)
  end

  defp put_snapshot(state, key, snapshot) do
    snapshots =
      state.snapshots
      |> Map.put(key, snapshot)
      |> Retention.retain_snapshots()

    handles =
      Map.new(snapshots, fn {snapshot_key, retained} ->
        {retained.generation_handle, snapshot_key}
      end)

    runtime_subscribers = Map.take(state.runtime_subscribers, Map.keys(snapshots))

    %{
      state
      | snapshots: snapshots,
        handles: handles,
        runtime_subscribers: runtime_subscribers
    }
  end

  @spec persist_snapshot(map(), term(), map(), boolean()) :: {map(), map()}
  def persist_snapshot(state, _key, snapshot, false), do: {snapshot, state}

  def persist_snapshot(state, key, snapshot, true) do
    revision = state.next_revision + 1

    snapshot =
      snapshot
      |> Map.put(:revision, revision)
      |> Map.update!(:source_revision, fn
        0 -> revision
        source_revision -> source_revision
      end)
      |> Retention.retain(&public/1)

    state =
      state
      |> Map.put(:next_revision, revision)
      |> put_snapshot(key, snapshot)
      |> update_active_revision(key, revision)

    {snapshot, state}
  end

  defp update_active_revision(state, key, revision) do
    scope = Source.scope(key)

    case Map.get(state.active_sources, scope) do
      %{key: ^key} = active ->
        put_in(state.active_sources[scope], %{active | revision: revision})

      _other ->
        state
    end
  end
end
