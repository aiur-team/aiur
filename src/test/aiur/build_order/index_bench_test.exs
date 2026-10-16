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
      page = Index.window(index, "America/Los_Angeles", now())
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

      assert {:ok, _} = GenServer.call(server, {:window, "Etc/UTC"})
      :erlang.garbage_collect(server)
      {:memory, process_bytes} = Process.info(server, :memory)
      IO.puts("INDEX_BENCH kind=#{kind} tickets=#{count} assemble_diff_ms=#{microseconds / 1_000} flat_index_bytes=#{bytes} process_bytes=#{process_bytes} page_rows=#{length(page.sections.hist)}")
      stop_supervised(child)
      assert map_size(index.all) == count
      if count == 1_400, do: assert(microseconds <= 250_000)
    end
  end
end
