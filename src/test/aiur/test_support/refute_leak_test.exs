defmodule Aiur.TestSupport.RefuteLeakTest do
  use Aiur.TestSupport

  test "leak assertion checks beyond inspect defaults" do
    term = %{items: Enum.to_list(1..100) ++ ["buried-sentinel"]}
    assert_raise ExUnit.AssertionError, fn -> Aiur.TestSupport.refute_leak(term, "buried-sentinel") end
  end

  test "leak assertion checks beyond printable binary defaults" do
    term = String.duplicate("ordinary", 600) <> "buried-binary-sentinel"
    assert_raise ExUnit.AssertionError, fn -> Aiur.TestSupport.refute_leak(term, "buried-binary-sentinel") end
  end

  test "test tree rejects bare inspect refutes" do
    test_root = Path.expand("../..", __DIR__)

    offenders =
      test_root
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> then(fn source ->
          if Regex.match?(~r/\brefute\s+inspect\s*\(/, source), do: [path], else: []
        end)
      end)

    assert offenders == []
  end
end
