defmodule Aiur.ProviderMeters.HostProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.ProviderMeterProjection
  alias Aiur.ProviderMeters.HostObservations

  test "descriptor selects a live host view for all shared surfaces and retires it" do
    now = DateTime.utc_now()
    {:ok, hosts} = HostObservations.start_link(name: nil, clock: fn -> now end)
    {:ok, projection} = ProviderMeterProjection.start_link(name: nil, subscribe?: false, host_observations: hosts)

    on_exit(fn ->
      for pid <- [projection, hosts], Process.alive?(pid), do: GenServer.stop(pid)
    end)

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
