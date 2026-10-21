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
    scratch_dir = Path.join(System.tmp_dir!(), "refute-leak-#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch_dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(scratch_dir) end)
    scratch_path = Path.join(scratch_dir, "unsafe-pattern.exs")

    unsafe_inspect =
      ~r/(?:\brefute\s+inspect\s*\(|\bassert\s+[^\n]*\|>\s*inspect\s*\([^)]*\)\s*\|>\s*String\.contains\?\([^\n]*\)\s*==\s*false|\brefute\s+[^\n]*\|>\s*inspect\s*\([^)]*\)\s*\|>\s*String\.contains\?[^\n]*|\brefute\s+[^\n]*\|>\s*inspect\s*\([^)]*\)\s*=~[^\n]*|\b(?:assert|refute)\s+[^\n]*\|>\s*inspect\s*\(\s*limit\s*:\s*[^,)]*\)[^\n]*\|>\s*String\.contains\?)/

    assert Regex.match?(unsafe_inspect, "refute view |> inspect() |> String.contains?(secret)")
    assert Regex.match?(unsafe_inspect, "refute view |> inspect() =~ secret")
    assert Regex.match?(unsafe_inspect, "refute view |> inspect(limit: :infinity) |> String.contains?(secret)")

    File.write!(scratch_path, "refute view |> inspect() |> String.contains?(secret)")
    assert Regex.match?(unsafe_inspect, File.read!(scratch_path))

    offenders =
      test_root
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.reject(&(&1 == __ENV__.file))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> then(fn source ->
          if Regex.match?(unsafe_inspect, source), do: [path], else: []
        end)
      end)

    assert offenders == []
  end
end
