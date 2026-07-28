defmodule Aiur.ProviderMeterProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.ProviderMeterProjection
  alias Aiur.ProviderMeterSnapshot

  @now ~U[2026-07-27 12:00:00Z]

  setup do
    name = :"projection_#{System.unique_integer([:positive])}"
    # No PubSub subscription: the tests deliver observations directly so they
    # do not need the app's PubSub running.
    {:ok, pid} = ProviderMeterProjection.start_link(name: name, subscribe?: false, clock: fn -> @now end)
    %{projection: name, pid: pid}
  end

  test "a provider with no observation reads as unknown, not as zero", %{projection: projection} do
    view = ProviderMeterProjection.provider_view(projection, :claude)

    assert view.state == :unknown
    assert view.observed_at == nil
    assert view.age_seconds == nil
    assert view.windows == %{}
    assert view.health.failure == :no_observation
  end

  test "an accepted observation becomes readable with its age", %{projection: projection, pid: pid} do
    send(pid, {:provider_meter_changed, snapshot(:claude, ~U[2026-07-27 11:58:00Z], %{"5h" => %{used_percent: 42}})})

    view = ProviderMeterProjection.provider_view(projection, :claude)

    assert view.state == :observed
    assert view.observed_at == ~U[2026-07-27 11:58:00Z]
    assert view.age_seconds == 120
    assert view.windows == %{"5h" => %{used_percent: 42}}
  end

  # The projection exists so a value survives the session that observed it —
  # that is precisely when an operator opens a surface to decide what to run.
  test "an observation stays readable after its session ends", %{projection: projection, pid: pid} do
    send(pid, {:provider_meter_changed, snapshot(:codex, ~U[2026-07-27 11:00:00Z])})

    view = ProviderMeterProjection.provider_view(projection, :codex)

    assert view.state == :observed
    assert view.age_seconds == 3_600
  end

  test "providers project independently", %{projection: projection, pid: pid} do
    send(pid, {:provider_meter_changed, snapshot(:claude, ~U[2026-07-27 11:59:00Z])})

    views = ProviderMeterProjection.snapshot(projection)

    assert views.claude.state == :observed
    assert views.codex.state == :unknown
  end

  # PubSub delivery order is not guaranteed, so a late-arriving older
  # observation must not overwrite a newer one.
  test "an older observation never displaces a newer one", %{projection: projection, pid: pid} do
    send(pid, {:provider_meter_changed, snapshot(:claude, ~U[2026-07-27 11:59:00Z])})
    send(pid, {:provider_meter_changed, snapshot(:claude, ~U[2026-07-27 11:00:00Z])})

    assert ProviderMeterProjection.provider_view(projection, :claude).observed_at == ~U[2026-07-27 11:59:00Z]
  end

  test "the projection carries no account generation", %{projection: projection, pid: pid} do
    send(pid, {:provider_meter_changed, snapshot(:claude, ~U[2026-07-27 11:59:00Z])})

    view = ProviderMeterProjection.provider_view(projection, :claude)

    refute Map.has_key?(view, :provider_account_generation)

    assert view |> inspect() |> String.contains?("gen-secret-1") == false,
           "the opaque account generation must not reach a consumer view"
  end

  test "an unavailable projection degrades to unknown rather than raising" do
    views = ProviderMeterProjection.snapshot(:"never_started_#{System.unique_integer([:positive])}")

    assert views.claude.state == :unknown
    assert views.codex.state == :unknown
  end

  defp snapshot(provider, observed_at, windows \\ %{}) do
    %ProviderMeterSnapshot{
      provider: provider,
      backend: :app_server,
      provider_account_generation: "gen-secret-1",
      observed_at: observed_at,
      auth_mode: :subscription,
      freshness: :fresh,
      health: %{state: :healthy, failure: nil, last_observed_at: observed_at, last_source_version: 1},
      windows: windows
    }
  end
end
