# Usage: elixir tooling/json_store_oracle_probe.exs /path/to/frozen-snapshot
[root] = System.argv()
path = Path.join(root, "src/test/aiur/json_store_test.exs")
source = File.read!(path)
[_, tail] = String.split(source, "for {:ok, value} <- results do", parts: 2)
[body, _] = String.split(tail, "
      end", parts: 2)
oracle = "import ExUnit.Assertions
for {:ok, value} <- results do" <> body <> "
end"
for {name, results} <- [
  {"all_errors", List.duplicate({:error, :invalid_json}, 10)},
  {"mixed_errors", [{:ok, %{"v" => 1}}, {:error, :invalid_json}]},
  {"invalid_success_value", [{:ok, %{"v" => "bad"}}]},
  {"valid_values", Enum.map(1..10, &{:ok, %{"v" => &1}})}
] do
  outcome =
    try do
      Code.eval_string(oracle, results: results)
      "passes"
    rescue
      ExUnit.AssertionError -> "fails"
    end
  IO.puts("#{name}: #{outcome}")
end
