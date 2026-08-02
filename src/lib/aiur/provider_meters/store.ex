defmodule Aiur.ProviderMeters.Store do
  @moduledoc false

  use GenServer

  alias Aiur.{CodingAgent, ProviderAccountGeneration, ProviderMeterSnapshot}
  alias Aiur.ProviderMeters.{Events, Input, Reconciler}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec ingest(GenServer.server(), map()) :: {:ok, ProviderMeterSnapshot.t()} | {:error, atom()}
  def ingest(server, input), do: GenServer.call(server, {:ingest, input})

  @spec record_failure(GenServer.server(), map()) :: {:ok, ProviderMeterSnapshot.t()} | {:error, atom()}
  def record_failure(server, input), do: GenServer.call(server, {:failure, input})

  @spec snapshot(GenServer.server(), atom(), :app_server, reference() | map()) :: ProviderMeterSnapshot.t()
  def snapshot(server, provider, backend, binding), do: GenServer.call(server, {:snapshot, provider, backend, binding})

  @spec subscription_generation(GenServer.server(), atom(), :app_server, reference() | map()) ::
          {:ok, String.t()} | {:error, :unknown_account_generation}
  def subscription_generation(server, provider, backend, binding) do
    GenServer.call(server, {:subscription_generation, provider, backend, binding})
  end

  @spec generation(GenServer.server()) :: non_neg_integer()
  def generation(server), do: GenServer.call(server, :generation)

  @impl true
  def init(opts) do
    {:ok,
     %{
       projections: %{},
       generation: 0,
       clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
       account_generation_owner: Keyword.get(opts, :account_generation_owner, ProviderAccountGeneration)
     }}
  end

  @impl true
  def handle_call({:ingest, input}, _from, state) do
    case normalize_update(input, state) do
      {:ok, update} ->
        key = key(update)
        {outcome, snapshot} = Reconciler.apply(Map.get(state.projections, key), update, now(state))
        {state, snapshot} = maybe_store(state, key, snapshot, outcome == :updated)
        {:reply, {:ok, snapshot}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:failure, input}, _from, state) do
    case normalize_failure(input, state) do
      {:ok, failure} ->
        key = key(failure)
        {outcome, snapshot} = Reconciler.failure(Map.get(state.projections, key), failure, now(state))
        {state, snapshot} = maybe_store(state, key, snapshot, outcome == :updated)
        {:reply, {:ok, snapshot}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:snapshot, provider, backend, binding}, _from, state) do
    case resolve_generation(state, provider, backend, binding) do
      {:ok, generation} ->
        {state, snapshot} = refreshed_snapshot(state, provider, backend, generation)
        {:reply, snapshot, state}

      {:error, _reason} ->
        {:reply, ProviderMeterSnapshot.unknown(provider, backend), state}
    end
  end

  def handle_call({:subscription_generation, provider, backend, binding}, _from, state) do
    {:reply, resolve_generation(state, provider, backend, binding), state}
  end

  def handle_call(:generation, _from, state), do: {:reply, state.generation, state}

  defp normalize_update(input, state) do
    with {:ok, update} <- Input.normalize(input),
         {:ok, generation} <-
           resolve_generation(
             state,
             update.provider,
             update.backend,
             update.account_generation_binding
           ) do
      {:ok, update |> Map.delete(:account_generation_binding) |> Map.put(:provider_account_generation, generation)}
    end
  end

  defp normalize_failure(input, state) do
    with {:ok, failure} <- Input.normalize_failure(input),
         {:ok, generation} <-
           resolve_generation(
             state,
             failure.provider,
             failure.backend,
             failure.account_generation_binding
           ) do
      {:ok, failure |> Map.delete(:account_generation_binding) |> Map.put(:provider_account_generation, generation)}
    end
  end

  defp resolve_generation(state, provider, backend, binding) do
    with %{backends: backends} when is_list(backends) <- CodingAgent.provider_account_generation(provider),
         true <- backend in backends,
         %{generation: generation, freshness: :current, health: :healthy} when is_binary(generation) <-
           ProviderAccountGeneration.lookup(state.account_generation_owner, provider, backend, binding) do
      {:ok, generation}
    else
      _ -> {:error, :unknown_account_generation}
    end
  end

  defp refreshed_snapshot(state, provider, backend, generation) do
    key = {provider, backend, generation}

    case Map.get(state.projections, key) do
      nil ->
        {state, ProviderMeterSnapshot.empty(provider, backend, generation)}

      snapshot ->
        snapshot = Reconciler.refresh(snapshot, now(state))
        maybe_store(state, key, snapshot, snapshot != Map.get(state.projections, key))
    end
  end

  defp maybe_store(state, _key, snapshot, false), do: {state, snapshot}

  defp maybe_store(state, key, snapshot, true) do
    generation = state.generation + 1
    snapshot = %{snapshot | projection_generation: generation}
    state = %{state | projections: Map.put(state.projections, key, snapshot), generation: generation}
    :ok = Events.broadcast(snapshot)
    {state, snapshot}
  end

  defp key(%{
         provider: provider,
         backend: backend,
         provider_account_generation: generation
       }),
       do: {provider, backend, generation}

  defp now(%{clock: clock}), do: clock.()
end
