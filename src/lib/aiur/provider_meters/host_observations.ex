defmodule Aiur.ProviderMeters.HostObservations do
  @moduledoc """
  Display-only meter observations scoped to live provider host processes.

  This owner never mints an account generation or writes ProviderMeters.Store.
  Each host has a separate complete snapshot; concurrent hosts are never merged.
  A host's monitor removes its observation when the process ends.
  """

  use GenServer

  alias Aiur.CodingAgent
  alias Aiur.ProviderMeters.HostSnapshot
  alias Aiur.ProviderMeterSnapshot

  @call_timeout 5_000
  @topic "provider_meters:host_observed"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Subscribe to redacted host-meter change signals for display refresh."
  @spec subscribe() :: :ok | {:error, :subscription_unavailable}
  def subscribe do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)
    else
      {:error, :subscription_unavailable}
    end
  end

  @doc "Mint an in-memory capability for one live host and monitor its owner."
  @spec attach(GenServer.server(), atom(), atom(), pid()) :: {:ok, reference()} | {:error, atom()}
  def attach(server \\ __MODULE__, provider, backend, owner) do
    GenServer.call(server, {:attach, provider, backend, owner}, @call_timeout)
  end

  @doc "Accept a complete unverified observation from this exact host scope."
  @spec observe(GenServer.server(), reference(), map()) :: :ok | {:error, atom()}
  def observe(server \\ __MODULE__, scope, observation) do
    GenServer.call(server, {:observe, scope, observation}, @call_timeout)
  end

  @doc "Record a failed read while retaining this live host's last observation."
  @spec fail(GenServer.server(), reference(), atom(), DateTime.t()) :: :ok | {:error, atom()}
  def fail(server \\ __MODULE__, scope, reason, attempted_at \\ DateTime.utc_now()) do
    GenServer.call(server, {:fail, scope, reason, attempted_at}, @call_timeout)
  end

  @doc "Retire a host before its process exits, such as on credential replacement."
  @spec retire(GenServer.server(), reference()) :: :ok | {:error, :unknown_scope}
  def retire(server \\ __MODULE__, scope) do
    GenServer.call(server, {:retire, scope}, @call_timeout)
  end

  @doc "A redacted snapshot with no account generation or host capability."
  @spec redacted_snapshot(GenServer.server(), atom()) :: ProviderMeterSnapshot.t()
  def redacted_snapshot(server \\ __MODULE__, provider) do
    if GenServer.whereis(server) do
      GenServer.call(server, {:snapshot, provider}, @call_timeout)
    else
      HostSnapshot.unknown(provider)
    end
  catch
    :exit, _reason -> HostSnapshot.unknown(provider)
  end

  @doc "The shared surface view, labeled as unverified when observed."
  @spec provider_view(GenServer.server(), atom()) :: map()
  def provider_view(server \\ __MODULE__, provider) do
    snapshot = redacted_snapshot(server, provider)

    %{
      provider: provider,
      state: if(snapshot.observed_at, do: :observed, else: :unknown),
      identity_scope: snapshot.identity_scope,
      observed_at: snapshot.observed_at,
      age_seconds: snapshot.age_seconds,
      auth_mode: snapshot.auth_mode,
      plan: snapshot.plan,
      freshness: snapshot.freshness,
      health: snapshot.health,
      windows: snapshot.windows
    }
  end

  @impl true
  def init(opts), do: {:ok, %{hosts: %{}, clock: Keyword.get(opts, :clock, &DateTime.utc_now/0), next_order: 0}}

  @impl true
  def handle_call({:attach, provider, backend, owner}, _from, state) do
    if is_pid(owner) and Process.alive?(owner) and valid_backend?(provider, backend) do
      scope = make_ref()
      host = %{provider: provider, backend: backend, owner: owner, monitor: Process.monitor(owner), snapshot: nil, order: state.next_order}
      {:reply, {:ok, scope}, %{state | hosts: Map.put(state.hosts, scope, host), next_order: state.next_order + 1}}
    else
      {:reply, {:error, :invalid_host}, state}
    end
  end

  def handle_call({:observe, scope, observation}, _from, state) do
    with {:ok, host} <- host(state, scope),
         {:ok, snapshot} <- HostSnapshot.observe(host, scope, observation, state.clock.()) do
      notify(host.provider)
      {:reply, :ok, put_in(state.hosts[scope].snapshot, snapshot)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fail, scope, reason, attempted_at}, _from, state) do
    with {:ok, host} <- host(state, scope),
         {:ok, snapshot} <- HostSnapshot.fail(host, scope, reason, attempted_at, state.clock.()) do
      notify(host.provider)
      {:reply, :ok, put_in(state.hosts[scope].snapshot, snapshot)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:retire, scope}, _from, state) do
    case Map.pop(state.hosts, scope) do
      {nil, _hosts} ->
        {:reply, {:error, :unknown_scope}, state}

      {host, hosts} ->
        Process.demonitor(host.monitor, [:flush])
        notify(host.provider)
        {:reply, :ok, %{state | hosts: hosts}}
    end
  end

  def handle_call({:snapshot, provider}, _from, state) do
    {:reply, HostSnapshot.select(state.hosts, provider, state.clock.()), state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, state) do
    for {_scope, %{monitor: ^monitor, provider: provider}} <- state.hosts, do: notify(provider)
    hosts = Map.reject(state.hosts, fn {_scope, host} -> host.monitor == monitor end)
    {:noreply, %{state | hosts: hosts}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp host(state, scope) when is_reference(scope) do
    case Map.fetch(state.hosts, scope) do
      {:ok, host} -> {:ok, host}
      :error -> {:error, :unknown_scope}
    end
  end

  defp host(_state, _scope), do: {:error, :unknown_scope}

  defp valid_backend?(provider, backend) do
    provider in CodingAgent.provider_families() and backend == CodingAgent.provider_meter_backend(provider)
  end

  defp notify(provider) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, {:host_meter_changed, provider})
    end

    :ok
  end
end
