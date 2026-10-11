defmodule Aiur.RunTelemetry.Sampler.ProcessTreeTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.Procfs
  alias Aiur.RunTelemetry.Sampler

  test "sample_once/2 attributes mutually exclusive actor trees and real FD headroom" do
    table = process_table()
    first_metrics = metrics(0)

    first =
      Sampler.sample_once(%{},
        process_table_fun: fn -> {:ok, table, []} end,
        measure_fun: measure_from(first_metrics),
        entries_fun: &reaper_entries/0,
        daemon_pid: 1,
        operator_pid: 30,
        monotonic_ms: 1_000,
        clock_ticks_per_second: 100,
        fd_headroom_fun: fn ->
          %{pid: "1", used: 90, limit: 100, available: 10, headroom_ratio: 0.1}
        end
      )

    records = by_actor(first.records)

    assert records["ticket:930"].process_count == 2
    assert records["_daemon"].process_count == 3
    assert records["_operator"].process_count == 2
    assert records["ticket:remote"].availability == "unavailable"
    assert records["ticket:remote"].unavailable_reason == "remote_worker"

    assert records["_daemon"].system_fd == %{
             pid: "1",
             used: 90,
             limit: 100,
             available: 10,
             headroom_ratio: 0.1
           }

    assert records["ticket:930"].cpu_percent == nil
    assert Enum.sum([records["ticket:930"].process_count, records["_daemon"].process_count, records["_operator"].process_count]) == 7

    second_metrics =
      first_metrics
      |> put_in([10, :cpu_ticks], first_metrics[10].cpu_ticks + 100)
      |> put_in([10, :read_bytes], first_metrics[10].read_bytes + 1_000)
      |> put_in([11, :start_time_ticks], 999)
      |> put_in([11, :cpu_ticks], 1)

    second =
      Sampler.sample_once(first.previous,
        process_table_fun: fn -> {:ok, put_in(table, [11, :start_time_ticks], 999), []} end,
        measure_fun: measure_from(second_metrics),
        entries_fun: &reaper_entries/0,
        daemon_pid: 1,
        operator_pid: 30,
        monotonic_ms: 2_000,
        clock_ticks_per_second: 100,
        fd_headroom_fun: fn -> :unavailable end
      )

    ticket = by_actor(second.records)["ticket:930"]
    assert_in_delta ticket.cpu_percent, 100.0, 0.001
    assert_in_delta ticket.read_bytes_per_second, 1_000.0, 0.001
  end

  test "missing operator and procfs failures remain unavailable rather than zero" do
    no_operator =
      Sampler.sample_once(%{},
        process_table_fun: fn -> {:ok, process_table(), []} end,
        measure_fun: measure_from(metrics(0)),
        entries_fun: &reaper_entries/0,
        daemon_pid: 1,
        operator_pid: nil,
        monotonic_ms: 1_000,
        clock_ticks_per_second: 100,
        fd_headroom_fun: fn -> :exhausted end
      )

    records = by_actor(no_operator.records)
    assert records["_operator"].availability == "unavailable"
    assert records["_operator"].unavailable_reason == "operator_pid_unavailable"
    assert records["_daemon"].system_fd_status == "exhausted"

    unavailable =
      Sampler.sample_once(%{},
        process_table_fun: fn -> {:error, {:procfs_unavailable, :enoent}} end,
        entries_fun: &reaper_entries/0,
        daemon_pid: 1,
        operator_pid: nil,
        monotonic_ms: 1_000,
        clock_ticks_per_second: 100,
        fd_headroom_fun: fn -> :unavailable end
      )

    unavailable_records = by_actor(unavailable.records)
    assert unavailable_records["_daemon"].availability == "unavailable"
    assert unavailable_records["ticket:930"].availability == "unavailable"
    assert unavailable_records["_daemon"].rss_bytes == nil
    assert unavailable.warnings != []
  end

  test "invalid providers and measurements degrade to explicit unavailable evidence" do
    invalid_table =
      Sampler.sample_once(%{},
        process_table_fun: fn -> :invalid end,
        entries_fun: fn -> :invalid end,
        daemon_pid: 1,
        operator_pid: nil,
        fd_headroom_fun: fn -> raise "fd reader failed" end
      )

    assert by_actor(invalid_table.records)["_daemon"].availability == "unavailable"
    assert Enum.any?(invalid_table.warnings, &(&1.reason == :invalid_process_table))

    invalid_measurement =
      Sampler.sample_once(%{},
        process_table_fun: fn -> {:ok, process_table(), []} end,
        measure_fun: fn _table, _pids -> :invalid end,
        entries_fun: fn -> [:invalid_entry | reaper_entries()] end,
        daemon_pid: 1,
        operator_pid: 30,
        monotonic_ms: 1_000,
        clock_ticks_per_second: 100,
        fd_headroom_fun: fn -> :unavailable end
      )

    assert Enum.all?(invalid_measurement.records, &(&1.availability == "unavailable"))
    assert Enum.any?(invalid_measurement.warnings, &(&1.reason == :invalid_measurement))

    unavailable_clock =
      Sampler.sample_once(%{},
        process_table_fun: fn -> {:ok, process_table(), []} end,
        measure_fun: measure_from(metrics(0)),
        entries_fun: &reaper_entries/0,
        daemon_pid: 1,
        operator_pid: 30,
        monotonic_ms: 1_000,
        clock_ticks_per_second: :unavailable,
        fd_headroom_fun: fn -> :unavailable end
      )

    assert by_actor(unavailable_clock.records)["ticket:930"].cpu_percent == nil
  end

  test "PIDs that exit mid-scan cost one warning record, not one per PID" do
    root = Aiur.TestSupport.tmp_root!("aiur-sampler-procfs")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.join(root, "1"))
    File.write!(Path.join([root, "1", "stat"]), "1 (beam.smp) S 0 0 0 0 0 0 0 0 0 0 5 6 0 0 0 0 1 0 10\n")

    # Real hosts churn through short-lived processes constantly, so most of the
    # PIDs a scan lists are gone before their `stat` is read.
    for pid <- 100..199, do: File.mkdir_p!(Path.join(root, Integer.to_string(pid)))

    result =
      Sampler.sample_once(%{},
        process_table_fun: fn -> Procfs.process_table(root: root) end,
        measure_fun: fn table, pids -> Procfs.measure_many(table, pids, root: root) end,
        entries_fun: fn -> [] end,
        daemon_pid: 1,
        operator_pid: nil,
        monotonic_ms: 1_000,
        clock_ticks_per_second: 100,
        fd_headroom_fun: fn -> :unavailable end,
        fleet_snapshot_fun: fn -> :unavailable end,
        build_status_fun: fn -> :unavailable end
      )

    assert [%{field: :stat, pid: nil, reason: :vanished_during_scan, count: 100}] =
             Enum.filter(result.warnings, &(&1.reason == :vanished_during_scan))

    refute Enum.any?(result.warnings, &(&1.field == :stat and &1.reason == :enoent))
  end

  test "repeated EACCES and unavailable fields produce one counted warning per sample" do
    test_pid = self()
    table = process_table()
    warnings = for pid <- Map.keys(table), field <- [:io, :fd], do: %{pid: pid, field: field, reason: :eacces}
    warnings = warnings ++ [%{pid: 1, field: :rss, reason: :unavailable}]

    {:ok, sampler} =
      Sampler.start_link(
        name: nil,
        interval_ms: 60_000,
        start_immediately?: false,
        recorder: fn batch -> send(test_pid, {:recorded, batch}) end,
        sample_opts: [
          process_table_fun: fn -> {:ok, table, [%{pid: 99, field: :stat, reason: :eacces}]} end,
          measure_fun: fn _table, _pids ->
            measured = Map.new(metrics(0), fn {pid, process} -> {pid, %{process | rss_bytes: nil, fd_count: nil, read_bytes: nil, write_bytes: nil}} end)
            {:ok, measured, warnings}
          end,
          entries_fun: &reaper_entries/0,
          daemon_pid: 1,
          operator_pid: 30,
          clock_ticks_per_second: 100,
          fd_headroom_fun: fn -> :unavailable end,
          fleet_snapshot_fun: fn -> :unavailable end,
          build_status_fun: fn -> :unavailable end
        ]
      )

    on_exit(fn -> if Process.alive?(sampler), do: GenServer.stop(sampler) end)

    for _sample <- 1..3 do
      send(sampler, :tick)
      assert_receive {:recorded, batch}, 1_000
      assert [{:warning, summary}] = Enum.filter(batch, &(elem(&1, 0) == :warning))
      assert summary.event == :resource_sample_warning
      assert summary.reason == :unreadable_fields
      assert summary.count == 2 * map_size(table) + 2

      assert summary.counts == [
               %{field: :fd, reason: :eacces, count: map_size(table)},
               %{field: :io, reason: :eacces, count: map_size(table)},
               %{field: :rss, reason: :unavailable, count: 1},
               %{field: :stat, reason: :eacces, count: 1}
             ]

      assert {:resource, daemon} = Enum.find(batch, fn {kind, record} -> kind == :resource and record.actor == "_daemon" end)
      assert daemon.rss_bytes == nil
      assert daemon.read_bytes == nil
      assert :rss_bytes in daemon.partial_fields
    end
  end

  defp by_actor(records), do: Map.new(records, &{&1.actor, &1})

  defp process_table do
    %{
      1 => base(1, 30, 10),
      2 => base(2, 1, 20),
      10 => base(10, 1, 100),
      11 => base(11, 10, 110),
      20 => base(20, 1, 200),
      30 => base(30, 0, 300),
      31 => base(31, 30, 310)
    }
  end

  defp metrics(offset) do
    process_table()
    |> Map.new(fn {pid, base} ->
      {pid,
       Map.merge(base, %{
         cpu_ticks: pid * 10 + offset,
         rss_bytes: pid * 1_000,
         fd_count: rem(pid, 5) + 1,
         read_bytes: pid * 100 + offset,
         write_bytes: pid * 200 + offset
       })}
    end)
  end

  defp measure_from(metrics) do
    fn _table, pids -> {:ok, Map.take(metrics, MapSet.to_list(pids)), []} end
  end

  defp reaper_entries do
    [
      {{:os_pid, 10}, :agent, %{ticket: "930", backend: "codex", remote: false}},
      {{:os_pid, 11}, :agent, %{ticket: "930", backend: "codex", remote: false}},
      {{:os_pid, 20}, :agent, %{ticket: "remote", backend: "codex", remote: true, worker_host: "builder"}}
    ]
  end

  defp base(pid, ppid, start_time), do: %{pid: pid, ppid: ppid, cpu_ticks: pid, start_time_ticks: start_time}
end
