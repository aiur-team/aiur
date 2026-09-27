# Run only the two signal-fixture tests against a private copy of the frozen shim.
# The fake compiler/release/engine come from the actual test AST; no real build or run.
[snapshot, scratch, mode] = System.argv()
true = mode in ["original", "ignore_signals"]
probe_root = Path.join(scratch, "shim-signals-#{System.pid()}")
File.mkdir_p!(probe_root)
System.put_env("TMPDIR", probe_root)
System.put_env("HOME", probe_root)
File.cd!(probe_root)
shim = snapshot |> Path.join("scripts/aiurdev") |> File.read!()
needle = "trap 'release_build_lock' EXIT INT TERM"
4 = length(String.split(shim, needle)) - 1
shim = if mode == "ignore_signals",
  do: String.replace(shim, needle, "trap 'release_build_lock' EXIT\n  trap '' INT TERM"),
  else: shim
shim_path = Path.join(probe_root, "aiurdev")
File.write!(shim_path, shim)
defmodule Aiur.TestSupport do
  def tmp_root!(prefix), do: Path.join(System.tmp_dir!(), "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}")
end
ExUnit.start(autorun: false)
ast = snapshot |> Path.join("src/test/scripts_aiurdev_test.exs") |> File.read!() |> Code.string_to_quoted!()
{:defmodule, _, [_, [do: {:__block__, _, expressions}]]} = ast
helpers = Enum.filter(expressions, fn
  {:defp, _, [{name, _, _} | _]} ->
    name in [:fake_repo, :fake_mise, :spawn_shim_with_pid, :wait_until]
  _ -> false
end)
titles = [
  "SIGINT/SIGTERM during a locked rebuild releases the build lock",
  "a stale-reclaim takeover is not deleted by the previous owner's cleanup"
]
tests = Enum.filter(expressions, fn
  {:test, _, [title | _]} -> title in titles
  _ -> false
end)
2 = length(tests)
Code.compile_quoted(quote do
  defmodule ResearchShimSignalTests do
    use ExUnit.Case, async: false
    @script unquote(shim_path)
    unquote_splicing(helpers)
    unquote_splicing(tests)
  end
end)
try do
  %{failures: 0, total: 2} = ExUnit.run()
  IO.puts("mode=#{mode}; actual_signal_fixture_tests=2; failures=0")
after
  File.cd!(scratch)
  File.rm_rf!(probe_root)
end
