# Usage: elixir tooling/coordination_timeout_probe.exs SNAPSHOT baseline|mutant original|guarded
# Compiles an in-memory mutation; never edits production source.
[root, mode, oracle] = System.argv()
ExUnit.start(autorun: false)
Code.require_file(Path.join(root, "src/lib/aiur/secret_redactor.ex"))
source = File.read!(Path.join(root, "src/lib/aiur/coordination_tasks.ex"))
original = "defp resolve_timeout(:infinity, _default), do: :infinity"
replacement = "defp resolve_timeout(:infinity, default), do: default"
unless String.contains?(source, original), do: raise("mutation anchor missing")
source = if mode == "mutant", do: String.replace(source, original, replacement), else: source
Code.compile_string(source, "coordination_tasks_probe_source.ex")
{:ok, supervisor} = Task.Supervisor.start_link(name: Aiur.TaskSupervisor)
target = "infinite operation timeout preserves ordering past the default deadline"
test_source = File.read!(Path.join(root, "src/test/aiur/coordination_tasks_test.exs"))
ast = Code.string_to_quoted!(test_source)
ast = Macro.prewalk(ast, fn
  {:test, _meta, [^target, [do: body]]} = test ->
    if oracle == "guarded" do
      guarded = Macro.postwalk(body, fn
        {:send, meta, [{:first, _, _} = first, :release]} = release ->
          quote line: meta[:line] || 1 do
            refute_receive :second_started, 80
            assert Process.alive?(unquote(first))
            unquote(release)
          end
        node -> node
      end)
      {:test, elem(test, 1), [target, [do: guarded]]}
    else
      test
    end
  {:test, _, _} -> nil
  node -> node
end)
Code.compile_quoted(ast, "coordination_tasks_probe_test.exs")
result = ExUnit.run()
IO.inspect({mode, oracle, result}, label: "probe")
Supervisor.stop(supervisor)
expected = if mode == "mutant" and oracle == "guarded", do: 1, else: 0
unless result.total == 1 and result.failures == expected, do: raise("unexpected probe result")
