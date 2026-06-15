defmodule Aiur.LauncherWatchdogTest do
  use ExUnit.Case, async: true

  alias Aiur.LauncherWatchdog

  test "does not arm when no launcher pid is present" do
    assert :ignore = start_watchdog(launcher_pid: nil)
    assert :ignore = start_watchdog(launcher_pid: "")
    assert :ignore = start_watchdog(launcher_pid: "not-a-pid")
    assert :ignore = start_watchdog(launcher_pid: "0")
  end

  test "halts through on_launcher_gone when the launcher pid disappears" do
    test_pid = self()

    {:ok, pid} =
      start_watchdog(
        launcher_pid: "12345",
        interval_ms: 5,
        alive_fun: fn _ -> false end,
        on_launcher_gone: fn -> send(test_pid, :launcher_gone) end
      )

    ref = Process.monitor(pid)

    assert_receive :launcher_gone, 500
    # The watchdog stops itself after firing so the supervisor's shutdown
    # path isn't racing a still-polling timer.
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
  end

  test "stays armed while the launcher pid is alive" do
    test_pid = self()

    {:ok, _pid} =
      start_watchdog(
        launcher_pid: "12345",
        interval_ms: 5,
        alive_fun: fn _ -> true end,
        on_launcher_gone: fn -> send(test_pid, :launcher_gone) end
      )

    refute_receive :launcher_gone, 100
  end

  defp start_watchdog(opts) do
    LauncherWatchdog.start_link(Keyword.put(opts, :name, nil))
  end
end
