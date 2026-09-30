# Research-only assertion probe; does not run the application or writer.
[snapshot] = System.argv()
source = Path.join(snapshot, "src/test/aiur/issue_log_transcript_test.exs") |> File.read!()
{_, bodies} = source |> Code.string_to_quoted!() |> Macro.prewalk([], fn
  {:test, _, ["persists booleans as JSON booleans", _, [do: body]]} = node, acc ->
    {node, [body | acc]}
  node, acc -> {node, acc}
end)
[{:__block__, _, expressions}] = bodies
assertions = Enum.filter(expressions, &match?({:assert, _, _}, &1))
if length(assertions) != 2, do: raise("assertion shape changed")
original = quote do
  import ExUnit.Assertions
  unquote({:__block__, [], assertions})
end
accepts = fn ast, record ->
  try do
    Code.eval_quoted(ast, record: record)
    true
  rescue
    ExUnit.AssertionError -> false
  end
end
cases = [
  {"valid_boolean", %{"role" => "tool", "payload" => %{"truncated" => false}}, true},
  {"string_boolean", %{"role" => "tool", "payload" => %{"truncated" => "false"}}, false},
  {"missing_payload", %{"role" => "tool"}, false}
]
for {label, record, expected_control} <- cases do
  original_passes = accepts.(original, record)
  control_passes = get_in(record, ["payload", "truncated"]) === false
  if not original_passes or control_passes != expected_control, do: raise("unexpected probe result")
  IO.puts("#{label}: original_passes=#{original_passes} exact_boolean_control=#{control_passes}")
end
