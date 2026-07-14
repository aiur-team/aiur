defmodule Aiur.ProviderAccountGeneration.Lifecycle do
  @moduledoc false

  alias Aiur.ProviderAccountGeneration.{Monitor, Registry, Snapshot, Validation}

  @spec bind(map(), atom(), atom(), reference(), map(), pid()) :: {map(), list(), map()}
  def bind(state, provider, backend, binding, opts, owner_pid) do
    entry_key = Registry.key(provider, backend, binding)

    case Registry.entry(state, entry_key) do
      %{snapshot: %{generation: generation} = snapshot} = entry when is_binary(generation) ->
        if Validation.same_binding_continuity?(opts),
          do: {snapshot, [], state},
          else: replace_known(state, entry_key, provider, backend, opts, owner_pid, entry, :rotated)

      _ ->
        bind_new(state, entry_key, provider, backend, binding, opts, owner_pid)
    end
  end

  @spec replace(map(), atom(), atom(), reference(), map(), pid()) :: {map(), list(), map()}
  def replace(state, provider, backend, binding, opts, owner_pid) do
    entry_key = Registry.key(provider, backend, binding)
    {entry, state} = Registry.ensure(state, provider, backend, binding)
    change = if is_binary(entry.snapshot.generation), do: :rotated, else: :bound
    replace_known(state, entry_key, provider, backend, opts, owner_pid, entry, change)
  end

  @spec invalidate(map(), atom(), atom(), reference(), map(), pid()) :: {map(), atom() | nil, String.t(), map()}
  def invalidate(state, provider, backend, binding, opts, owner_pid) do
    entry_key = Registry.key(provider, backend, binding)
    {entry, state} = Registry.ensure(state, provider, backend, binding)
    {snapshot, change} = Snapshot.invalidated(entry.snapshot, provider, backend, Map.fetch!(opts, :source), Map.fetch!(opts, :reason), state.clock.())
    updated = entry |> Map.put(:snapshot, snapshot) |> Map.put(:auth_mode, nil) |> Monitor.owner(owner_pid)
    {snapshot, change, updated.topic, Registry.put(state, entry_key, updated)}
  end

  defp bind_new(state, entry_key, provider, backend, binding, opts, owner_pid) do
    previous_binding = Map.get(opts, :previous_binding)

    cond do
      is_reference(previous_binding) and previous_binding != binding and
          Validation.continuity?(opts, previous_binding) ->
        continue_known(state, entry_key, provider, backend, previous_binding, opts, owner_pid)

      is_reference(previous_binding) and previous_binding != binding ->
        {snapshot, change, topic, state} = invalidate(state, provider, backend, previous_binding, %{source: Map.fetch!(opts, :source), reason: :continuity_lost}, owner_pid)
        {current, changes, state} = create_known(state, entry_key, provider, backend, opts, owner_pid, :bound)
        {current, add_change(changes, change, topic, snapshot), state}

      true ->
        create_known(state, entry_key, provider, backend, opts, owner_pid, :bound)
    end
  end

  defp continue_known(state, entry_key, provider, backend, previous_binding, opts, owner_pid) do
    previous_key = Registry.key(provider, backend, previous_binding)

    case Registry.entry(state, previous_key) do
      %{snapshot: %{generation: generation}} when is_binary(generation) ->
        {previous, change, topic, state} =
          invalidate(state, provider, backend, previous_binding, %{source: Map.fetch!(opts, :source), reason: :continuity_lost}, owner_pid)

        {snapshot, changes, state} =
          create_known(state, entry_key, provider, backend, opts, owner_pid, :continued, generation)

        {snapshot, add_change(changes, change, topic, previous), state}

      _ ->
        create_known(state, entry_key, provider, backend, opts, owner_pid, :bound)
    end
  end

  defp create_known(state, entry_key, provider, backend, opts, owner_pid, change, generation \\ nil) do
    binding = elem(entry_key, 2)
    {entry, state} = Registry.ensure(state, provider, backend, binding)
    snapshot = Snapshot.known(provider, backend, generation || state.mint.(), Map.fetch!(opts, :source), state.clock.())
    updated = entry |> Map.put(:snapshot, snapshot) |> Map.put(:auth_mode, Map.get(opts, :auth_mode)) |> Monitor.owner(owner_pid)
    {snapshot, [{updated.topic, snapshot, change}], Registry.put(state, entry_key, updated)}
  end

  defp replace_known(state, entry_key, provider, backend, opts, owner_pid, entry, change) do
    snapshot = Snapshot.known(provider, backend, state.mint.(), Map.fetch!(opts, :source), state.clock.())
    updated = entry |> Map.put(:snapshot, snapshot) |> Map.put(:auth_mode, Map.get(opts, :auth_mode)) |> Monitor.owner(owner_pid)
    {snapshot, [{updated.topic, snapshot, change}], Registry.put(state, entry_key, updated)}
  end

  defp add_change(changes, nil, _topic, _snapshot), do: changes
  defp add_change(changes, change, topic, snapshot), do: [{topic, snapshot, change} | changes]
end
