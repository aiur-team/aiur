defmodule Aiur.ProviderAccountGeneration.Registry do
  @moduledoc false

  alias Aiur.ProviderAccountGeneration.{Continuity, Monitor, Snapshot, Tombstones}

  @spec issue(map(), atom(), atom(), pid()) :: {:ok, map(), map()} | {:error, :owner_unavailable}
  def issue(state, provider, backend, owner_pid) when is_pid(owner_pid) do
    binding = make_ref()
    authority = make_ref()
    {entry, state} = ensure(state, provider, backend, binding)
    entry = entry |> Map.put(:authority, authority) |> Monitor.owner(owner_pid)
    state = put(state, key(provider, backend, binding), entry)
    :ok = Continuity.retain(state.continuity, key(provider, backend, binding), authority, entry.topic, owner_pid)
    {:ok, %{binding: binding, authority: authority, topic: entry.topic}, state}
  end

  @spec recover(map(), atom(), atom(), reference(), reference(), String.t(), pid()) :: {:ok, list(), map()} | :error
  def recover(state, provider, backend, binding, authority, topic, owner_pid) when is_pid(owner_pid) do
    entry_key = key(provider, backend, binding)

    cond do
      Map.has_key?(state.tombstones, entry_key) ->
        :error

      entry = Map.get(state.entries, entry_key) ->
        recover_existing(state, entry_key, authority, topic, owner_pid, entry)

      Continuity.recover?(state.continuity, entry_key, authority, topic) ->
        entry = new_entry(provider, backend, topic, authority) |> Monitor.owner(owner_pid)
        :ok = Continuity.retain(state.continuity, entry_key, authority, topic, owner_pid)
        {:ok, [{topic, entry.snapshot, :recovered}], put(state, entry_key, entry)}

      true ->
        :error
    end
  end

  @spec subscription(map(), atom(), atom(), reference()) :: {:ok, String.t()} | {:error, :owner_unavailable}
  def subscription(state, provider, backend, binding) do
    case Map.get(state.entries, key(provider, backend, binding)) do
      %{authority: authority, topic: topic} when is_reference(authority) and is_binary(topic) -> {:ok, topic}
      _ -> {:error, :owner_unavailable}
    end
  end

  @spec lookup(map(), atom(), atom(), reference()) :: map()
  def lookup(state, provider, backend, binding) do
    entry_key = key(provider, backend, binding)

    case Map.get(state.entries, entry_key) do
      %{snapshot: snapshot} -> snapshot
      _ -> Map.get(state.tombstones, entry_key, Snapshot.unknown(provider, backend, :unavailable, :never_observed, nil))
    end
  end

  @spec ensure(map(), atom(), atom(), reference()) :: {map(), map()}
  def ensure(state, provider, backend, binding) do
    entry_key = key(provider, backend, binding)

    case Map.get(state.entries, entry_key) do
      nil ->
        entry = new_entry(provider, backend, state.topic_mint.(), nil)
        {entry, put(state, entry_key, entry)}

      entry ->
        {entry, state}
    end
  end

  @spec put(map(), tuple(), map()) :: map()
  def put(state, entry_key, entry), do: %{state | entries: Map.put(state.entries, entry_key, entry)}

  @spec entry(map(), tuple()) :: map() | nil
  def entry(state, entry_key), do: Map.get(state.entries, entry_key)

  @spec key(atom(), atom(), reference()) :: tuple()
  def key(provider, backend, binding), do: {provider, backend, binding}

  @spec authorized?(map(), atom(), atom(), reference(), term()) :: boolean()
  def authorized?(state, provider, backend, binding, authority) do
    case entry(state, key(provider, backend, binding)) do
      %{authority: ^authority} when is_reference(authority) -> true
      _ -> false
    end
  end

  @spec authorized_transition?(map(), atom(), atom(), reference(), map()) :: boolean()
  def authorized_transition?(state, provider, backend, binding, opts) do
    authorized?(state, provider, backend, binding, Map.get(opts, :authority)) and
      authorized_previous?(state, provider, backend, opts)
  end

  @spec retire(map(), tuple(), map()) :: map()
  defdelegate retire(state, entry_key, snapshot), to: Tombstones

  defp recover_existing(state, entry_key, authority, topic, owner_pid, %{authority: nil, topic: topic} = entry) do
    recovered = entry |> Map.merge(%{authority: authority, topic: topic}) |> Monitor.owner(owner_pid)
    :ok = Continuity.retain(state.continuity, entry_key, authority, topic, owner_pid)
    {:ok, [{topic, recovered.snapshot, :recovered}], put(state, entry_key, recovered)}
  end

  defp recover_existing(state, entry_key, authority, topic, owner_pid, %{authority: authority, topic: topic} = entry) do
    :ok = Continuity.retain(state.continuity, entry_key, authority, topic, owner_pid)
    {:ok, [], put(state, entry_key, Monitor.owner(entry, owner_pid))}
  end

  defp recover_existing(_state, _entry_key, _authority, _topic, _owner_pid, _entry), do: :error

  defp authorized_previous?(state, provider, backend, opts) do
    case Map.get(opts, :previous_binding) do
      binding when is_reference(binding) -> authorized?(state, provider, backend, binding, Map.get(opts, :previous_authority))
      _ -> true
    end
  end

  defp new_entry(provider, backend, topic, authority) do
    %{
      snapshot: Snapshot.unknown(provider, backend, :unavailable, :never_observed, nil),
      topic: topic,
      authority: authority,
      monitor: nil
    }
  end
end
