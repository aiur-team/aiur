defmodule Aiur.DaemonScanHotPathTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.AgentProcessLog.PsSnapshot
  alias Aiur.AgentResourceGuard.{BusyLoop, RunawayGroups}

  @moduletag :tmp_dir

  test "proc scans bypass the file server and regex parsing", %{tmp_dir: root} do
    proc = Path.join(root, "123")
    File.mkdir_p!(proc)
    File.write!(Path.join(proc, "stat"), "123 (sh (odd) name) R 1 42 42 0 0 0 3 0 0 0 10 20 0 0 0 0 0 0 99\n")
    File.write!(Path.join(proc, "io"), "syscr: 4\nsyscw: 5\n")
    File.write!(Path.join(proc, "status"), "voluntary_ctxt_switches:\t6\n")
    File.ln_s!(proc, Path.join(proc, "cwd"))

    {result, calls} =
      traced(
        fn ->
          {RunawayGroups.scan(proc_root: root, threshold: 0), Aiur.AgentResourceGuard.workspace_orphans(root, root), BusyLoop.sample(123, root)}
        end,
        [{:file, :read_file, 1}, {:file, :read_link, 1}, {Regex, :run, 2}, {Regex, :split, 3}]
      )

    assert {[%{pgid: 42, comm: "sh (odd) name", count: 1}], [%{pid: 123, cwd: ^proc}], %{pid: 123, state: "R", cpu: 30, minflt: 3, start: "99", io: 9, ctxt: 6}} = result
    assert calls == []
  end

  test "ps parsing preserves argv and start identity without regex splitting" do
    {result, calls} =
      traced(
        fn ->
          {PsSnapshot.parse_ps(" 123\t 1  sh   sh -c a  b\n 124 1 sleep\ninvalid\n"), PsSnapshot.parse_lstarts(" 123   Tue Oct 27 12:00:00 2026\ninvalid\n")}
        end,
        [{Regex, :split, 3}]
      )

    assert {%{123 => %{pid: 123, ppid: 1, comm: "sh", cmdline: "sh -c a  b"}, 124 => %{comm: "sleep", cmdline: ""}}, %{123 => "Tue Oct 27 12:00:00 2026"}} = result
    assert calls == []
  end

  test "an empty root set skips process collection while still reporting prior exits", %{tmp_dir: root} do
    now = DateTime.utc_now()
    path = Path.join(root, "processes.tsv")
    entry = %{pid: 123, ppid: 1, root_pid: 123, ticket: "6950", comm: "sh", first_seen: DateTime.add(now, -2, :second)}

    assert Aiur.AgentProcessLog.sweep_once(
             roots_fun: fn -> [] end,
             processes_fun: fn -> flunk("host scan without agents") end,
             processes: %{{123, "start"} => entry},
             clock: fn -> now end,
             path: path
           ) == %{}

    assert File.read!(path) == "#{DateTime.to_unix(now)}\texit\t123\t6950\t123\t1\tsh\t\t\t\t2\n"
  end

  defp traced(fun, patterns) do
    for pattern <- patterns, do: :erlang.trace_pattern(pattern, true, [])
    on_exit(fn -> for pattern <- patterns, do: :erlang.trace_pattern(pattern, false, []) end)

    task =
      Task.async(fn ->
        receive do
          :run -> fun.()
        end
      end)

    :erlang.trace(task.pid, true, [:call])
    send(task.pid, :run)
    result = Task.await(task)
    ref = :erlang.trace_delivered(task.pid)
    receive_barrier({:trace_delivered, _, ^ref})
    {result, trace_calls(task.pid, [])}
  end

  defp trace_calls(pid, calls) do
    receive do
      {:trace, ^pid, :call, call} -> trace_calls(pid, [call | calls])
    after
      0 -> calls
    end
  end
end
