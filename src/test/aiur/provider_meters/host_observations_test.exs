defmodule Aiur.ProviderMeters.HostObservationsTest do
  use ExUnit.Case, async: false

  alias Aiur.ProviderMeters.HostObservations

  @now ~U[2026-09-27 12:10:00Z]

  setup do
    server = start_supervised!({HostObservations, name: nil, clock: fn -> @now end})
    %{server: server}
  end

  test "a host observation is display-only and never carries a trusted generation", %{server: server} do
    {:ok, scope} = HostObservations.attach(server, :codex, :app_server, self())
    assert :ok = HostObservations.observe(server, scope, observation(scope, ~U[2026-09-27 12:05:00Z], 117))

    view = HostObservations.provider_view(server, :codex)
    snapshot = HostObservations.redacted_snapshot(server, :codex)

    assert view.state == :observed
    assert view.identity_scope == :host_unverified
    assert view.age_seconds == 300
    assert view.windows["window.current"].used_percent == 117
    assert view.windows["window.weekly"].used_percent == 55
    refute Map.has_key?(view, :host_scope)
    assert snapshot.identity_scope == :host_unverified
    assert snapshot.provider_account_generation == nil
    assert snapshot.auth_mode == :unknown
  end

  test "concurrent hosts select one whole constrained snapshot and retire independently", %{server: server} do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    :ok = HostObservations.subscribe()

    {:ok, first} = HostObservations.attach(server, :codex, :app_server, self())
    {:ok, second} = HostObservations.attach(server, :codex, :app_server, owner)
    assert :ok = HostObservations.observe(server, first, observation(first, ~U[2026-09-27 12:03:00Z], 10))
    assert_receive {:host_meter_changed, :codex}, 1000
    assert :ok = HostObservations.observe(server, second, observation(second, ~U[2026-09-27 12:07:00Z], 80))
    assert_receive {:host_meter_changed, :codex}, 1000

    assert HostObservations.provider_view(server, :codex).windows["window.current"].used_percent == 80

    Process.exit(owner, :kill)
    assert_receive {:host_meter_changed, :codex}, 1000
    assert HostObservations.provider_view(server, :codex).windows["window.current"].used_percent == 10
    assert {:error, :unknown_scope} = HostObservations.observe(server, second, observation(second, @now, 99))
    assert :ok = HostObservations.retire(server, first)
    assert_receive {:host_meter_changed, :codex}, 1000
    assert HostObservations.provider_view(server, :codex).state == :unknown
  end

  test "the most constrained host wins even when the lower reading was observed later", %{server: server} do
    {:ok, first} = HostObservations.attach(server, :codex, :app_server, self())
    {:ok, second} = HostObservations.attach(server, :codex, :app_server, self())
    assert :ok = HostObservations.observe(server, first, observation(first, ~U[2026-09-27 12:03:00Z], 94))
    assert :ok = HostObservations.observe(server, second, observation(second, ~U[2026-09-27 12:07:00Z], 33))
    assert HostObservations.provider_view(server, :codex).windows["window.current"].used_percent == 94
  end

  test "stale and wrong-scope writes cannot replace the active observation", %{server: server} do
    {:ok, scope} = HostObservations.attach(server, :codex, :app_server, self())
    assert :ok = HostObservations.observe(server, scope, observation(scope, ~U[2026-09-27 12:05:00Z], 24))

    assert {:error, :stale_observation} =
             HostObservations.observe(server, scope, observation(scope, ~U[2026-09-27 12:04:00Z], 99))

    assert {:error, :invalid_unverified_observation} =
             HostObservations.observe(server, scope, observation(make_ref(), @now, 99))

    assert {:error, :invalid_unverified_observation} =
             HostObservations.observe(server, scope, %{observation(scope, @now, 99) | identity: :account})

    assert HostObservations.provider_view(server, :codex).windows["window.current"].used_percent == 24
  end

  test "same-host probe failure preserves values but marks them stale", %{server: server} do
    {:ok, scope} = HostObservations.attach(server, :codex, :app_server, self())
    assert :ok = HostObservations.observe(server, scope, observation(scope, ~U[2026-09-27 12:05:00Z], 33))
    assert :ok = HostObservations.fail(server, scope, :timeout, @now)

    view = HostObservations.provider_view(server, :codex)
    assert view.windows["window.current"].used_percent == 33
    assert view.windows["window.current"].freshness == :stale
    assert view.freshness == :stale
    assert view.health.failure == :timeout
    assert view.health.state == :stale
    assert view.age_seconds == 300
  end

  test "first probe failure is visible as unavailable without inventing a reading", %{server: server} do
    {:ok, scope} = HostObservations.attach(server, :codex, :app_server, self())
    assert :ok = HostObservations.fail(server, scope, :timeout, @now)

    view = HostObservations.provider_view(server, :codex)
    assert view.state == :unknown
    assert view.identity_scope == :host_unverified
    assert view.health.failure == :timeout
    assert view.health.last_attempt_at == @now
    assert view.windows == %{}
    assert view.observed_at == nil
  end

  test "an older failed read cannot stale a newer observation", %{server: server} do
    {:ok, scope} = HostObservations.attach(server, :codex, :app_server, self())
    assert :ok = HostObservations.observe(server, scope, observation(scope, ~U[2026-09-27 12:05:00Z], 33))
    assert {:error, :stale_observation} = HostObservations.fail(server, scope, :timeout, ~U[2026-09-27 12:04:00Z])

    view = HostObservations.provider_view(server, :codex)
    assert view.freshness == :fresh
    assert view.health.failure == nil
  end

  test "future observation is refused and no value is fabricated", %{server: server} do
    {:ok, scope} = HostObservations.attach(server, :codex, :app_server, self())

    assert {:error, :future_observation} =
             HostObservations.observe(server, scope, observation(scope, ~U[2026-09-27 12:12:00Z], 30))

    assert HostObservations.provider_view(server, :codex).state == :unknown
  end

  defp observation(scope, observed_at, current_percent) do
    %{
      identity: :unverified,
      host_scope: scope,
      observed_at: observed_at,
      auth_mode: :unknown,
      tier: :pro,
      windows: [
        %{
          limit_id: "window.current",
          kind: :rate_limit,
          name: :primary,
          source: :provider,
          observed_at: observed_at,
          used_percent: current_percent,
          resets_at: ~U[2026-09-27 13:00:00Z],
          coverage: :supported
        },
        %{
          limit_id: "window.weekly",
          kind: :rate_limit,
          name: :secondary,
          source: :provider,
          observed_at: observed_at,
          used_percent: 55,
          resets_at: ~U[2026-10-04 12:00:00Z],
          coverage: :supported
        }
      ]
    }
  end
end
