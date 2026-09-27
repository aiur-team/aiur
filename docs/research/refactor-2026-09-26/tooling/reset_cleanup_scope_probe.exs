# Research-only: evaluate the frozen test's cleanup inside a caller-owned TMPDIR.
# Usage: elixir reset_cleanup_scope_probe.exs SNAPSHOT EXPECTED_PRIVATE_TMPDIR
[snapshot, expected_tmp] = System.argv()
tmp_root = Path.expand(System.tmp_dir!())
if tmp_root != Path.expand(expected_tmp), do: raise("TMPDIR does not match private probe root")
if tmp_root in ["/", "/tmp", "/var/tmp"], do: raise("refusing shared temporary root")

source = Path.join(snapshot, "src/test/aiur/test_reset_test.exs") |> File.read!()
ast = Code.string_to_quoted!(source)
wanted = ~s|File.rm_rf!(Path.join(System.tmp_dir!(), "aiur-workspaces"))|
{_, matches} = Macro.prewalk(ast, [], fn node, acc ->
  case node do
    {{:., _, [{:__aliases__, _, [:File]}, :rm_rf!]}, _, [_]} ->
      if Macro.to_string(node) == wanted, do: {node, [node | acc]}, else: {node, acc}
    _ -> {node, acc}
  end
end)
[cleanup] = matches
scope = Path.join(tmp_root, "aiur-workspaces")
if File.exists?(scope), do: raise("probe scope already exists")
fixture = Path.join(scope, "repo/owned-fixture")
sibling = Path.join(scope, "other-repo/other-fixture/keep.txt")
setup = fn ->
  File.mkdir_p!(fixture)
  File.mkdir_p!(Path.dirname(sibling))
  File.write!(sibling, "sibling evidence")
end
try do
  setup.()
  Code.eval_quoted(cleanup)
  original_removed_sibling = not File.exists?(sibling)
  if not original_removed_sibling, do: raise("counterexample not reproduced")
  setup.()
  File.rm_rf!(fixture)
  control_preserved_sibling = File.read!(sibling) == "sibling evidence"
  if not control_preserved_sibling, do: raise("narrow cleanup control failed")
  IO.puts("original_cleanup_removed_sibling=true")
  IO.puts("fixture_only_cleanup_preserved_sibling=true")
after
  File.rm_rf!(scope)
end
