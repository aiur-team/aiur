defmodule Aiur.ProviderAccountGeneration do
  @moduledoc """
  Owns opaque local account generations for trusted provider auth bindings.

  The owner deliberately keeps continuity only in memory. A binding is a
  local, trusted process capability, not an account identifier; it is never
  returned or published. Callers can obtain a generation only by presenting
  the exact active binding that a trusted provider lifecycle adapter owns.
  """

  use GenServer

  @pubsub Aiur.PubSub
  @schema_version 1

  @trusted_sources %{
    codex: [:codex_app_server],
    claude: [:claude_app_server]
  }

  @type provider :: :codex | :claude
  @type backend :: :app_server
  @type binding :: reference()
  @type snapshot :: %{
          schema_version: pos_integer(),
          provider: provider(),
          backend: backend(),
          generation: String.t() | nil,
          source: atom(),
          freshness: :current | :unknown,
          health: :healthy | :unknown | :unavailable,
          reason: atom() | nil,
          observed_at: DateTime.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name) do
      GenServer.start_link(__MODULE__, opts)
    else
      GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec lookup(provider(), backend(), binding()) :: snapshot()
  def lookup(provider, backend, binding), do: lookup(__MODULE__, provider, backend, binding)

  @spec lookup(GenServer.server(), provider(), backend(), binding()) :: snapshot()
  def lookup(server, provider, backend, binding) do
    GenServer.call(server, {:lookup, provider, backend, binding})
  end

  @spec bind(provider(), backend(), binding(), keyword()) :: {:ok, snapshot()} | {:error, :invalid_observation}
  def bind(provider, backend, binding, opts \\ []), do: bind(__MODULE__, provider, backend, binding, opts)

  @spec bind(GenServer.server(), provider(), backend(), binding(), keyword()) :: {:ok, snapshot()} | {:error, :invalid_observation}
  def bind(server, provider, backend, binding, opts) when is_list(opts) do
    GenServer.call(server, {:bind, provider, backend, binding, Map.new(opts)})
  end

  @spec replace(provider(), backend(), binding(), keyword()) :: {:ok, snapshot()} | {:error, :invalid_observation}
  def replace(provider, backend, binding, opts \\ []), do: replace(__MODULE__, provider, backend, binding, opts)

  @spec replace(GenServer.server(), provider(), backend(), binding(), keyword()) :: {:ok, snapshot()} | {:error, :invalid_observation}
  def replace(server, provider, backend, binding, opts) when is_list(opts) do
    GenServer.call(server, {:replace, provider, backend, binding, Map.new(opts)})
  end

  @spec confirm(provider(), backend(), binding(), keyword()) :: {:ok, snapshot()} | {:error, :invalid_observation}
  def confirm(provider, backend, binding, opts \\ []), do: confirm(__MODULE__, provider, backend, binding, opts)

  @spec confirm(GenServer.server(), provider(), backend(), binding(), keyword()) :: {:ok, snapshot()} | {:error, :invalid_observation}
  def confirm(server, provider, backend, binding, opts) when is_list(opts) do
    GenServer.call(server, {:confirm, provider, backend, binding, Map.new(opts)})
  end

  @spec invalidate(provider(), backend(), binding(), keyword()) :: {:ok, snapshot()} | {:error, :invalid_observation}
  def invalidate(provider, backend, binding, opts \\ []), do: invalidate(__MODULE__, provider, backend, binding, opts)

  @spec invalidate(GenServer.server(), provider(), backend(), binding(), keyword()) ::
          {:ok, snapshot()} | {:error, :invalid_observation}
  def invalidate(server, provider, backend, binding, opts) when is_list(opts) do
    GenServer.call(server, {:invalidate, provider, backend, binding, Map.new(opts)})
  end

  @spec subscribe(provider(), backend()) :: :ok | {:error, term()}
  def subscribe(provider, backend) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) -> Phoenix.PubSub.subscribe(@pubsub, topic(provider, backend))
      _ -> :ok
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       entries: %{},
       mint: Keyword.get(opts, :mint, &mint_generation/0),
       clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)
     }}
  end

  @impl true
  def handle_call({:lookup, provider, backend, binding}, _from, state) do
    {:reply, lookup_entry(state.entries, provider, backend, binding), state}
  end

  def handle_call({:bind, provider, backend, binding, opts}, _from, state) do
    if valid_observation?(provider, backend, binding, opts) do
      {snapshot, change, state} = bind_entry(state, provider, backend, binding, opts)
      maybe_broadcast(snapshot, change)
      {:reply, {:ok, snapshot}, state}
    else
      {:reply, {:error, :invalid_observation}, state}
    end
  end

  def handle_call({:confirm, provider, backend, binding, opts}, _from, state) do
    if valid_observation?(provider, backend, binding, opts) do
      {:reply, {:ok, lookup_entry(state.entries, provider, backend, binding)}, state}
    else
      {:reply, {:error, :invalid_observation}, state}
    end
  end

  def handle_call({:replace, provider, backend, binding, opts}, _from, state) do
    if valid_observation?(provider, backend, binding, opts) do
      {snapshot, change, state} = replace_entry(state, provider, backend, binding, opts)
      maybe_broadcast(snapshot, change)
      {:reply, {:ok, snapshot}, state}
    else
      {:reply, {:error, :invalid_observation}, state}
    end
  end

  def handle_call({:invalidate, provider, backend, binding, opts}, _from, state) do
    if valid_observation?(provider, backend, binding, opts) and valid_invalidation_reason?(Map.get(opts, :reason)) do
      {snapshot, change, state} = invalidate_entry(state, provider, backend, binding, opts)
      maybe_broadcast(snapshot, change)
      {:reply, {:ok, snapshot}, state}
    else
      {:reply, {:error, :invalid_observation}, state}
    end
  end

  defp bind_entry(state, provider, backend, binding, opts) do
    key = entry_key(provider, backend, binding)

    case Map.get(state.entries, key) do
      %{snapshot: snapshot} ->
        {snapshot, nil, state}

      _ ->
        continue_or_bind(state, key, provider, backend, binding, opts)
    end
  end

  defp continue_or_bind(state, key, provider, backend, _binding, opts) do
    previous_binding = Map.get(opts, :previous_binding)

    case Map.get(state.entries, entry_key(provider, backend, previous_binding)) do
      %{snapshot: previous_snapshot} ->
        if is_reference(previous_binding) and proven_continuity?(opts, previous_binding) do
          snapshot =
            known_snapshot(provider, backend, previous_snapshot.generation, Map.fetch!(opts, :source), state.clock.())

          state =
            state
            |> delete_entry(provider, backend, previous_binding)
            |> put_entry(key, snapshot)

          {snapshot, :continued, state}
        else
          bind_new_generation(state, key, provider, backend, opts, :bound)
        end

      _ ->
        bind_new_generation(state, key, provider, backend, opts, :bound)
    end
  end

  defp bind_new_generation(state, key, provider, backend, opts, change) do
    snapshot = known_snapshot(provider, backend, state.mint.(), Map.fetch!(opts, :source), state.clock.())
    {snapshot, change, put_entry(state, key, snapshot)}
  end

  defp replace_entry(state, provider, backend, binding, opts) do
    key = entry_key(provider, backend, binding)
    change = if Map.has_key?(state.entries, key), do: :rotated, else: :bound
    bind_new_generation(state, key, provider, backend, opts, change)
  end

  defp invalidate_entry(state, provider, backend, binding, opts) do
    key = entry_key(provider, backend, binding)

    case Map.get(state.entries, key) do
      %{snapshot: _snapshot} ->
        snapshot = unknown_snapshot(provider, backend, Map.fetch!(opts, :source), Map.fetch!(opts, :reason), state.clock.())
        {snapshot, :invalidated, %{state | entries: Map.delete(state.entries, key)}}

      _ ->
        {unknown_snapshot(provider, backend, Map.fetch!(opts, :source), Map.fetch!(opts, :reason), state.clock.()), nil, state}
    end
  end

  defp put_entry(state, key, snapshot) do
    %{state | entries: Map.put(state.entries, key, %{snapshot: snapshot})}
  end

  defp lookup_entry(entries, provider, backend, binding) do
    key = entry_key(provider, backend, binding)

    case Map.get(entries, key) do
      %{snapshot: snapshot} -> snapshot
      _ -> unknown_snapshot(provider, backend, :unavailable, :no_trusted_binding, nil)
    end
  end

  defp delete_entry(state, provider, backend, binding) do
    %{state | entries: Map.delete(state.entries, entry_key(provider, backend, binding))}
  end

  defp entry_key(provider, backend, binding), do: {provider, backend, binding}

  defp known_snapshot(provider, backend, generation, source, observed_at) do
    %{
      schema_version: @schema_version,
      provider: provider,
      backend: backend,
      generation: generation,
      source: source,
      freshness: :current,
      health: :healthy,
      reason: nil,
      observed_at: observed_at
    }
  end

  defp unknown_snapshot(provider, backend, source, reason, observed_at) do
    %{
      schema_version: @schema_version,
      provider: provider,
      backend: backend,
      generation: nil,
      source: source,
      freshness: :unknown,
      health: if(source == :unavailable, do: :unavailable, else: :unknown),
      reason: reason,
      observed_at: observed_at
    }
  end

  defp valid_observation?(provider, backend, binding, opts) do
    valid_scope?(provider, backend) and is_reference(binding) and trusted_source?(provider, Map.get(opts, :source))
  end

  defp valid_scope?(provider, :app_server), do: provider in [:codex, :claude]
  defp valid_scope?(_provider, _backend), do: false

  defp trusted_source?(provider, source), do: source in Map.get(@trusted_sources, provider, [])

  defp valid_invalidation_reason?(reason), do: reason in [:logout, :credential_replaced, :account_replaced, :backend_replaced, :continuity_lost]

  defp proven_continuity?(opts, previous_binding) do
    Map.get(opts, :continuity) == :proven and Map.get(opts, :previous_binding) == previous_binding
  end

  defp maybe_broadcast(_snapshot, nil), do: :ok

  defp maybe_broadcast(snapshot, change) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        event = Map.put(snapshot, :change, change)
        Phoenix.PubSub.broadcast(@pubsub, topic(snapshot.provider, snapshot.backend), {:provider_account_generation_changed, event})

      _ ->
        :ok
    end
  end

  defp topic(provider, backend), do: "provider-account-generation:#{provider}:#{backend}"

  defp mint_generation do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end
end
