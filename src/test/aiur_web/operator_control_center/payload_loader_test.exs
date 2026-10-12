defmodule AiurWeb.OperatorControlCenter.PayloadLoaderTest do
  use Aiur.TestSupport

  alias AiurWeb.{ControlCenterCache, Endpoint}
  alias AiurWeb.OperatorControlCenter.PayloadLoader

  setup context do
    previous = Application.get_env(:aiur, Endpoint)
    counter = :counters.new(1, [])
    cache = start_supervised!({ControlCenterCache, name: nil})

    Application.put_env(
      :aiur,
      Endpoint,
      Keyword.merge(previous || [],
        server: false,
        secret_key_base: String.duplicate("s", 64),
        control_center_cache: if(context[:missing_cache], do: :missing_payload_cache, else: cache),
        # Past the cache's load timeout, so the slow provider still overruns the
        # whole load; the default budget would degrade only its own surface.
        control_center_provider_budget_ms: 60_000,
        units_fleet_fun: fn ->
          :counters.add(counter, 1, 1)
          Process.sleep(10_000)
          %{}
        end
      )
    )

    on_exit(fn -> Application.put_env(:aiur, Endpoint, previous) end)
    Aiur.TestSupport.start_owned_endpoint!()
    %{counter: counter}
  end

  @tag missing_cache: true
  test "cache exit returns an unavailable dashboard without uncached provider reads", %{counter: counter} do
    for mode <- [:cached, {:event, MapSet.new([:change])}] do
      payload = PayloadLoader.load(mode)
      assert payload.stale == true
      assert payload.fleet.error.code == "snapshot_unavailable"
      assert payload.provider_health.fleet == :unavailable
      assert payload.retained_counts.health.status == :unavailable
    end

    assert :counters.get(counter, 1) == 0
  end

  @tag timeout: 15_000
  test "slow cached load returns unavailable without starting an uncached retry", %{counter: counter} do
    started = System.monotonic_time(:millisecond)
    payload = PayloadLoader.load(:fresh)
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert payload.stale == true
    assert payload.cache_error == :timeout
    assert payload.fleet.error.code == "snapshot_unavailable"
    assert :counters.get(counter, 1) == 1
  end
end
