# Usage: elixir tooling/provider_refresh_lifecycle_probe.exs SNAPSHOT
# Runs only the frozen refresh tests and their scheduler; no Aiur application.
[root] = System.argv()
ExUnit.start(autorun: false)
Code.require_file(Path.join(root, "src/lib/aiur/provider_meter_refresh.ex"))
{:ok, supervisor} = Task.Supervisor.start_link(name: Aiur.TaskSupervisor)
before = MapSet.new(Process.list())
:erlang.trace(:all, true, [:procs, :set_on_spawn, {:tracer, self()}])
Code.require_file(Path.join(root, "src/test/aiur/provider_meter_refresh_test.exs"))
result = ExUnit.run()
delivery = :erlang.trace_delivered(:all)
receive do
  {:trace_delivered, :all, ^delivery} -> :ok
after
  5_000 -> raise "trace delivery timed out"
end
:erlang.trace(:all, false, [:all])
IO.inspect(result, label: "isolated_test_result")
collect = fn collect, spawned ->
  receive do
    {:trace, _parent, :spawn, pid, {:erlang, :apply, [fun, []]}} when is_function(fun) ->
      case :erlang.fun_info(fun, :module) do
        {:module, Aiur.ProviderMeterRefreshTest} -> collect.(collect, [pid | spawned])
        _ -> collect.(collect, spawned)
      end
    _other -> collect.(collect, spawned)
  after
    0 -> spawned
  end
end
spawned = MapSet.new(collect.(collect, []))
survivors =
  Process.list()
  |> Enum.reject(&MapSet.member?(before, &1))
  |> Enum.filter(&MapSet.member?(spawned, &1))
IO.inspect(length(survivors), label: "surviving_test_spawned_processes")
Enum.each(survivors, fn pid ->
  IO.inspect(Process.info(pid, [:initial_call, :current_function, :links, :status]))
  Process.exit(pid, :kill)
end)
Supervisor.stop(supervisor)
unless result.failures == 0 and length(survivors) == 1 do
  raise "unexpected lifecycle probe result"
end
