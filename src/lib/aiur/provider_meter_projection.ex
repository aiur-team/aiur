defmodule Aiur.ProviderMeterProjection do
  @moduledoc """
  The consumer-facing read model for registry-declared provider meter facts.

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
  @call_timeout 5_000
  @default_probe_interval_seconds 300
  @stale_after_intervals 2
  @stale_after_failures 2

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
    if GenServer.whereis(server) do
      GenServer.call(server, {:provider_view, provider}, @call_timeout)
    else
      unknown_view(provider)
    end
  catch
    :exit, _reason -> unknown_view(provider)
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
      ProviderMeterSnapshot.unknown(provider, backend(provider))
    end
  catch
    :exit, _reason -> ProviderMeterSnapshot.unknown(provider, backend(provider))
  end

  @doc "Record the result of a provider probe, including failed attempts."
  @spec record_probe_result(GenServer.server(), map(), DateTime.t()) :: :ok
  def record_probe_result(server \\ __MODULE__, outcome, attempted_at \\ DateTime.utc_now()) do
    if GenServer.whereis(server) do
      GenServer.call(server, {:probe_result, outcome, attempted_at}, @call_timeout)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec providers() :: [provider()]
  def providers, do: @providers

  @impl true
  def init(opts) do
    _ = if Keyword.get(opts, :subscribe?, true), do: Events.subscribe_observed()

    {:ok,
     %{
       observations: %{},
       probe_statuses: %{},
       clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
       probe_interval_seconds: Keyword.get(opts, :probe_interval_seconds, configured_probe_interval_seconds())
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    now = state.clock.()

    views =
      Map.new(@providers, fn provider ->
        {provider, view(Map.get(state.observations, provider), provider, now, Map.get(state.probe_statuses, provider), state)}
      end)

    {:reply, views, state}
  end

  def handle_call({:provider_view, provider}, _from, state) when provider in @providers do
    {:reply, view(Map.get(state.observations, provider), provider, state.clock.(), Map.get(state.probe_statuses, provider), state), state}
  end

  def handle_call({:redacted_snapshot, provider}, _from, state) do
    snapshot = Map.get(state.observations, provider) || ProviderMeterSnapshot.unknown(provider, backend(provider))
    reply = snapshot |> Map.put(:provider_account_generation, nil) |> project_snapshot(provider, state.clock.(), Map.get(state.probe_statuses, provider), state)

    {:reply, reply, state}
  end

  def handle_call({:probe_result, %{provider: provider, observed?: observed?, reason: reason}, attempted_at}, _from, state)
      when provider in @providers and is_boolean(observed?) and is_struct(attempted_at, DateTime) do
    previous = Map.get(state.probe_statuses, provider, %{last_attempt_at: nil, failure: nil, consecutive_failures: 0})

    status =
      if observed? do
        %{last_attempt_at: attempted_at, failure: nil, consecutive_failures: 0}
      else
        %{
          last_attempt_at: attempted_at,
          failure: reason || :no_observation,
          consecutive_failures: previous.consecutive_failures + 1
        }
      end

    state = %{state | probe_statuses: Map.put(state.probe_statuses, provider, status)}

    if observed? do
      {:reply, :ok, state}
    else
      snapshot = Map.get(state.observations, provider) || ProviderMeterSnapshot.unknown(provider, backend(provider))
      snapshot = project_snapshot(snapshot, provider, state.clock.(), status, state)
      :ok = Events.broadcast_from(self(), snapshot)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:provider_meter_changed, %ProviderMeterSnapshot{provider: provider} = snapshot}, state)
      when provider in @providers do
    {:noreply,
     %{
       state
       | observations: retain(state.observations, provider, snapshot),
         probe_statuses: recover_probe_status(state.probe_statuses, provider, snapshot.observed_at)
     }}
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
      nil ->
        Map.put(observations, provider, snapshot)

      prior ->
        if DateTime.compare(observed_at, prior) == :lt do
          observations
        else
          Map.put(observations, provider, merge_patch(previous, snapshot))
        end
    end
  end

  defp merge_patch(previous, %ProviderMeterSnapshot{update_kind: :patch} = incoming) do
    %{
      incoming
      | windows: Map.merge(previous.windows, incoming.windows),
        plan: incoming.plan || previous.plan
    }
  end

  defp merge_patch(_previous, incoming), do: incoming

  defp view(nil, provider, now, probe_status, state) do
    project_view(unknown_view(provider), nil, provider, now, probe_status, state)
  end

  defp view(%ProviderMeterSnapshot{} = snapshot, provider, now, probe_status, state) do
    project_view(
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
      },
      snapshot,
      provider,
      now,
      probe_status,
      state
    )
  end

  defp project_view(view, snapshot, _provider, _now, probe_status, state) do
    freshness = observation_freshness(snapshot, view.age_seconds, state.probe_interval_seconds)

    %{
      view
      | freshness: freshness,
        plan: project_plan(view.plan, freshness),
        windows: project_windows(view.windows, freshness),
        health: projected_health(view.health, snapshot, freshness, probe_status)
    }
  end

  defp project_snapshot(snapshot, provider, now, probe_status, state) do
    age = age_seconds(snapshot.observed_at, now)
    freshness = observation_freshness(snapshot, age, state.probe_interval_seconds)
    health = projected_health(snapshot.health, snapshot, freshness, probe_status)

    %{
      snapshot
      | provider: provider,
        age_seconds: age,
        freshness: freshness,
        health: health,
        windows: project_windows(snapshot.windows, freshness),
        plan: project_plan(snapshot.plan, freshness)
    }
  end

  defp project_windows(windows, :stale) when is_map(windows) do
    Map.new(windows, fn {limit_id, window} -> {limit_id, Map.put(window, :freshness, :stale)} end)
  end

  defp project_windows(windows, _freshness), do: windows

  defp project_plan(plan, :stale) when is_map(plan), do: Map.put(plan, :freshness, :stale)
  defp project_plan(plan, _freshness), do: plan

  defp observation_freshness(nil, _age_seconds, _interval_seconds), do: :unknown
  defp observation_freshness(%ProviderMeterSnapshot{observed_at: nil}, _age_seconds, _interval_seconds), do: :unknown

  defp observation_freshness(%ProviderMeterSnapshot{}, age_seconds, interval_seconds)
       when is_integer(age_seconds) and age_seconds > interval_seconds * @stale_after_intervals,
       do: :stale

  defp observation_freshness(%ProviderMeterSnapshot{freshness: freshness}, _age_seconds, _interval_seconds)
       when freshness in [:partial, :stale],
       do: freshness

  defp observation_freshness(%ProviderMeterSnapshot{}, _age_seconds, _interval_seconds), do: :fresh

  defp projected_health(health, snapshot, freshness, probe_status) do
    facts = probe_facts(health, probe_status)
    state = health_state(snapshot, freshness, facts)

    Map.merge(health, %{
      state: state,
      failure: facts.failure,
      last_observed_at: Map.get(health, :last_observed_at) || observed_at(snapshot),
      last_attempt_at: facts.last_attempt_at,
      consecutive_failures: facts.consecutive_failures
    })
  end

  defp probe_facts(health, nil) do
    %{
      failure: Map.get(health, :failure),
      last_attempt_at: Map.get(health, :last_attempt_at),
      consecutive_failures: Map.get(health, :consecutive_failures, 0),
      probe_failure?: false,
      adapter_failure?: not is_nil(Map.get(health, :failure))
    }
  end

  defp probe_facts(health, status) do
    status_failure = Map.get(status, :failure)

    %{
      failure: status_failure || Map.get(health, :failure),
      last_attempt_at: Map.get(status, :last_attempt_at) || Map.get(health, :last_attempt_at),
      consecutive_failures: Map.get(status, :consecutive_failures, 0),
      probe_failure?: not is_nil(status_failure),
      adapter_failure?: is_nil(status_failure) and not is_nil(Map.get(health, :failure))
    }
  end

  defp health_state(nil, _freshness, _facts), do: :unavailable
  defp health_state(%ProviderMeterSnapshot{observed_at: nil}, _freshness, _facts), do: :unavailable
  defp health_state(_snapshot, :stale, _facts), do: :stale
  defp health_state(_snapshot, _freshness, %{adapter_failure?: true}), do: :stale

  defp health_state(_snapshot, _freshness, %{probe_failure?: true, consecutive_failures: count})
       when count >= @stale_after_failures,
       do: :stale

  defp health_state(_snapshot, :partial, _facts), do: :partial
  defp health_state(_snapshot, :fresh, %{probe_failure?: true}), do: :partial
  defp health_state(_snapshot, :fresh, _facts), do: :healthy
  defp health_state(_snapshot, _freshness, facts), do: Map.get(facts, :state, :unavailable)

  defp observed_at(nil), do: nil
  defp observed_at(snapshot), do: snapshot.observed_at

  defp recover_probe_status(statuses, provider, observed_at) do
    case {Map.get(statuses, provider), observed_at} do
      {%{last_attempt_at: attempt}, %DateTime{} = observed_at} when is_struct(attempt, DateTime) ->
        if DateTime.compare(observed_at, attempt) != :lt do
          Map.put(statuses, provider, %{last_attempt_at: attempt, failure: nil, consecutive_failures: 0})
        else
          statuses
        end

      _ ->
        statuses
    end
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
      health: %{
        state: :unavailable,
        failure: :no_observation,
        last_observed_at: nil,
        last_source_version: nil,
        last_attempt_at: nil,
        consecutive_failures: 0
      },
      windows: %{}
    }
  end

  defp configured_probe_interval_seconds do
    case Aiur.Config.settings() do
      {:ok, %{polling: %{usage_interval_seconds: seconds}}} when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @default_probe_interval_seconds
    end
  rescue
    _error -> @default_probe_interval_seconds
  catch
    _kind, _reason -> @default_probe_interval_seconds
  end

  @doc false
  @spec backend() :: :app_server
  def backend, do: :app_server

  @doc false
  @spec backend(provider()) :: atom()
  def backend(provider), do: Aiur.CodingAgent.provider_meter_backend(provider)
end
