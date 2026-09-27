# Standalone research probe: pure manifest decoding, no application boot or writes.
# Usage: elixir manifest_validation_oracle_probe.exs FROZEN_SNAPSHOT
[snapshot] = System.argv()
test_ast = snapshot |> Path.join("src/test/aiur/usage_compaction/manifest_test.exs") |> File.read!() |> Code.string_to_quoted!()
{_, fixtures} = Macro.prewalk(test_ast, [], fn
  {:=, _, [{name, _, nil}, value]} = node, acc when name in [:gapped, :escaping] ->
    {node, [{name, value} | acc]}
  node, acc -> {node, acc}
end)
true = Enum.sort(Enum.map(fixtures, &elem(&1, 0))) == [:escaping, :gapped]
production = snapshot |> Path.join("src/lib/aiur/usage_compaction/manifest.ex") |> File.read!() |> Code.string_to_quoted!()
{:defmodule, meta, [_name, body]} = production
Code.compiler_options(ignore_module_conflict: false)
Code.compile_quoted({:defmodule, meta, [ResearchManifestOriginal, body]})
# Bypass only structural block decoding after the checksum gate.
{mutant_body, changes} = Macro.prewalk(body, 0, fn
  {:decode_blocks, _, [{{:., _, [{:__aliases__, _, [:Map]}, :get]}, _, [{:record, _, nil}, "blocks"]}, {:retired_through, _, nil}]}, n ->
    {quote(do: {:ok, []}), n + 1}
  node, n -> {node, n}
end)
1 = changes
Code.compile_quoted({:defmodule, meta, [ResearchManifestBypassedBlocks, mutant_body]})
for {name, ast} <- fixtures do
  {record, _} = Code.eval_quoted(ast)
  false = Map.has_key?(record, "checksum")
  {:error, :invalid_manifest} = ResearchManifestOriginal.from_record(record)
  {:error, :invalid_manifest} = ResearchManifestBypassedBlocks.from_record(record)
  checksum = record |> :erlang.term_to_binary([:deterministic]) |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  signed = Map.put(record, "checksum", checksum)
  {:error, :invalid_manifest} = ResearchManifestOriginal.from_record(signed)
  {:ok, _} = ResearchManifestBypassedBlocks.from_record(signed)
  IO.puts("#{name}: original_fixture_rejects_with_block_validation_bypassed=true; signed_control_detects_bypass=true")
end
