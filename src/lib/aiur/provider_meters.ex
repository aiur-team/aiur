defmodule Aiur.ProviderMeters do
  @moduledoc """
  Canonical provider-neutral account meter projection.

  Provider adapters submit content-free observations through `ingest/1`.
  The canonical store validates each mutation and resolves its exact opaque
  account generation before accepting, retaining, or broadcasting it.
  """

  alias Aiur.ProviderMeterProbe
  alias Aiur.ProviderMeterProjection
  alias Aiur.ProviderMeters.{Events, HostObservations, ProbeCrash, Store}
  alias Aiur.ProviderMeterSnapshot

  @type provider :: atom()
  @type backend :: atom()

  @spec ingest(map()) :: {:ok, ProviderMeterSnapshot.t()} | {:error, atom()}
  def ingest(update), do: Store.ingest(Store, update)

  @spec record_failure(map()) :: {:ok, ProviderMeterSnapshot.t()} | {:error, atom()}
  def record_failure(failure), do: Store.record_failure(Store, failure)

  @doc "Build the typed snapshot contract for a provider observation."
  @spec observation_snapshot(map()) :: ProviderMeterSnapshot.t()
  def observation_snapshot(attributes) when is_map(attributes),
    do: struct!(ProviderMeterSnapshot, attributes)

  @spec snapshot(provider(), backend(), reference() | map()) :: ProviderMeterSnapshot.t()
  def snapshot(provider, backend, binding), do: Store.snapshot(Store, provider, backend, binding)

  @spec lookup(provider(), backend(), reference() | map()) :: ProviderMeterSnapshot.t()
  def lookup(provider, backend, binding), do: snapshot(provider, backend, binding)

  @spec health(provider(), backend(), reference() | map()) :: ProviderMeterSnapshot.health()
  def health(provider, backend, binding), do: snapshot(provider, backend, binding).health

  @spec freshness(provider(), backend(), reference() | map()) ::
          :fresh | :partial | :stale | :unknown
  def freshness(provider, backend, binding), do: snapshot(provider, backend, binding).freshness

  @spec generation() :: non_neg_integer()
  def generation, do: Store.generation(Store)

  @spec subscribe(provider(), backend(), reference() | map()) :: :ok | {:error, term()}
  def subscribe(provider, backend, binding) do
    with {:ok, generation} <- Store.subscription_generation(Store, provider, backend, binding) do
      Events.subscribe(provider, backend, generation)
    end
  end

  @doc "Broadcast a provider meter snapshot to generation-scoped subscribers."
  @spec broadcast_snapshot(ProviderMeterSnapshot.t()) :: :ok
  def broadcast_snapshot(snapshot), do: Events.broadcast(snapshot)

  @doc "Record an exception contained by a provider meter probe and return its failure reason."
  @spec log_probe_crash(atom(), atom(), term(), Exception.stacktrace()) :: :probe_crashed
  def log_probe_crash(provider, kind, error, stacktrace),
    do: ProbeCrash.log(provider, kind, error, stacktrace)

  @doc "Run the registered account-session probe for one provider."
  @spec probe_session(atom(), String.t(), keyword()) :: ProviderMeterProbe.outcome()
  def probe_session(provider, backend, opts), do: ProviderMeterProbe.probe_session(provider, backend, opts)

  @doc "Read the Claude usage endpoint for one provider."
  @spec probe_usage_api(atom(), String.t(), keyword()) :: ProviderMeterProbe.outcome()
  def probe_usage_api(provider, backend, opts), do: ProviderMeterProbe.probe_usage_api(provider, backend, opts)

  @doc "Return the retained display projection for one provider."
  @spec provider_view(ProviderMeterProjection.provider()) :: ProviderMeterProjection.view()
  def provider_view(provider), do: ProviderMeterProjection.provider_view(provider)

  @doc "Attach a live host to the display-only, unverified meter projection."
  @spec attach_host(atom(), atom(), pid(), GenServer.server()) ::
          {:ok, reference()} | {:error, atom()}
  def attach_host(provider, backend, owner, server \\ __MODULE__) do
    case host_server(server) do
      HostObservations = host_server ->
        HostObservations.attach(host_server, provider, backend, owner)

      test_server ->
        test_server.attach(provider, backend, owner)
    end
  end

  @doc "Record an unverified observation for an attached host."
  @spec observe_host(reference(), map(), GenServer.server()) :: :ok | {:error, atom()}
  def observe_host(scope, observation, server \\ __MODULE__) do
    case host_server(server) do
      HostObservations = host_server -> HostObservations.observe(host_server, scope, observation)
      test_server -> test_server.observe(scope, observation)
    end
  end

  @doc "Record a failed read for an attached host."
  @spec fail_host(reference(), atom(), DateTime.t(), GenServer.server()) :: :ok | {:error, atom()}
  def fail_host(scope, reason, attempted_at \\ DateTime.utc_now(), server \\ __MODULE__) do
    case host_server(server) do
      HostObservations = host_server ->
        HostObservations.fail(host_server, scope, reason, attempted_at)

      test_server ->
        test_server.fail(scope, reason)
    end
  end

  @doc "Retire a host from the display-only meter projection."
  @spec retire_host(reference(), GenServer.server()) :: :ok | {:error, :unknown_scope}
  def retire_host(scope, server \\ __MODULE__) do
    case host_server(server) do
      HostObservations = host_server -> HostObservations.retire(host_server, scope)
      test_server -> test_server.retire(scope)
    end
  end

  defp host_server(__MODULE__), do: HostObservations
  defp host_server(nil), do: HostObservations
  defp host_server(server), do: server
end
