defmodule Aiur.ProviderAccountGeneration do
  @moduledoc """
  Owns opaque local account generations for trusted provider auth bindings.

  A binding is a local process capability, not an account identifier. The
  owner retains only the capability, a random generation, and a private PubSub
  topic. Account payloads, credentials, and provider identifiers never enter
  state, events, logs, or the public lookup contract.
  """

  use GenServer

  @pubsub Aiur.PubSub
  @schema_version 1

  @trusted_sources %{
    codex: [:codex_app_server],
    claude: [:claude_app_server]
  }

  @supported_auth_modes ~w(apikey chatgpt chatgptAuthTokens headers agentIdentity personalAccessToken bedrockApiKey)

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
    safe_call(server, {:lookup, provider, backend, binding}, unavailable_snapshot(provider, backend))
  end

  @spec bind(provider(), backend(), binding(), keyword()) :: {:ok, snapshot()}
  def bind(provider, backend, binding, opts \\ []), do: bind(__MODULE__, provider, backend, binding, opts)

  @spec bind(GenServer.server(), provider(), backend(), binding(), keyword()) :: {:ok, snapshot()}
  def bind(server, provider, backend, binding, opts) when is_list(opts) do
    safe_call(server, {:bind, provider, backend, binding, Map.new(opts)}, {:ok, unavailable_snapshot(provider, backend)})
  end

  @spec replace(provider(), backend(), binding(), keyword()) :: {:ok, snapshot()}
  def replace(provider, backend, binding, opts \\ []), do: replace(__MODULE__, provider, backend, binding, opts)

  @spec replace(GenServer.server(), provider(), backend(), binding(), keyword()) :: {:ok, snapshot()}
  def replace(server, provider, backend, binding, opts) when is_list(opts) do
    safe_call(server, {:replace, provider, backend, binding, Map.new(opts)}, {:ok, unavailable_snapshot(provider, backend)})
  end

  @spec confirm(provider(), backend(), binding(), keyword()) :: {:ok, snapshot()}
  def confirm(provider, backend, binding, opts \\ []), do: confirm(__MODULE__, provider, backend, binding, opts)

  @spec confirm(GenServer.server(), provider(), backend(), binding(), keyword()) :: {:ok, snapshot()}
  def confirm(server, provider, backend, binding, opts) when is_list(opts) do
    safe_call(server, {:confirm, provider, backend, binding, Map.new(opts)}, {:ok, unavailable_snapshot(provider, backend)})
  end

  @spec invalidate(provider(), backend(), binding(), keyword()) :: {:ok, snapshot()}
  def invalidate(provider, backend, binding, opts \\ []), do: invalidate(__MODULE__, provider, backend, binding, opts)

  @spec invalidate(GenServer.server(), provider(), backend(), binding(), keyword()) :: {:ok, snapshot()}
  def invalidate(server, provider, backend, binding, opts) when is_list(opts) do
    safe_call(server, {:invalidate, provider, backend, binding, Map.new(opts)}, {:ok, unavailable_snapshot(provider, backend)})
  end

  @doc "Subscribe the caller to change events for one exact trusted binding."
  @spec subscribe(provider(), backend(), binding()) :: :ok | {:error, term()}
  def subscribe(provider, backend, binding), do: subscribe(__MODULE__, provider, backend, binding)

  @spec subscribe(GenServer.server(), provider(), backend(), binding()) :: :ok | {:error, term()}
  def subscribe(server, provider, backend, binding) do
    case safe_call(server, {:subscription_topic, provider, backend, binding}, {:error, :owner_unavailable}) do
      {:ok, topic} ->
        case Process.whereis(@pubsub) do
          pid when is_pid(pid) -> Phoenix.PubSub.subscribe(@pubsub, topic)
          _ -> :ok
        end

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       entries: %{},
       mint: Keyword.get(opts, :mint, &mint_generation/0),
       topic_mint: Keyword.get(opts, :topic_mint, &mint_topic/0),
       clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)
     }}
  end

  @impl true
  def handle_call({:lookup, provider, backend, binding}, _from, state) do
    {:reply, lookup_entry(state.entries, provider, backend, binding), state}
  end

  def handle_call({:subscription_topic, provider, backend, binding}, _from, state) do
    if valid_scope?(provider, backend) and is_reference(binding) do
      {entry, state} = ensure_entry(state, provider, backend, binding)
      {:reply, {:ok, entry.topic}, state}
    else
      {:reply, {:error, :invalid_binding}, state}
    end
  end

  def handle_call({:bind, provider, backend, binding, opts}, from, state) do
    if valid_observation?(provider, backend, binding, opts) do
      {snapshot, changes, state} = bind_entry(state, provider, backend, binding, opts, caller_pid(from))
      broadcast_changes(changes)
      {:reply, {:ok, snapshot}, state}
    else
      {:reply, {:ok, unavailable_snapshot(provider, backend)}, state}
    end
  end

  def handle_call({:confirm, provider, backend, binding, opts}, _from, state) do
    if valid_observation?(provider, backend, binding, opts) do
      {:reply, {:ok, lookup_entry(state.entries, provider, backend, binding)}, state}
    else
      {:reply, {:ok, unavailable_snapshot(provider, backend)}, state}
    end
  end

  def handle_call({:replace, provider, backend, binding, opts}, from, state) do
    if valid_observation?(provider, backend, binding, opts) do
      {snapshot, changes, state} = replace_entry(state, provider, backend, binding, opts, caller_pid(from))
      broadcast_changes(changes)
      {:reply, {:ok, snapshot}, state}
    else
      {:reply, {:ok, unavailable_snapshot(provider, backend)}, state}
    end
  end

  def handle_call({:invalidate, provider, backend, binding, opts}, _from, state) do
    if valid_observation?(provider, backend, binding, opts) and valid_invalidation_reason?(Map.get(opts, :reason)) do
      {snapshot, change, topic, state} = invalidate_entry(state, provider, backend, binding, opts)
      changes = maybe_add_change([], change, topic, snapshot)
      broadcast_changes(changes)
      {:reply, {:ok, snapshot}, state}
    else
      {:reply, {:ok, unavailable_snapshot(provider, backend)}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {changes, entries} = invalidate_monitored_entries(state.entries, monitor, state.clock)
    broadcast_changes(changes)
    {:noreply, %{state | entries: entries}}
  end

  defp bind_entry(state, provider, backend, binding, opts, owner_pid) do
    key = entry_key(provider, backend, binding)

    case Map.get(state.entries, key) do
      %{snapshot: %{generation: generation} = snapshot, auth_mode: existing_mode} = entry when is_binary(generation) ->
        if same_auth_mode?(existing_mode, Map.get(opts, :auth_mode)) do
          {snapshot, [], state}
        else
          replace_known_entry(state, key, provider, backend, opts, owner_pid, entry, :rotated)
        end

      _ ->
        bind_new_entry(state, key, provider, backend, binding, opts, owner_pid)
    end
  end

  defp bind_new_entry(state, key, provider, backend, binding, opts, owner_pid) do
    previous_binding = Map.get(opts, :previous_binding)

    cond do
      is_reference(previous_binding) and previous_binding != binding and proven_continuity?(opts, previous_binding) ->
        continue_known_entry(state, key, provider, backend, previous_binding, opts, owner_pid)

      is_reference(previous_binding) and previous_binding != binding ->
        {changes, state} = invalidate_previous_binding(state, provider, backend, previous_binding, opts)
        {snapshot, new_changes, state} = create_known_entry(state, key, provider, backend, opts, owner_pid, :bound)
        {snapshot, changes ++ new_changes, state}

      true ->
        create_known_entry(state, key, provider, backend, opts, owner_pid, :bound)
    end
  end

  defp continue_known_entry(state, key, provider, backend, previous_binding, opts, owner_pid) do
    previous_key = entry_key(provider, backend, previous_binding)

    case Map.get(state.entries, previous_key) do
      %{snapshot: %{generation: generation}} when is_binary(generation) ->
        {previous_unknown, old_change, old_topic, state} =
          invalidate_entry(state, provider, backend, previous_binding, %{source: Map.fetch!(opts, :source), reason: :continuity_lost})

        {snapshot, new_changes, state} =
          create_known_entry(state, key, provider, backend, opts, owner_pid, :continued, generation)

        changes = maybe_add_change([], old_change, old_topic, previous_unknown) ++ new_changes
        {snapshot, changes, state}

      _ ->
        create_known_entry(state, key, provider, backend, opts, owner_pid, :bound)
    end
  end

  defp create_known_entry(state, key, provider, backend, opts, owner_pid, change, generation \\ nil) do
    binding = elem(key, 2)
    {entry, state} = ensure_entry(state, provider, backend, binding)

    snapshot =
      known_snapshot(
        provider,
        backend,
        generation || state.mint.(),
        Map.fetch!(opts, :source),
        state.clock.()
      )

    entry =
      entry
      |> Map.put(:snapshot, snapshot)
      |> Map.put(:auth_mode, Map.get(opts, :auth_mode))
      |> monitor_owner(owner_pid)

    state = put_entry(state, key, entry)
    {snapshot, [{entry.topic, snapshot, change}], state}
  end

  defp replace_entry(state, provider, backend, binding, opts, owner_pid) do
    key = entry_key(provider, backend, binding)
    {entry, state} = ensure_entry(state, provider, backend, binding)
    change = if is_binary(entry.snapshot.generation), do: :rotated, else: :bound
    replace_known_entry(state, key, provider, backend, opts, owner_pid, entry, change)
  end

  defp replace_known_entry(state, key, provider, backend, opts, owner_pid, entry, change) do
    snapshot = known_snapshot(provider, backend, state.mint.(), Map.fetch!(opts, :source), state.clock.())

    entry =
      entry
      |> Map.put(:snapshot, snapshot)
      |> Map.put(:auth_mode, Map.get(opts, :auth_mode))
      |> monitor_owner(owner_pid)

    state = put_entry(state, key, entry)
    {snapshot, [{entry.topic, snapshot, change}], state}
  end

  defp invalidate_previous_binding(state, provider, backend, previous_binding, opts) do
    {snapshot, change, topic, state} =
      invalidate_entry(state, provider, backend, previous_binding, %{
        source: Map.fetch!(opts, :source),
        reason: :continuity_lost
      })

    {maybe_add_change([], change, topic, snapshot), state}
  end

  defp invalidate_entry(state, provider, backend, binding, opts) do
    key = entry_key(provider, backend, binding)
    {entry, state} = ensure_entry(state, provider, backend, binding)

    snapshot = unknown_snapshot(provider, backend, Map.fetch!(opts, :source), Map.fetch!(opts, :reason), state.clock.())
    change = if is_binary(entry.snapshot.generation), do: :invalidated, else: nil
    entry = %{entry | snapshot: snapshot, auth_mode: nil}
    state = put_entry(state, key, entry)
    {snapshot, change, entry.topic, state}
  end

  defp invalidate_monitored_entries(entries, monitor, clock) do
    Enum.reduce(entries, {[], %{}}, fn {key, entry}, {changes, updated_entries} ->
      case entry.monitor do
        {^monitor, _owner_pid} when is_binary(entry.snapshot.generation) ->
          {provider, backend, _binding} = key
          snapshot = unknown_snapshot(provider, backend, entry.snapshot.source, :continuity_lost, clock.())
          updated_entry = %{entry | snapshot: snapshot, auth_mode: nil, monitor: nil}
          {[{entry.topic, snapshot, :invalidated} | changes], Map.put(updated_entries, key, updated_entry)}

        {^monitor, _owner_pid} ->
          {changes, Map.put(updated_entries, key, %{entry | monitor: nil})}

        _ ->
          {changes, Map.put(updated_entries, key, entry)}
      end
    end)
  end

  defp ensure_entry(state, provider, backend, binding) do
    key = entry_key(provider, backend, binding)

    case Map.get(state.entries, key) do
      nil ->
        entry = %{
          snapshot: unknown_snapshot(provider, backend, :unavailable, :never_observed, nil),
          topic: state.topic_mint.(),
          auth_mode: nil,
          monitor: nil
        }

        {entry, put_entry(state, key, entry)}

      entry ->
        {entry, state}
    end
  end

  defp lookup_entry(entries, provider, backend, binding) do
    case Map.get(entries, entry_key(provider, backend, binding)) do
      %{snapshot: snapshot} -> snapshot
      _ -> unknown_snapshot(provider, backend, :unavailable, :never_observed, nil)
    end
  end

  defp put_entry(state, key, entry), do: %{state | entries: Map.put(state.entries, key, entry)}

  defp entry_key(provider, backend, binding), do: {provider, backend, binding}

  defp monitor_owner(entry, owner_pid) when is_pid(owner_pid) do
    case entry.monitor do
      {_monitor, ^owner_pid} ->
        entry

      {monitor, _other_owner} ->
        Process.demonitor(monitor, [:flush])
        %{entry | monitor: {Process.monitor(owner_pid), owner_pid}}

      nil ->
        %{entry | monitor: {Process.monitor(owner_pid), owner_pid}}
    end
  end

  defp caller_pid({pid, _tag}) when is_pid(pid), do: pid

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

  defp unavailable_snapshot(provider, backend), do: unknown_snapshot(provider, backend, :unavailable, :owner_unavailable, nil)

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
    valid_scope?(provider, backend) and is_reference(binding) and trusted_source?(provider, Map.get(opts, :source)) and
      valid_auth_mode?(Map.get(opts, :auth_mode))
  end

  defp valid_scope?(provider, :app_server), do: provider in [:codex, :claude]
  defp valid_scope?(_provider, _backend), do: false

  defp trusted_source?(provider, source), do: source in Map.get(@trusted_sources, provider, [])
  defp valid_auth_mode?(nil), do: true
  defp valid_auth_mode?(auth_mode), do: auth_mode in @supported_auth_modes

  defp valid_invalidation_reason?(reason) do
    reason in [
      :logout,
      :credential_replaced,
      :account_replaced,
      :backend_replaced,
      :continuity_lost,
      :no_authenticated_account,
      :unsupported_auth_mode,
      :untrusted_lifecycle
    ]
  end

  defp proven_continuity?(opts, previous_binding) do
    Map.get(opts, :continuity) == :proven and Map.get(opts, :previous_binding) == previous_binding
  end

  defp same_auth_mode?(nil, _incoming), do: true
  defp same_auth_mode?(_existing, nil), do: true
  defp same_auth_mode?(mode, mode), do: true
  defp same_auth_mode?(_existing, _incoming), do: false

  defp maybe_add_change(changes, nil, _topic, _snapshot), do: changes
  defp maybe_add_change(changes, change, topic, snapshot), do: changes ++ [{topic, snapshot, change}]

  defp broadcast_changes(changes) do
    Enum.each(changes, fn {topic, snapshot, change} ->
      case Process.whereis(@pubsub) do
        pid when is_pid(pid) and is_binary(topic) ->
          event = Map.put(snapshot, :change, change)
          Phoenix.PubSub.broadcast(@pubsub, topic, {:provider_account_generation_changed, event})

        _ ->
          :ok
      end
    end)
  end

  defp safe_call(server, message, fallback) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> fallback
  end

  defp mint_generation do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp mint_topic do
    "provider-account-generation:" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end
end
