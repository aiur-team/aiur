# Usage: elixir tooling/build_descendant_identity_probe.exs SNAPSHOT
# Extracts the real fixture writer; adds only a BASHPID observation.
[root] = System.argv()
source = File.read!(Path.join(root, "src/test/aiur/build_gate_test.exs"))
ast = Code.string_to_quoted!(source)
{_, functions} = Macro.prewalk(ast, [], fn
  {:defp, meta, [{:write_fake_mix!, head_meta, args}, body]}, acc ->
    {nil, [{:def, meta, [{:write_fake_mix!, head_meta, args}, body]} | acc]}
  node, acc -> {node, acc}
end)
[writer] = functions
Code.compile_quoted(quote do
  defmodule ProbeFixture do
    unquote(writer)
  end
end)
dir = Path.join(System.get_env("AIUR_RESEARCH_PROBE_TMP", System.tmp_dir!()), "aiur-descendant-probe-#{System.unique_integer([:positive])}")
File.mkdir_p!(dir)
path = Path.join(dir, "mix")
descendant = Path.join(dir, "descendant")
release = Path.join(dir, "release")
ProbeFixture.write_fake_mix!(path)
script = File.read!(path)
needle = ~S|printf '%s\n' "$$" > "${FAKE_MIX_DESCENDANT}.pid"|
observation = ~S|printf '%s\n' "$BASHPID" > "${FAKE_MIX_DESCENDANT}.actual-pid"|
unless length(String.split(script, needle)) == 2, do: raise("fixture PID assignment changed")
File.write!(path, String.replace(script, needle, needle <> "\n" <> observation))
wait = fn file ->
  Enum.reduce_while(1..200, nil, fn _, _ ->
    if File.exists?(file), do: {:halt, :ok}, else: (Process.sleep(10); {:cont, nil})
  end) || raise("fixture observation timed out")
end
try do
  {_out, 0} = System.cmd("bash", [path, "test"], env: [
    {"FAKE_MIX_LOG", Path.join(dir, "log")},
    {"FAKE_MIX_PID", Path.join(dir, "parent")},
    {"FAKE_MIX_DESCENDANT", descendant},
    {"FAKE_MIX_DESCENDANT_RELEASE", release},
    {"FAKE_MIX_DESCENDANT_SLEEP", "0"}
  ])
  wait.(descendant <> ".actual-pid")
  parent = File.read!(Path.join(dir, "parent")) |> String.trim()
  recorded = File.read!(descendant <> ".pid") |> String.trim()
  actual = File.read!(descendant <> ".actual-pid") |> String.trim()
  {_, live} = System.cmd("kill", ["-0", actual], stderr_to_stdout: true)
  unless recorded == parent and actual != parent and live == 0, do: raise("unexpected identity result")
  IO.puts("recorded_descendant_equals_parent=true actual_descendant_differs=true actual_descendant_alive=true")
after
  File.touch!(release)
  wait.(descendant <> ".done")
  File.rm_rf!(dir)
end
