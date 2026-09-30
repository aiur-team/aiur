# Syntax-only regex census, including inline sigils. No compilation/evaluation.
defmodule ResearchRegexCensus do
  def run(root) do
    files = Path.wildcard(Path.join(root, "src/lib/**/*.ex")) |> Enum.sort()
    inputs = Enum.map(files, fn path -> %{path: Path.relative_to(path, root), sha256: hash(File.read!(path))} end)
    rows = Enum.flat_map(files, fn path ->
      path |> File.read!() |> Code.string_to_quoted!(columns: true) |> walk(nil, Path.relative_to(path, root))
    end)
    groups = rows |> Enum.group_by(& &1.expression_sha256) |> Enum.flat_map(fn {key, sites} ->
      modules = sites |> Enum.map(& &1.module) |> Enum.uniq() |> length()
      if modules > 1, do: [%{expression_sha256: key, modules: modules, sites: sites}], else: []
    end) |> Enum.sort_by(&{-&1.modules, &1.expression_sha256})
    IO.puts(JSON.encode!(%{status: "in-progress", files: inputs, sigil_sites: length(rows),
      cross_module_groups: groups,
      limits: "Literal r/R sigil AST nodes outside quote blocks. Includes attributes and inline uses; overlaps attribute census. Flags and interpolation expressions are preserved. Dynamic Regex.compile strings and macro-generated sigils are excluded. Matching syntax does not prove identical validation contracts."}))
  end
  defp walk({:quote, _, _}, _, _), do: []
  defp walk({:defmodule, _, [name, body]}, parent, path) do
    local = Macro.to_string(name)
    module = if parent && not String.starts_with?(local, ["Aiur.", "AiurWeb.", "Mix.", "Elixir."]), do: parent <> "." <> local, else: local
    walk(Keyword.fetch!(body, :do), module, path)
  end
  defp walk({kind, meta, _} = node, module, path) when kind in [:sigil_r, :sigil_R] do
    expression = node |> Macro.prewalk(fn
      {form, metadata, args} when is_list(metadata) -> {form, [], args}
      other -> other
    end) |> Macro.to_string()
    [%{path: path, module: module, line: meta[:line], expression: expression, expression_sha256: hash(expression)}]
  end
  defp walk(list, module, path) when is_list(list), do: Enum.flat_map(list, &walk(&1, module, path))
  defp walk(tuple, module, path) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.flat_map(&walk(&1, module, path))
  defp walk(_, _, _), do: []
  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
[root] = System.argv()
ResearchRegexCensus.run(root)
