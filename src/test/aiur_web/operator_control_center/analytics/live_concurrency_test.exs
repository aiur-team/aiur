defmodule AiurWeb.OperatorControlCenter.Analytics.LiveConcurrencyTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.Analytics.LiveConcurrency
  alias AiurWeb.OperatorControlCenter.Analytics.Presenter

  @fixtures Path.expand("../../../fixtures/run_telemetry", __DIR__)

  test "counts adopted running entries and excludes paused entries" do
    running = [%{work_state: :working, adopted_from: "prior boot"} | Enum.map(1..10, &%{work_state: :working, adopted_from: "prior boot #{&1}"})]

    assert LiveConcurrency.count(running) == 11
    assert LiveConcurrency.count([%{work_state: :working}, %{work_state: :paused}]) == 1
  end

  test "live count keeps stale sample age visible and retained models say run end" do
    model = %{live_concurrency: 11, live_occupied: 12, live_concurrency_state: {:stale, 600_000}, kpis: %{conc_now: 2}}

    assert LiveConcurrency.label(model, true) == "11 running now (12 slots occupied) (sample 10m old)"
    assert LiveConcurrency.label(model, false) == "2 at run end"
  end

  test "presenter renders live adopted agents when telemetry only sees seven" do
    running = Enum.map(1..13, fn n -> %{work_state: :working, adopted_from: if(n <= 11, do: "prior boot")} end)
    t0 = 1_792_219_200_000
    t1 = t0 + 600_000

    actors =
      Map.new(1..7, fn n ->
        key = "ticket:#{n}"
        samples = Enum.map([t0, t1], fn ts -> %{"cpu_percent" => 10.0, "rss_bytes" => 100, timestamp_ms: ts, availability: "measured"} end)
        {key, %{samples: samples, profile: %{}}}
      end)

    dataset = %{
      actors: actors,
      tickets: %{},
      provenance: %{time_range: %{start: DateTime.from_unix!(t0, :millisecond) |> DateTime.to_iso8601(), end: DateTime.from_unix!(t1, :millisecond) |> DateTime.to_iso8601()}}
    }

    snapshot = {:stale, %{running: running, capacity: %{occupied: 14}}, %{age_ms: 600_000}}
    opts = LiveConcurrency.snapshot_opts(snapshot)
    model = Presenter.model(dataset, opts)

    assert model.kpis.conc_now == 7
    assert model.live_concurrency == 13
    assert model.live_occupied == 14
    assert LiveConcurrency.label(model, true) == "13 running now (14 slots occupied) (sample 10m old)"
  end

  test "unavailable snapshots do not make telemetry look current" do
    for {snapshot, cause} <- [
          {:snapshot_unpublished, :snapshot_unpublished},
          {:orchestrator_unavailable, :orchestrator_unavailable}
        ] do
      model = Presenter.model(%{actors: %{}, tickets: %{}}, LiveConcurrency.snapshot_opts(snapshot))

      assert model.live_concurrency_state == cause
      assert LiveConcurrency.label(model, true) == "occupancy unavailable"
    end

    assert LiveConcurrency.label(%{live_concurrency_state: {:stale_unavailable, nil}}, true) ==
             "occupancy unavailable (sample age unknown)"

    stale_without_age = LiveConcurrency.snapshot_opts({:stale, %{capacity: %{}}, %{}})
    assert stale_without_age[:live_concurrency_state] == {:stale_unavailable, nil}

    assert LiveConcurrency.label(Map.new(stale_without_age), true) ==
             "occupancy unavailable (sample age unknown)"
  end

  test "presenter reads live count and cap from one injected dashboard snapshot" do
    running = Enum.map(1..13, fn _ -> %{work_state: :working, adopted_from: "prior boot"} end)
    snapshot = %{capacity: %{effective: 16, max: 16, configured: 16, occupied: 14}, running: running}
    parent = self()

    snapshot_fun = fn _orchestrator, _timeout ->
      send(parent, :snapshot_read)
      {:current, snapshot, %{age_ms: 0}}
    end

    assert {:ok, model} =
             Presenter.load(
               session: :current,
               telemetry_file: @fixtures,
               dashboard_snapshot_fun: snapshot_fun,
               cache_identity: {__MODULE__, :one_snapshot, System.unique_integer([:positive])}
             )

    assert_received :snapshot_read
    refute_received :snapshot_read
    assert model.live_concurrency == 13
    assert model.cap == 16
  end
end
