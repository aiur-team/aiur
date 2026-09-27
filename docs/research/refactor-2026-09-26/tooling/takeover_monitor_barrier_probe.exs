# Isolated monitor/helper barrier probe. No Aiur application or tracker is started.
[snapshot] = System.argv()
# Required only to compile unused default emitter branches.
defmodule Aiur.Issue do
  defstruct [:identifier]
end
Code.compile_file(Path.join(snapshot, "src/lib/aiur/executor/takeover_alert/monitor.ex"))
ast = snapshot |> Path.join("src/test/aiur/executor/takeover_alert_monitor_test.exs") |> File.read!() |> Code.string_to_quoted!()
{_, helpers} = Macro.prewalk(ast, [], fn
  {:defp, meta, [{:wait_for_mailbox_drained, _, _} | _] = args} = node, acc ->
    {node, [{:def, meta, args} | acc]}
  node, acc -> {node, acc}
end)
1 = length(helpers)
Code.compile_quoted(quote do
  defmodule ResearchMonitorWait do
    import ExUnit.Assertions
    unquote_splicing(Enum.reverse(helpers))
  end
end)
parent = self()
held_snapshot = fn captured_now ->
  send(parent, {:snapshot_held, self(), captured_now})
  receive do
    :release_snapshot ->
      send(parent, :snapshot_released)
      %{tickets: [], authoritative?: false}
  after
    5000 -> raise "probe callback was not released"
  end
end
{:ok, pid} = Aiur.Executor.TakeoverAlert.Monitor.start_link(
  name: ResearchHeldMonitor,
  start_paused?: true,
  snapshot_fun: held_snapshot,
  now_fun: fn -> ~U[2026-01-01 00:00:00Z] end,
  settings_fun: fn -> %{first_hours: 8, continuous_hours: 1} end,
  interval_ms: 60000
)
try do
  send(pid, :tick)
  receive do
    {:snapshot_held, ^pid, ~U[2026-01-01 00:00:00Z]} -> :ok
  after
    1000 -> raise "monitor did not enter real tick callback"
  end
  {:messages, []} = Process.info(pid, :messages)
  :ok = ResearchMonitorWait.wait_for_mailbox_drained(pid)
  IO.puts("actual_mailbox_helper_returns_while_real_tick_held=true")
  task = Task.async(fn -> :sys.get_state(pid) end)
  nil = Task.yield(task, 25)
  IO.puts("actor_completion_barrier_remains_blocked=true")
  send(pid, :release_snapshot)
  receive do
    :snapshot_released -> :ok
  after
    1000 -> raise "snapshot did not release"
  end
  %{start_paused?: true} = Task.await(task, 1000)
  IO.puts("actor_completion_barrier_returns_after_release=true")
after
  send(pid, :release_snapshot)
  GenServer.stop(pid)
end
