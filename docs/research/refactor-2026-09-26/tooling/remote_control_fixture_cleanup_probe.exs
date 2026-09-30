# Isolated failure-path fixture probe; never invokes a workspace reaper.
[snapshot, scratch] = System.argv()
source = Path.join(snapshot, "src/test/aiur/claude/remote_control_test.exs")
ast = source |> File.read!() |> Code.string_to_quoted!()
title = "reaps a real process rooted under the workspace and spares one outside it"
{_, [test_body]} = Macro.prewalk(ast, [], fn
  {:test, _, [^title, [do: body]]} = node, acc -> {node, [body | acc]}
  node, acc -> {node, acc}
end)
{:__block__, _, expressions} = test_body
callbacks = for {:on_exit, _, [callback]} <- expressions, do: callback
2 = length(callbacks)
{_, helpers} = Macro.prewalk(ast, [], fn
  {:defp, meta, [{name, _, _} | _] = args} = node, acc
      when name in [:spawn_sleeper, :wait_for_proc_cwd] ->
    {node, [{:def, meta, args} | acc]}
  node, acc -> {node, acc}
end)
Code.compile_quoted(quote do
  defmodule ResearchSleeperFixture do
    unquote_splicing(Enum.reverse(helpers))
  end
end)
root = Path.join(scratch, "owned-sleepers-#{System.pid()}")
inside = Path.join(root, "inside/ticket/src")
outside = Path.join(root, "outside")
File.mkdir_p!(inside)
File.mkdir_p!(outside)
inside_pid = ResearchSleeperFixture.spawn_sleeper(inside)
outside_pid = ResearchSleeperFixture.spawn_sleeper(outside)
runnable = fn pid ->
  case File.read("/proc/#{pid}/stat") do
    {:ok, stat} -> not String.contains?(stat, ") Z ")
    _ -> false
  end
end
try do
  true = runnable.(inside_pid)
  true = runnable.(outside_pid)
  binding = [root: Path.join(root, "inside"), outside: outside, outside_pid: outside_pid]
  # Simulate an assertion failure before successful inside reaping.
  Enum.each(Enum.reverse(callbacks), fn callback ->
    {fun, _} = Code.eval_quoted(callback, binding)
    fun.()
  end)
  Enum.reduce_while(1..100, nil, fn _, _ ->
    if runnable.(outside_pid), do: (Process.sleep(10); {:cont, nil}), else: {:halt, nil}
  end)
  true = runnable.(inside_pid)
  false = runnable.(outside_pid)
  false = File.exists?(inside)
  IO.puts("actual_on_exit_callbacks=2")
  IO.puts("inside_sleeper_survives_failed_reap_cleanup=true")
  IO.puts("outside_sleeper_cleaned=true")
  {_, 0} = System.cmd("kill", ["-KILL", to_string(inside_pid)], stderr_to_stdout: true)
  Enum.reduce_while(1..100, nil, fn _, _ ->
    if runnable.(inside_pid), do: (Process.sleep(10); {:cont, nil}), else: {:halt, nil}
  end)
  false = runnable.(inside_pid)
  IO.puts("owned_inside_cleanup_control_stops_sleeper=true")
after
  for pid <- [inside_pid, outside_pid] do
    System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
  end
  File.rm_rf!(root)
end
