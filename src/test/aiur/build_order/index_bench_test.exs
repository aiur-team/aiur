defmodule Aiur.BuildOrder.IndexBenchTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.BuildOrder.Index
  alias AiurWeb.Build.Index, as: IndexServer
  @moduletag :perf_regression

  test "records 1400 and 10000 ticket assembly time, index size and page size" do
    # Measure steady-state work after loading the projector modules.
    assert {:ok, _warm} = assemble(parts([row(1)]))

    for count <- [1_400, 10_000], kind <- [:history, :open] do
      p = parts(for n <- 1..count, do: row(n, %{end: DateTime.add(~U[2026-10-07 12:00:00Z], -div(n, 50) * 86_400)}))
      p = if kind == :open, do: put_in(parts(), [:open, Access.key(:tickets)], Enum.map(1..count, &open/1)), else: p
      assert {:ok, old} = assemble(p)

      {microseconds, index} =
        :timer.tc(fn ->
          {:ok, index} = assemble(p)
          Index.diff(old, index)
          index
        end)

      bytes = :erts_debug.flat_size(index) * :erlang.system_info(:wordsize)
      page = Index.window(Index.base(index), "America/Los_Angeles", now())
      child = {:index_bench, kind, count}

      server =
        start_supervised!(
          {IndexServer,
           name: nil,
           subscribe: fn -> :ok end,
           broadcast: fn _ -> :ok end,
           read: fn _, _, _ -> p end,
           daemon_read: fn _ -> %{state: "unknown", heartbeat_at: nil, observed_at: now()} end,
           daemon_timer: fn _, _, _ -> make_ref() end},
          id: child
        )

      assert {:ok, _} = IndexServer.window(server, "Etc/UTC")
      :erlang.garbage_collect(server)
      {:memory, process_bytes} = Process.info(server, :memory)
      IO.puts("INDEX_BENCH kind=#{kind} tickets=#{count} assemble_diff_ms=#{microseconds / 1_000} flat_index_bytes=#{bytes} process_bytes=#{process_bytes} page_rows=#{length(page.sections.hist)}")
      stop_supervised(child)
      assert map_size(index.all) == count
      if count == 1_400, do: assert(microseconds <= 250_000)
    end
  end

  test "records mount latency for 1 and 50 concurrent mounts of a 1400 ticket index" do
    p = parts(for n <- 1..1_400, do: row(n, %{end: DateTime.add(~U[2026-10-07 12:00:00Z], -div(n, 50) * 86_400)}))

    server =
      start_supervised!(
        {IndexServer,
         name: nil,
         subscribe: fn -> :ok end,
         broadcast: fn _ -> :ok end,
         read: fn _, _, _ -> p end,
         daemon_read: fn _ -> %{state: "unknown", heartbeat_at: nil, observed_at: now()} end,
         daemon_timer: fn _, _, _ -> make_ref() end}
      )

    mount = fn -> :timer.tc(fn -> {:ok, _} = IndexServer.window(server, "America/Los_Angeles") end) |> elem(0) end
    mount.()
    single = 1..5 |> Enum.map(fn _ -> mount.() end) |> Enum.sort() |> Enum.at(2)

    latencies =
      for n <- [10, 50], into: %{} do
        worst = 1..n |> Task.async_stream(fn _ -> mount.() end, max_concurrency: n, timeout: 30_000) |> Enum.map(fn {:ok, us} -> us end) |> Enum.max()
        {n, worst}
      end

    IO.puts("INDEX_MOUNT_BENCH schedulers=#{System.schedulers_online()} single_us=#{single} worst_10_us=#{latencies[10]} worst_50_us=#{latencies[50]}")
    # Serialized in the server, the worst of 50 mounts waits for all 50 cuts; caller-side cuts run in parallel.
    if System.schedulers_online() >= 4, do: assert(latencies[50] < 25 * single)
  end
end
