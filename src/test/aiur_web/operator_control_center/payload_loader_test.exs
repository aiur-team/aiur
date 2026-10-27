defmodule AiurWeb.OperatorControlCenter.PayloadLoaderTest do
  use Aiur.TestSupport

  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.{ControlCenterCache, Endpoint}
  alias AiurWeb.OperatorControlCenter.PayloadLoader

  setup context do
    previous = Application.get_env(:aiur, Endpoint)
    test = self()
    cache = start_supervised!({ControlCenterCache, [name: nil, load_timeout_ms: 100]})

    Application.put_env(
      :aiur,
      Endpoint,
      (previous || [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        control_center_cache: if(context[:missing_cache], do: :missing_payload_cache, else: cache),
        # Past the injected cache timeout, forcing its unavailable-load path.
        control_center_provider_budget_ms: 60_000,
        # Endpoint config is global, so other processes' dashboard loads can reach
        # this fun too; `$callers` tells which load started each read (#4892).
        units_fleet_fun: fn ->
          send(test, {:fleet_read, Process.get(:"$callers", [])})

          receive do
            :never_release -> %{}
          end
        end
      )
      |> EndpointStubs.scope()
    )

    on_exit(fn -> Application.put_env(:aiur, Endpoint, previous) end)
    Aiur.TestSupport.start_owned_endpoint!()
    %{cache: cache}
  end

  @tag missing_cache: true
  test "cache exit returns an unavailable dashboard without uncached provider reads" do
    for mode <- [:cached, {:event, MapSet.new([:change])}] do
      payload = PayloadLoader.load(mode)
      assert payload.stale == true
      assert payload.fleet.error.code == "snapshot_unavailable"
      assert payload.provider_health.fleet == :unavailable
      assert payload.retained_counts.health.status == :unavailable
    end

    test = self()
    refute_received {:fleet_read, [^test | _]}
  end

  test "slow cached load returns unavailable without starting an uncached retry", %{cache: cache} do
    payload_task = Task.async(fn -> PayloadLoader.load(:fresh) end)
    assert_receive {:fleet_read, [_loader, ^cache | _]}, 1_000
    payload = Task.await(payload_task, 1_000)
    assert payload.stale == true
    assert payload.cache_error == :timeout
    assert payload.fleet.error.code == "snapshot_unavailable"
    # The bounded read runs in a task of the loader task the cache started.
    test = self()
    refute_received {:fleet_read, [^test | _]}
  end
end
