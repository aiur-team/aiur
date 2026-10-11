defmodule Aiur.AgentResourceGuard.RunawayGroupsTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Aiur.AgentResourceGuard.RunawayGroups

  defp write_procs(proc_root, pids, comm, pgid) do
    for pid <- pids do
      dir = Path.join(proc_root, Integer.to_string(pid))
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "stat"), "#{pid} (#{comm}) S 1 #{pgid} #{pgid} 0 -1 4194304\n")
    end
  end

  setup %{tmp_dir: proc_root} do
    # A self-spawning wrapper chain, a busy but legitimate group, and noise.
    write_procs(proc_root, 1..12, "git", 500)
    write_procs(proc_root, 100..109, "beam.smp", 600)
    write_procs(proc_root, 200..204, "sh (weird) name", 600)
    File.mkdir_p!(Path.join(proc_root, "self"))
    {:ok, opts: [proc_root: proc_root, threshold: 10, interval_ms: 0]}
  end

  test "scan counts only groups running one command more than the threshold", %{opts: opts} do
    assert RunawayGroups.scan(opts) == [%{pgid: 500, comm: "git", count: 12}]

    assert RunawayGroups.scan(Keyword.put(opts, :threshold, 4)) |> Enum.map(&{&1.pgid, &1.comm, &1.count}) ==
             [{500, "git", 12}, {600, "beam.smp", 10}, {600, "sh (weird) name", 5}]
  end

  test "check alerts once per runaway group and names the group to kill", %{opts: opts} do
    test_pid = self()
    opts = Keyword.put(opts, :emit_fun, fn topic, alert -> send(test_pid, {:alert, topic, alert}) end)

    assert [%{pgid: 500, count: 12}] = RunawayGroups.check(opts)
    assert_received {:alert, "system.host.runaway_process_group", alert}
    assert alert[:message] == "Runaway process group 500: 12 `git` processes"
    assert alert[:reason] =~ "kill -9 -- -500"

    assert RunawayGroups.check(opts) == []
    refute_received {:alert, _topic, _alert}
  end

  test "the resource guard's tick runs the scan", %{opts: opts} do
    test_pid = self()
    emit = fn topic, alert -> send(test_pid, {:alert, topic, alert[:message]}) end

    start_supervised!({Aiur.AgentResourceGuard, name: nil, interval_ms: 10, enforce_opts: [cap: 0, emit_fun: emit] ++ opts})

    assert_receive {:alert, "system.host.runaway_process_group", "Runaway process group 500: 12 `git` processes"}, 2_000
  end

  test "check scans at most once per interval", %{opts: opts} do
    opts = Keyword.merge(opts, interval_ms: 60_000, emit_fun: fn _topic, _alert -> :ok end)

    assert [_group] = RunawayGroups.check(opts)
    assert RunawayGroups.check(Keyword.put(opts, :threshold, 1)) == []
  end
end
