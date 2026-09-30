# Parse-only inline scalar literal census. Never compiles or evaluates project code.
defmodule ResearchInlineLiteralCensus do
  def run(root) do
    files = Path.wildcard(Path.join(root, "src/lib/**/*.ex")) |> Enum.sort()

    {inputs, rows} =
      Enum.map_reduce(files, [], fn path, acc ->
        source = File.read!(path)
        ast = Code.string_to_quoted!(source, columns: true, token_metadata: true)
        rel = Path.relative_to(path, root)
        input = %{path: rel, sha256: hash(source)}
        {input, acc ++ walk(ast, nil, rel, nil)}
      end)

    IO.puts(
      JSON.encode!(%{
        files: inputs,
        literals: rows,
        limits:
          "Static binary/integer/float AST leaves outside module-attribute assignments and quote blocks. Source line is the nearest enclosing AST metadata and can be approximate for list elements. This includes function heads and non-constant expressions; it excludes dynamic strings, macro expansions, other file types and semantic units. Equal values are candidate navigation, not duplication evidence."
      })
    )
  end

  defp walk({:quote, _, _}, _, _, _), do: []

  defp walk({:defmodule, meta, [name, body]}, parent, path, inherited_line) do
    local = Macro.to_string(name)

    module =
      if parent && not String.starts_with?(local, ["Aiur.", "AiurWeb.", "Mix.", "Elixir."]),
        do: parent <> "." <> local,
        else: local

    walk(Keyword.fetch!(body, :do), module, path, meta[:line] || inherited_line)
  end

  # Attribute values already have a dedicated census; avoid counting the same
  # declaration a second time as an inline use.
  defp walk({:@, _, _}, _, _, _), do: []

  defp walk({_, meta, args}, module, path, inherited_line)
       when is_list(meta) and is_list(args) do
    line = meta[:line] || inherited_line
    Enum.flat_map(args, &walk(&1, module, path, line))
  end

  # Variable nodes have nil rather than an argument list. Do not descend into
  # their metadata: token line/column integers are not source literals.
  defp walk({_, meta, args}, module, path, inherited_line) when is_list(meta),
    do: walk(args, module, path, meta[:line] || inherited_line)

  defp walk(list, module, path, line) when is_list(list),
    do: Enum.flat_map(list, &walk(&1, module, path, line))

  defp walk(tuple, module, path, line) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.flat_map(&walk(&1, module, path, line))

  defp walk(value, module, path, line) when is_binary(value) and byte_size(value) > 0,
    do: [%{kind: :string, value: value, module: module, path: path, line: line}]

  defp walk(value, module, path, line) when is_integer(value) or is_float(value),
    do: [%{kind: :number, value: value, module: module, path: path, line: line}]

  defp walk(_, _, _, _), do: []

  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end

[root] = System.argv()
ResearchInlineLiteralCensus.run(root)
