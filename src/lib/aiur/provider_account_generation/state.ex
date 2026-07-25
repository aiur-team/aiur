defmodule Aiur.ProviderAccountGeneration.State do
  @moduledoc false

  alias Aiur.ProviderAccountGeneration.{Continuity, Lifecycle, Registry, Snapshot, Tombstones, Validation}

  @spec new(keyword()) :: map()
  def new(opts) do
    %{
      entries: %{},
      tombstones: %{},
      tombstone_order: [],
      continuity: Continuity.service_id(Keyword.get(opts, :name, Aiur.ProviderAccountGeneration)),
      tombstone_limit: max(Keyword.get(opts, :tombstone_limit, 256), 0),
      mint: Keyword.get(opts, :mint, &mint_generation/0),
      topic_mint: Keyword.get(opts, :topic_mint, &mint_topic/0),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)
    }
  end

  @spec lookup(map(), atom(), atom(), reference()) :: map()
  defdelegate lookup(state, provider, backend, binding), to: Registry

  @spec issue(map(), atom(), atom(), pid()) :: {:ok, map(), map()} | {:error, :owner_unavailable}
  def issue(state, provider, backend, owner_pid) when is_pid(owner_pid) do
    if Validation.scope?(provider, backend),
      do: Registry.issue(state, provider, backend, owner_pid),
      else: {:error, :owner_unavailable}
  end

  @spec recover(map(), atom(), atom(), reference(), reference(), String.t(), pid()) :: {:ok, list(), map()} | :error
  def recover(state, provider, backend, binding, authority, topic, owner_pid) when is_pid(owner_pid) do
    if Validation.scope?(provider, backend),
      do: Registry.recover(state, provider, backend, binding, authority, topic, owner_pid),
      else: :error
  end

  @spec subscription(map(), atom(), atom(), reference()) :: {:ok, String.t()} | {:error, atom()}
  def subscription(state, provider, backend, binding) do
    if Validation.scope?(provider, backend) and is_reference(binding), do: Registry.subscription(state, provider, backend, binding), else: {:error, :invalid_binding}
  end

  @spec bind(map(), atom(), atom(), reference(), map(), pid()) :: {map(), list(), map()}
  def bind(state, provider, backend, binding, opts, owner_pid) do
    if valid_transition?(state, provider, backend, binding, opts), do: Lifecycle.bind(state, provider, backend, binding, opts, owner_pid), else: {Snapshot.unavailable(provider, backend), [], state}
  end

  @spec confirm(map(), atom(), atom(), reference(), map()) :: {map(), map()}
  def confirm(state, provider, backend, binding, opts) do
    if valid_observation?(provider, backend, binding, opts) and Registry.authorized?(state, provider, backend, binding, Map.get(opts, :authority)) do
      {Registry.lookup(state, provider, backend, binding), state}
    else
      {Snapshot.unavailable(provider, backend), state}
    end
  end

  @spec replace(map(), atom(), atom(), reference(), map(), pid()) :: {map(), list(), map()}
  def replace(state, provider, backend, binding, opts, owner_pid) do
    if valid_observation?(provider, backend, binding, opts) and Registry.authorized?(state, provider, backend, binding, Map.get(opts, :authority)) do
      Lifecycle.replace(state, provider, backend, binding, opts, owner_pid)
    else
      {Snapshot.unavailable(provider, backend), [], state}
    end
  end

  @spec invalidate(map(), atom(), atom(), reference(), map(), pid()) :: {map(), list(), map()}
  def invalidate(state, provider, backend, binding, opts, owner_pid) do
    if valid_invalidation?(state, provider, backend, binding, opts) do
      {snapshot, change, topic, state} = Lifecycle.invalidate(state, provider, backend, binding, opts, owner_pid)
      {snapshot, add_change([], change, topic, snapshot), state}
    else
      {Snapshot.unavailable(provider, backend), [], state}
    end
  end

  @spec retire(map(), atom(), atom(), reference(), map(), pid()) :: {map(), list(), map()}
  def retire(state, provider, backend, binding, opts, owner_pid) do
    if valid_invalidation?(state, provider, backend, binding, opts) do
      {snapshot, change, topic, state} = Lifecycle.invalidate(state, provider, backend, binding, opts, owner_pid)
      {snapshot, add_change([], change, topic, snapshot), Registry.retire(state, Registry.key(provider, backend, binding), snapshot)}
    else
      {Snapshot.unavailable(provider, backend), [], state}
    end
  end

  @spec owner_down(map(), reference()) :: {list(), map()}
  defdelegate owner_down(state, monitor), to: Tombstones, as: :retire_monitored

  defp valid_transition?(state, provider, backend, binding, opts) do
    valid_observation?(provider, backend, binding, opts) and
      Registry.authorized_transition?(state, provider, backend, binding, opts)
  end

  defp valid_invalidation?(state, provider, backend, binding, opts) do
    valid_observation?(provider, backend, binding, opts) and Validation.invalidation_reason?(Map.get(opts, :reason)) and
      Registry.authorized?(state, provider, backend, binding, Map.get(opts, :authority))
  end

  defp valid_observation?(provider, backend, binding, opts), do: Validation.observation?(provider, backend, binding, opts)
  defp add_change(changes, nil, _topic, _snapshot), do: changes
  defp add_change(changes, change, topic, snapshot), do: [{topic, snapshot, change} | changes]
  defp mint_generation, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp mint_topic, do: "provider-account-generation:" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
end
