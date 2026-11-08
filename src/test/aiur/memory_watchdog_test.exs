defmodule Aiur.MemoryWatchdogTest do
  use ExUnit.Case, async: true

  alias Aiur.MemoryWatchdog

  @gib 1_073_741_824

  defp opts(used, host \\ 32 * @gib) do
    parent = self()

    [
      used_fun: fn -> used end,
      host_fun: fn -> host end,
      fraction_fun: fn -> 0.5 end,
      top_fun: fn -> [{"AiurWeb.Build.Index", 480 * 1_048_576}] end,
      alert_fun: fn topic, alert -> send(parent, {:alert, topic, alert}) end
    ]
  end

  test "alerts once on crossing the line, naming the largest process, and resolves below it" do
    assert MemoryWatchdog.check(false, opts(17 * @gib)) == true
    assert_received {:alert, "system.daemon.memory_high", alert}
    assert alert[:needs_attention] == true
    assert alert[:reason] =~ "AiurWeb.Build.Index 480 MiB"

    assert MemoryWatchdog.check(true, opts(20 * @gib)) == true
    refute_received {:alert, _, _}

    assert MemoryWatchdog.check(true, opts(4 * @gib)) == false
    assert_received {:alert, "system.daemon.memory_high.resolved", _}
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
    assert_receive :alert_attempted
    assert_receive :alert_attempted
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "stays quiet below the line and when host memory is unknown" do
    assert MemoryWatchdog.check(false, opts(15 * @gib)) == false
    assert MemoryWatchdog.check(false, opts(17 * @gib, nil)) == false
    refute_received {:alert, _, _}
  end
end
