defmodule Aiur.ProviderMeters.HostSnapshot do
  @moduledoc false

  alias Aiur.CodingAgent
  alias Aiur.ProviderMeters.{Input, Reconciler}
  alias Aiur.ProviderMeterSnapshot

  @stale_after_seconds 600
  @max_future_skew_seconds 60

  @spec observe(map(), reference(), map(), DateTime.t()) :: {:ok, ProviderMeterSnapshot.t()} | {:error, atom()}
  def observe(host, scope, observation, now) do
    with {:ok, update} <- normalize(host, scope, observation),
         :ok <- valid_time(update.observed_at, now) do
      case Reconciler.apply(host.snapshot, Map.put(update, :provider_account_generation, nil), now) do
        {:updated, snapshot} -> {:ok, %{snapshot | identity_scope: :host_unverified, provider_account_generation: nil}}
        {:ignored, _snapshot} -> {:error, :stale_observation}
      end
    end
  end

  @spec fail(map(), reference(), atom(), DateTime.t(), DateTime.t()) :: {:ok, ProviderMeterSnapshot.t()} | {:error, atom()}
  def fail(host, scope, reason, attempted_at, now) do
    with {:ok, _failure} <- validate_failure(host, scope, reason, attempted_at),
         :ok <- valid_time(attempted_at, now),
         :ok <- newer_failure(host.snapshot, attempted_at) do
      snapshot = host.snapshot || unknown(host.provider, host.backend)
      health = %{snapshot.health | failure: reason, last_attempt_at: attempted_at, consecutive_failures: snapshot.health.consecutive_failures + 1}
      {:ok, %{snapshot | health: health, identity_scope: :host_unverified}}
    end
  end

  @spec select(map(), atom(), DateTime.t()) :: ProviderMeterSnapshot.t()
  def select(hosts, provider, now) do
    snapshots = for {_scope, %{provider: ^provider, snapshot: %ProviderMeterSnapshot{} = snapshot, order: order}} <- hosts, do: {snapshot, order}
    observed = Enum.filter(snapshots, fn {snapshot, _order} -> not is_nil(snapshot.observed_at) end)
    candidates = if observed == [], do: snapshots, else: observed

    selected =
      Enum.max_by(candidates, fn {snapshot, order} -> {used_percent(snapshot), DateTime.to_unix(snapshot.observed_at || snapshot.health.last_attempt_at, :microsecond), order} end, fn -> nil end)

    project(selected, provider, now)
  end

  defp used_percent(snapshot) do
    snapshot.windows |> Map.values() |> Enum.map(&Map.get(&1, :used_percent)) |> Enum.filter(&is_number/1) |> Enum.max(fn -> -1 end)
  end

  @spec unknown(atom(), atom() | nil) :: ProviderMeterSnapshot.t()
  def unknown(provider, backend \\ nil) do
    ProviderMeterSnapshot.unknown(provider, backend || CodingAgent.provider_meter_backend(provider))
  end

  defp normalize(host, scope, %{identity: :unverified, host_scope: scope, observed_at: observed_at, windows: windows} = observation) do
    Input.normalize(%{
      schema_version: 1,
      update_kind: :snapshot,
      provider: host.provider,
      backend: host.backend,
      account_generation_binding: scope,
      auth_mode: :unknown,
      observed_at: observed_at,
      source: :provider,
      source_version: 1,
      windows: windows,
      plan: plan(observation)
    })
  end

  defp normalize(_host, _scope, _observation), do: {:error, :invalid_unverified_observation}

  defp plan(%{tier: tier, observed_at: observed_at}) when is_atom(tier), do: %{tier: tier, source: :provider, observed_at: observed_at}
  defp plan(_observation), do: nil

  defp validate_failure(host, scope, reason, attempted_at) do
    Input.normalize_failure(%{
      schema_version: 1,
      provider: host.provider,
      backend: host.backend,
      account_generation_binding: scope,
      reason: reason,
      observed_at: attempted_at
    })
  end

  defp valid_time(observed_at, now) do
    if DateTime.diff(observed_at, now) <= @max_future_skew_seconds, do: :ok, else: {:error, :future_observation}
  end

  defp newer_failure(nil, _attempted_at), do: :ok

  defp newer_failure(snapshot, attempted_at) do
    latest = snapshot.health.last_attempt_at || snapshot.observed_at

    if is_nil(latest) or DateTime.compare(attempted_at, latest) == :gt,
      do: :ok,
      else: {:error, :stale_observation}
  end

  defp project(nil, provider, _now), do: unknown(provider)

  defp project({snapshot, _order}, _provider, now) do
    if is_nil(snapshot.observed_at), do: %{snapshot | identity_scope: :host_unverified}, else: project_observed(snapshot, now)
  end

  defp project_observed(snapshot, now) do
    age = max(DateTime.diff(now, snapshot.observed_at), 0)
    stale? = age > @stale_after_seconds or not is_nil(snapshot.health.failure)
    freshness = if(stale?, do: :stale, else: :fresh)
    windows = Map.new(snapshot.windows, fn {id, window} -> {id, Map.put(window, :freshness, freshness)} end)
    health = %{snapshot.health | state: if(stale?, do: :stale, else: :healthy)}
    %{snapshot | age_seconds: age, freshness: freshness, windows: windows, health: health, provider_account_generation: nil, identity_scope: :host_unverified}
  end
end
