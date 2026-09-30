# Usage: elixir tooling/prewarm_phase_order_probe.exs SNAPSHOT
# Tests the original assertion block, not the production emitter.
[root] = System.argv()
source = File.read!(Path.join(root, "src/test/aiur/repo_base_test.exs"))
assertions =
  source
  |> String.split("\n")
  |> Enum.filter(&String.match?(&1, ~r/^      assert_receive \{:prewarm_phase, :(cloning|fetching|building|ready)\}, 5_000$/))
unless length(assertions) == 4, do: raise("expected exact four original assertions")
strict = """
import ExUnit.Assertions
for expected <- [:cloning, :fetching, :building, :ready] do
  assert_receive {:prewarm_phase, actual}, 100
  assert actual == expected
end
"""
for {label, code, expected_result} <- [
  {"original_reversed", "import ExUnit.Assertions\n" <> Enum.join(assertions, "\n"), :passes},
  {"ordered_control_reversed", strict, :fails}
] do
  for phase <- [:ready, :building, :fetching, :cloning], do: send(self(), {:prewarm_phase, phase})
  result =
    try do
      Code.eval_string(code)
      :passes
    rescue
      ExUnit.AssertionError -> :fails
    end
  IO.inspect({label, result})
  unless result == expected_result, do: raise("unexpected result")
  for _ <- 1..4 do
    receive do
      {:prewarm_phase, _} -> :ok
    after
      0 -> :ok
    end
  end
end
