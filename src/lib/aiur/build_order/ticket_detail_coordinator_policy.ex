defmodule Aiur.BuildOrder.TicketDetailCoordinator.Policy do
  @moduledoc false

  alias Aiur.BuildOrder.TicketDetail.{Failure, Snapshot, State}
  alias Aiur.TrackerIdentity

  @type entry :: %{
          identity: TrackerIdentity.t(),
          detail: Snapshot.t() | nil,
          failure: Failure.t() | nil,
          generation: pos_integer() | :unknown,
          last_access_ms: integer(),
          last_success_ms: integer() | nil,
          last_attempt_at: DateTime.t() | nil,
          inflight: map() | nil
        }

  @spec topic(TrackerIdentity.t()) :: String.t()
  def topic(identity) do
    "build_order:detail:" <> Base.url_encode64(:erlang.term_to_binary(cache_key(identity)), padding: false)
  end

  @spec cache_key(TrackerIdentity.t()) :: tuple()
  def cache_key(%TrackerIdentity{kind: kind, owner: owner, repository: repository, provider_id: provider_id}),
    do: {kind, String.downcase(owner), String.downcase(repository), provider_id}

  @spec ensure_entry(map(), TrackerIdentity.t()) :: {:ok, map(), [State.t()]} | {:error, Failure.t()}
  def ensure_entry(state, identity) do
    key = cache_key(identity)

    if Map.has_key?(state.entries, key) do
      {:ok, state, []}
    else
      with {:ok, state, updates} <- make_room(state) do
        entry = %{
          identity: identity,
          detail: nil,
          failure: nil,
          generation: :unknown,
          last_access_ms: now_ms(state),
          last_success_ms: nil,
          last_attempt_at: nil,
          inflight: nil
        }

        {:ok, %{state | entries: Map.put(state.entries, key, entry)}, updates}
      end
    end
  end

  @spec touch(map(), TrackerIdentity.t()) :: {entry(), map()}
  def touch(state, identity) do
    key = cache_key(identity)
    entry = %{Map.fetch!(state.entries, key) | last_access_ms: now_ms(state)}
    {entry, %{state | entries: Map.put(state.entries, key, entry)}}
  end

  @spec current(map(), TrackerIdentity.t()) :: State.t()
  def current(state, identity) do
    case Map.fetch(state.entries, cache_key(identity)) do
      {:ok, entry} -> state_for(entry, state)
      :error -> unavailable_state(identity)
    end
  end

  @spec evict_all(map()) :: {map(), [State.t()]}
  def evict_all(state) do
    updates = state.entries |> Map.values() |> Enum.map(&evicted_state/1)
    {%{state | entries: %{}, inflight_by_ref: %{}}, updates}
  end

  @spec fresh?(entry(), map()) :: boolean()
  def fresh?(%{detail: %Snapshot{}, failure: nil, last_success_ms: last_success_ms}, state) when is_integer(last_success_ms) do
    now_ms(state) - last_success_ms < state.freshness_ms
  end

  def fresh?(_entry, _state), do: false

  @spec state_for(entry(), map()) :: State.t()
  def state_for(%{detail: detail, failure: failure} = entry, state) do
    %State{
      identity: entry.identity,
      generation: entry.generation,
      health: health(detail, failure, entry, state),
      detail: detail,
      failure: failure,
      last_success_at: detail && detail.observed_at,
      last_attempt_at: entry.last_attempt_at
    }
  end

  @spec evicted_state(entry()) :: State.t()
  def evicted_state(entry) do
    %State{
      identity: entry.identity,
      generation: entry.generation,
      health: :unavailable,
      failure: %Failure{kind: :evicted}
    }
  end

  defp make_room(state) when map_size(state.entries) < state.max_entries, do: {:ok, state, []}

  defp make_room(state) do
    state.entries
    |> Enum.reject(fn {_key, entry} -> entry.inflight end)
    |> Enum.min_by(fn {_key, entry} -> entry.last_access_ms end, fn -> nil end)
    |> case do
      {key, entry} -> {:ok, %{state | entries: Map.delete(state.entries, key)}, [evicted_state(entry)]}
      nil -> {:error, %Failure{kind: :capacity}}
    end
  end

  defp unavailable_state(identity), do: %State{identity: identity, generation: :unknown, health: :unavailable}
  defp health(nil, _failure, _entry, _state), do: :unavailable
  defp health(%Snapshot{}, failure, _entry, _state) when not is_nil(failure), do: :stale
  defp health(%Snapshot{}, _failure, entry, state), do: if(fresh?(entry, state), do: :healthy, else: :stale)
  defp now_ms(state), do: state.clock_ms.()
end
