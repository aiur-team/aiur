defmodule Aiur.RunTelemetry.SamplerTest do
  use ExUnit.Case, async: true

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

  test "invalid scan results are recorded as fail-open warnings" do
    test_pid = self()

    {:ok, sampler} =
      Sampler.start_link(
        name: nil,
        sample_fun: fn _previous -> :invalid end,
        recorder: fn records -> send(test_pid, {:recorded, records}) end,
        start_immediately?: false
      )

    send(sampler, :ignored)
    send(sampler, :tick)

    assert_receive {:recorded,
                    [
                      {:warning,
                       %{
                         event: :resource_sample_failed,
                         reason: :invalid_result
                       }}
                    ]},
                   500

    GenServer.stop(sampler)
  end

  test "a slow scan causes overlapping ticks to be skipped" do
    test_pid = self()

    sample_fun = fn previous ->
      send(test_pid, {:scan_started, self()})

      receive do
        :finish_scan -> %{records: [], warnings: [], previous: previous}
      end
    end

    recorder = fn records -> send(test_pid, {:recorded, records}) end

    {:ok, sampler} =
      Sampler.start_link(
        name: nil,
        interval_ms: 10_000,
        sample_fun: sample_fun,
        recorder: recorder,
        start_immediately?: true
      )

    assert_receive {:scan_started, worker}, 500
    send(sampler, :tick)
    refute_receive {:scan_started, _other}, 100

    assert_receive {:recorded, [{:warning, %{event: :resource_sample_skipped, reason: :overlap}}]}, 500

    send(worker, :finish_scan)
    assert_receive {:recorded, []}, 500
    assert Process.alive?(sampler)
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
