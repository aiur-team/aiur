# Usage: elixir tooling/resume_message_oracle_probe.exs SNAPSHOT
# Evaluates the exact negative assertion with the production-shaped message.
[root] = System.argv()
source = File.read!(Path.join(root, "src/test/aiur/orchestrator_max_duration_test.exs"))
[assertion] = source |> String.split("\n") |> Enum.filter(&String.contains?(&1, "refute_received {:resume_agent"))
for {name, code, expected} <- [
  {"original", assertion, :passes},
  {"three_element_control", String.replace(assertion, "_request_id}", "_request_id, _generation}"), :fails}
] do
  send(self(), {:resume_agent, 7, 101})
  result =
    try do
      Code.eval_string("import ExUnit.Assertions\n" <> code)
      :passes
    rescue
      ExUnit.AssertionError -> :fails
    end
  IO.inspect({name, result})
  unless result == expected, do: raise("unexpected assertion result")
  receive do
    {:resume_agent, 7, 101} -> :ok
  after
    0 -> :ok
  end
end
