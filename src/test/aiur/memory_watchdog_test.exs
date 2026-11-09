defmodule Aiur.MemoryWatchdogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.MemoryWatchdog

  @gib 1_073_741_824

  defp opts(used, host \\ 32 * @gib, rss \\ nil) do
    parent = self()

    [
      used_fun: fn -> used end,
      rss_fun: fn -> rss end,
      host_fun: fn -> host end,
      fraction_fun: fn -> 0.5 end,
      snapshot_fun: fn ->
        %{
          processes: [%{name: "AiurWeb.Build.Index", memory: 480 * 1_048_576, queue: 7}],
          unresponsive: ["Aiur.Runaway"],
          ets: [%{name: ":github_resources", memory: 90 * 1_048_576, size: 5947}]
        }
      end,
      alert_fun: fn topic, alert -> send(parent, {:alert, topic, alert}) end
    ]
  end

  test "alerts once on crossing the line, naming the largest processes and tables, and resolves below it" do
    log = capture_log(fn -> assert MemoryWatchdog.check(false, opts(17 * @gib)) == true end)
    assert_received {:alert, "system.daemon.memory_high", alert}
    assert alert[:needs_attention] == true
    assert alert[:reason] =~ "AiurWeb.Build.Index 480 MiB queue=7"
    assert log =~ "processes=[AiurWeb.Build.Index 480 MiB queue=7] unresponsive=[Aiur.Runaway] ets=[:github_resources 90 MiB size=5947]"

    assert MemoryWatchdog.check(true, opts(20 * @gib)) == true
    refute_received {:alert, _, _}

    assert MemoryWatchdog.check(true, opts(4 * @gib)) == false
    assert_received {:alert, "system.daemon.memory_high.resolved", _}
  end

  test "resident memory above the line alerts even when the BEAM's own count is below it" do
    log = capture_log(fn -> assert MemoryWatchdog.check(false, opts(4 * @gib, 32 * @gib, 21 * @gib)) == true end)
    assert_received {:alert, "system.daemon.memory_high", _}
    assert log =~ "used_mib=21504 rss_mib=21504 beam_mib=4096"
  end

  test "a process that does not answer is listed as unresponsive instead of hanging the snapshot" do
    stuck = start_supervised!({Agent, fn -> nil end})
    Process.register(stuck, :memory_watchdog_test_stuck)

    # Stands in for a process in a long garbage collection, which does not answer Process.info/2.
    hangs = fn
      ^stuck, _items ->
        receive do
        after
          :infinity -> nil
        end

      pid, items ->
        Process.info(pid, items)
    end

    snapshot = MemoryWatchdog.snapshot(pids: [self(), stuck], probe_timeout_ms: 200, info_fun: hangs)

    assert snapshot.unresponsive == [":memory_watchdog_test_stuck"]
    assert [%{memory: memory, queue: queue}] = snapshot.processes
    assert memory > 0 and is_integer(queue)
    assert Enum.any?(snapshot.ets, &(&1.size >= 0 and &1.memory > 0))
  end

  test "the daemon caps every process heap at boot" do
    assert %{size: size, kill: true, error_logger: true} = :erlang.system_info(:max_heap_size)
    assert size * :erlang.system_info(:wordsize) == 4 * @gib
  end

  test "a process spawned under the cap is killed when its heap passes it" do
    previous = :erlang.system_info(:max_heap_size)
    on_exit(fn -> :erlang.system_flag(:max_heap_size, previous) end)

    capture_log(fn ->
      :ok = MemoryWatchdog.cap_process_heap(8 * 1_048_576)
      {pid, ref} = spawn_monitor(fn -> Enum.to_list(1..10_000_000) |> length() end)
      :erlang.system_flag(:max_heap_size, previous)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    end)
  end

  test "a failing alert leaves the watchdog running" do
    parent = self()

    failing =
      Keyword.merge(opts(17 * @gib),
        name: nil,
        interval_ms: 1,
        alert_fun: fn _topic, _alert ->
          send(parent, :alert_attempted)
          raise "sink down"
        end
      )

    {:ok, pid} = GenServer.start(MemoryWatchdog, failing)
    capture_log(fn -> assert_receive :alert_attempted, 1_000 end)
    capture_log(fn -> assert_receive :alert_attempted, 1_000 end)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "stays quiet below the line and when host memory is unknown" do
    assert MemoryWatchdog.check(false, opts(15 * @gib)) == false
    assert MemoryWatchdog.check(false, opts(17 * @gib, nil)) == false
    refute_received {:alert, _, _}
  end
end
