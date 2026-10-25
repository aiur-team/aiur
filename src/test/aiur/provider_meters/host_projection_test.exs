defmodule Aiur.ProviderMeters.HostProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.ProviderMeterProjection
  alias Aiur.ProviderMeters.HostObservations

  # Supervised, not linked: a linked server dies with the test process's
  # :shutdown exit while on_exit is still checking Process.alive?/stopping it.
  defp start_meters(now) do
    hosts = start_supervised!({HostObservations, name: nil, clock: fn -> now end})
    projection = start_supervised!({ProviderMeterProjection, name: nil, subscribe?: false, host_observations: hosts})
    {hosts, projection}
  end

  test "meter servers outlive the test process exit until the test supervisor stops them" do
    {hosts, projection} = start_meters(DateTime.utc_now())
    {:links, links} = Process.info(self(), :links)

    refute hosts in links
    refute projection in links
  end

  test "descriptor selects a live host view for all shared surfaces and retires it" do
    now = DateTime.utc_now()
    {hosts, projection} = start_meters(now)

    assert {:ok, scope} = HostObservations.attach(hosts, :muse, :app_server, self())
    observed_at = DateTime.add(now, -17, :second)

    fact = %{
      identity: :unverified,
      host_scope: scope,
      observed_at: observed_at,
      auth_mode: :unknown,
      windows: [
        %{limit_id: "muse.current", kind: :rate_limit, name: :current, source: :provider, observed_at: observed_at, used_percent: 123.5, coverage: :supported},
        %{limit_id: "muse.weekly", kind: :rate_limit, name: :weekly, source: :provider, observed_at: observed_at, used_percent: 18, coverage: :supported}
      ]
    }

    assert :ok = HostObservations.observe(hosts, scope, fact)

    assert %{muse: %{state: :observed, identity_scope: :host_unverified, age_seconds: 17} = view} =
             ProviderMeterProjection.snapshot(projection)

    assert view.windows["muse.current"].used_percent == 123.5
    assert view.windows["muse.current"].name == "Current"
    assert view.windows["muse.weekly"].name == "Weekly"
    snapshot = ProviderMeterProjection.redacted_snapshot(projection, :muse)
    assert snapshot.identity_scope == :host_unverified
    assert snapshot.provider_account_generation == nil
    assert snapshot.windows["muse.current"].used_percent == 123.5
    assert :ok = HostObservations.retire(hosts, scope)
    assert %{state: :unknown, windows: windows} = ProviderMeterProjection.provider_view(projection, :muse)
    assert windows == %{}
  end
end
