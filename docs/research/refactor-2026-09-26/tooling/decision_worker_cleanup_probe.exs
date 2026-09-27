# Standalone research probe: no application boot or production mutation.
# Usage: elixir decision_worker_cleanup_probe.exs FROZEN_SNAPSHOT
[snapshot] = System.argv()
source = Path.join(snapshot, "src/test/aiur/decision_delivery_integration_test.exs")
ast = source |> File.read!() |> Code.string_to_quoted!()
{_, defs} = Macro.prewalk(ast, [], fn
  {:defp, meta, [{:worker_probe, args_meta, args}, body]} = node, acc ->
    {node, [{:def, meta, [{:worker_probe, args_meta, args}, body]} | acc]}
  node, acc -> {node, acc}
end)
[worker] = defs
{_, cleanups} = Macro.prewalk(ast, [], fn
  {{:., _, [{:__aliases__, _, [:Process]}, :exit]}, _, [{:worker_pid, _, nil}, :normal]} = node, acc ->
    {node, [node | acc]}
  node, acc -> {node, acc}
end)
[cleanup] = cleanups
Module.create(ResearchDecisionWorker, worker, Macro.Env.location(__ENV__))
parent = self()
pid = spawn(fn -> ResearchDecisionWorker.worker_probe(parent) end)
ref = Process.monitor(pid)
try do
  # Execute the same teardown signal used by the test's on_exit callback.
  {true, _} = Code.eval_quoted(cleanup, worker_pid: pid)
  # Signal and message from this sender reach the target in order.
  marker = make_ref()
  send(pid, {:after_cleanup_barrier, marker})
  receive do
    {:after_cleanup_barrier, ^marker} -> :ok
    {:DOWN, ^ref, :process, ^pid, reason} -> raise "normal signal terminated worker: #{inspect(reason)}"
  after
    1_000 -> raise "worker did not answer post-cleanup barrier"
  end
  true = Process.alive?(pid)
  IO.puts("original_normal_cleanup_worker_survives=true")
  true = Process.exit(pid, :kill)
  receive do
    {:DOWN, ^ref, :process, ^pid, :killed} -> IO.puts("kill_control_worker_terminated=true")
  after
    1_000 -> raise "kill control failed"
  end
after
  if Process.alive?(pid), do: Process.exit(pid, :kill)
  Process.demonitor(ref, [:flush])
end
