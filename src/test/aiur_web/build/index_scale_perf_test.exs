defmodule AiurWeb.Build.IndexScalePerfTest do
  @moduledoc """
  Server timing and memory of the build home at 10,000 tickets (MP-E8-C12-T06, T1-T6).

  A measurement, excluded by default (the suite excludes `:perf_regression`) because
  wall-clock budgets flake on shared CI runners. Run with

      env -C src HOME="$(mktemp -d)" mise exec -- mix test --include perf_regression \\
        --only perf_regression test/aiur_web/build/index_scale_perf_test.exs

  Each metric prints one `metric=… value=… unit=… budget=…` line, then asserts its budget.
  """
  use ExUnit.Case, async: false
  use Aiur.TestSupport

  alias Aiur.BuildOrder.{Features, History.Edges}
  alias Aiur.BuildOrder.Index, as: Core
  alias Aiur.TestSupport.BuildHome.{FixtureSource, IndexSeed, Scale}
  alias AiurWeb.Build.Index

  @moduletag :perf_regression
  @moduletag timeout: 300_000
  @zone "America/Los_Angeles"

  test "T1-T6 index assembly, window, diff, edges, memory and feature reads at 10,000 tickets" do
    Aiur.TestSupport.start_owned_endpoint!()
    {:ok, dense} = FixtureSource.full(dataset: "dense")
    data = Scale.dataset(dense, 10_000)
    dir = Aiur.TestSupport.tmp_root!("index-scale-perf")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    seed = IndexSeed.start(data, dir)
    on_exit(fn -> IndexSeed.stop(seed) end)
    now = data["now"]

    {assemble_us, index} =
      median(fn ->
        {:ok, index} = Core.assemble(seed.parts, now: now)
        index
      end)

    assert map_size(index.all) == 10_000
    base = Core.base(index)
    {window_us, _page} = median(fn -> Core.window(base, @zone, now) end)
    before = Core.local_midnight(Scale.local_date(now), @zone)
    {earlier_us, {:ok, page}} = median(fn -> Core.earlier(index, before, @zone, 1) end)
    assert page.rows != []
    {id, row} = Enum.find(index.all, fn {_id, row} -> row.sec == "hist" end)
    changed = put_in(index, [:all, id], %{row | title: row.title <> " (edited)"})
    {diff_us, diff} = median(fn -> Core.diff(index, changed) end)
    assert Enum.map(diff.upsert, & &1.id) == [id]
    {:ok, history} = seed.parts.history
    {edges_us, {:ok, edges}} = median(fn -> Edges.build(history, %{owner: "example", repository: "aiur-fixture"}) end)
    features_p95 = feature_p95(seed.opts[:features_opts])

    # Parts come from another process, as in production: a closure over seed.parts would add a
    # second copy of every part to the Index heap and inflate T5.
    parts = start_supervised!({Agent, fn -> seed.parts end})

    server =
      start_supervised!(
        {Index,
         name: nil,
         subscribe: fn -> :ok end,
         read: fn _, _, _ -> Agent.get(parts, & &1) end,
         daemon_read: fn _ -> %{state: "live", heartbeat_at: 1, observed_at: 2} end,
         daemon_timer: fn _, _, _ -> make_ref() end,
         clock: fn -> now end}
      )

    assert {:ok, _} = Index.window(server, @zone)
    memory = index_memory(server)

    results = [
      {"T1 assemble 10k", assemble_us / 1_000, "ms", 750},
      {"T2 window/3", window_us / 1_000, "ms", 25},
      {"T2 earlier/4 one day", earlier_us / 1_000, "ms", 25},
      {"T3 diff/2 one changed row", diff_us / 1_000, "ms", 50},
      {"T4 Edges.build/2 (#{length(edges.edges)} edges)", edges_us / 1_000, "ms", 300},
      {"T5 Index memory", memory / 1_048_576, "MiB", 64},
      {"T6 Features read p95 (100 calls)", features_p95 / 1_000, "ms", 5}
    ]

    for {metric, value, unit, budget} <- results, do: IO.puts("metric=#{inspect(metric)} value=#{Float.round(value * 1.0, 3)} unit=#{unit} budget=#{budget}")
    assert [] == for({metric, value, _unit, budget} <- results, value > budget, do: metric)
  end

  # Median of five runs after one warm-up, so module loading and first GC stay out of the number.
  defp median(fun) do
    fun.()
    runs = for _ <- 1..5, do: :timer.tc(fun)
    runs |> Enum.sort_by(&elem(&1, 0)) |> Enum.at(2)
  end

  defp feature_p95(opts) do
    samples = for _ <- 1..100, do: elem(:timer.tc(fn -> {:ok, _} = Features.snapshot(opts) end), 0)
    samples |> Enum.sort() |> Enum.at(94)
  end

  defp index_memory(pid) do
    :erlang.garbage_collect(pid)
    {:memory, process} = Process.info(pid, :memory)
    tables = Enum.filter(:ets.all(), &(:ets.info(&1, :owner) == pid))
    ets = Enum.sum(Enum.map(tables, &(:ets.info(&1, :memory) * :erlang.system_info(:wordsize))))
    IO.puts("metric=\"T5 breakdown\" process_bytes=#{process} ets_bytes=#{ets} tables=#{length(tables)}")
    process + ets
  end
end
