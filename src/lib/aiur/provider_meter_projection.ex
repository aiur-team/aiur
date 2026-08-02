defmodule Aiur.ProviderMeterProjection do
  @moduledoc """
  The consumer-facing read model for Codex and Claude meter facts.

  Every meter observation is minted against an opaque account-generation
  binding, and those bindings live in the observing session's process
  dictionary — they are per-session capabilities that die with the session.
  There is therefore no daemon-wide binding a consumer could resolve, which is
  why the dashboard's binding-scoped read has always degraded to the
  unknown-identity snapshot.

  This projection closes that gap from the other side. It accumulates accepted
  observations pushed by `Aiur.ProviderMeters`, retains the most recent one per
  provider, and serves a view with the account generation projected out. A
  consumer needs no binding and never holds a capability, so the dashboard, CLI
  and TUI can all read the same shape.

  Retention is deliberate: an observation stays readable after its session ends,
  carrying the time it was observed so a surface can name its age. A provider
  that has never been observed is `:unknown` — distinct from one observed to be
  at zero.
  """

  use GenServer

  alias Aiur.ProviderMeters.Events
  alias Aiur.ProviderMeterSnapshot

  # Registry-derived at compile time (a literal list, so the `in @providers`
  # guards below still inline) — a new metered backend projects with no edit.
  @providers Aiur.CodingAgent.provider_families()
  @backend :app_server
  @call_timeout 5_000

  @type provider :: atom()

  @type view :: %{
          provider: provider(),
          state: :observed | :unknown,
          observed_at: DateTime.t() | nil,
          age_seconds: non_neg_integer() | nil,
          auth_mode: :subscription | :api_key | :unknown,
          plan: map() | nil,
          freshness: :fresh | :partial | :stale | :unknown,
          health: map(),
          windows: %{String.t() => map()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker, restart: :permanent, shutdown: 5_000}
  end

  @doc """
  The identity-free projection for every provider, keyed by provider.

  Returns the unknown view for every provider when the projection is not
  running, so a consumer surface degrades to "not observed" rather than
  crashing.
  """
  @spec snapshot(GenServer.server()) :: %{provider() => view()}
  def snapshot(server \\ __MODULE__) do
    if GenServer.whereis(server) do
      GenServer.call(server, :snapshot, @call_timeout)
    else
      unknown_views()
    end
  catch
    :exit, _reason -> unknown_views()
  end

  @doc """
  The projection for one provider. Never raises; unknown when unavailable.

  Deliberately not an arity overload of `snapshot/1`: a provider atom is also a
  valid process name, so `snapshot(:codex)` would silently read a *server*
  named `:codex` and return every provider's view instead of failing.
  """
  @spec provider_view(GenServer.server(), provider()) :: view()
  def provider_view(server \\ __MODULE__, provider) when provider in @providers do
    server |> snapshot() |> Map.fetch!(provider)
  end

  @doc """
  The retained observation as a `ProviderMeterSnapshot` with the account
  generation projected out, for consumers that already speak that struct.

  A provider with no observation yields the explicit unknown snapshot, which is
  what the surfaces already render as "not observed".
  """
  @spec redacted_snapshot(GenServer.server(), provider()) :: ProviderMeterSnapshot.t()
  def redacted_snapshot(server \\ __MODULE__, provider) when provider in @providers do
    if GenServer.whereis(server) do
      GenServer.call(server, {:redacted_snapshot, provider}, @call_timeout)
    else
      ProviderMeterSnapshot.unknown(provider, @backend)
    end
  catch
    :exit, _reason -> ProviderMeterSnapshot.unknown(provider, @backend)
  end

  @doc false
  @spec providers() :: [provider()]
  def providers, do: @providers

  @impl true
  def init(opts) do
    _ = if Keyword.get(opts, :subscribe?, true), do: Events.subscribe_observed()

    {:ok, %{observations: %{}, clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    now = state.clock.()
    views = Map.new(@providers, fn provider -> {provider, view(Map.get(state.observations, provider), provider, now)} end)

    {:reply, views, state}
  end

  def handle_call({:redacted_snapshot, provider}, _from, state) do
    reply =
      case Map.get(state.observations, provider) do
        nil -> ProviderMeterSnapshot.unknown(provider, @backend)
        snapshot -> %{snapshot | provider_account_generation: nil}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:provider_meter_changed, %ProviderMeterSnapshot{provider: provider} = snapshot}, state)
      when provider in @providers do
    {:noreply, %{state | observations: retain(state.observations, provider, snapshot)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # An observation with no observed_at cannot be aged, and an older observation
  # must never displace a newer one — broadcast order is not guaranteed.
  defp retain(observations, provider, snapshot) do
    case {Map.get(observations, provider), snapshot.observed_at} do
      {_previous, nil} -> observations
      {nil, _observed_at} -> Map.put(observations, provider, snapshot)
      {previous, observed_at} -> put_if_newer(observations, provider, previous, snapshot, observed_at)
    end
  end

  defp put_if_newer(observations, provider, previous, snapshot, observed_at) do
    case previous.observed_at do
      nil -> Map.put(observations, provider, snapshot)
      prior -> if DateTime.compare(observed_at, prior) == :lt, do: observations, else: Map.put(observations, provider, snapshot)
    end
  end

  defp view(nil, provider, _now), do: unknown_view(provider)

  defp view(%ProviderMeterSnapshot{} = snapshot, provider, now) do
    %{
      provider: provider,
      state: :observed,
      observed_at: snapshot.observed_at,
      age_seconds: age_seconds(snapshot.observed_at, now),
      auth_mode: snapshot.auth_mode,
      plan: snapshot.plan,
      freshness: snapshot.freshness,
      health: snapshot.health,
      windows: snapshot.windows
    }
  end

  defp age_seconds(nil, _now), do: nil
  defp age_seconds(observed_at, now), do: now |> DateTime.diff(observed_at) |> max(0)

  defp unknown_views, do: Map.new(@providers, &{&1, unknown_view(&1)})

  defp unknown_view(provider) do
    %{
      provider: provider,
      state: :unknown,
      observed_at: nil,
      age_seconds: nil,
      auth_mode: :unknown,
      plan: nil,
      freshness: :unknown,
      health: %{state: :unavailable, failure: :no_observation, last_observed_at: nil, last_source_version: nil},
      windows: %{}
    }
  end

  @doc false
  @spec backend() :: :app_server
  def backend, do: @backend
end
