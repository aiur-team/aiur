# Parse only: never compile or load project modules. Body hashes are syntactic
# candidates, not semantic equivalence (aliases/imports/attributes can differ).
defmodule ResearchFunctionCensus do
  def run(root) do
    files = Path.wildcard(Path.join(root, "src/lib/**/*.ex")) |> Enum.sort()
    rows = Enum.flat_map(files, fn path ->
      source = File.read!(path)
      ast = Code.string_to_quoted!(source, columns: true, token_metadata: true)
      walk(ast, nil, Path.relative_to(path, root))
    end)
    inputs = Enum.map(files, fn path ->
      %{path: Path.relative_to(path, root), sha256: hash(File.read!(path))}
    end)
    IO.puts(JSON.encode!(%{files: inputs, definitions: rows,
      limits: "Literal def/defp/defmacro/defmacrop/defdelegate AST nodes in src/lib/**/*.ex. Quoted generated code is excluded; macro expansion is not performed. Default arguments use declared arity, not expanded callable arities. Body hashes retain variables and literal values while removing AST metadata. Matching hashes are not proof of semantic equivalence."}))
  end

  defp walk({:quote, _, _}, _, _), do: []
  defp walk({:defmodule, _, [name, body]}, parent, path) do
    local = Macro.to_string(name)
    module = if parent && not String.starts_with?(local, ["Aiur.", "AiurWeb.", "Mix.", "Elixir."]), do: parent <> "." <> local, else: local
    walk(Keyword.fetch!(body, :do), module, path)
  end
  defp walk({kind, meta, [head | tail]} = node, module, path)
       when kind in [:def, :defp, :defmacro, :defmacrop, :defdelegate] do
    {name, arity} = signature(head)
    normalized = tail |> clean() |> Macro.to_string()
    [%{path: path, module: module, kind: Atom.to_string(kind), name: name,
       arity: arity, line: meta[:line], end_line: end_line(node),
       body_sha256: hash(normalized), normalized_body_lines: length(String.split(normalized, "\n")),
       has_body: tail != []}]
  end
  defp walk(list, module, path) when is_list(list), do: Enum.flat_map(list, &walk(&1, module, path))
  defp walk(tuple, module, path) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.flat_map(&walk(&1, module, path))
  defp walk(_, _, _), do: []
  defp signature({:when, _, [head | _]}), do: signature(head)
  defp signature({name, _, args}) when is_atom(name), do: {Atom.to_string(name), if(is_list(args), do: length(args), else: 0)}
  defp signature(other), do: {Macro.to_string(other), nil}
  defp clean(ast), do: Macro.prewalk(ast, fn
    {form, metadata, args} when is_list(metadata) -> {form, [], args}
    other -> other
  end)
  defp end_line(ast) do
    {_, lines} = Macro.prewalk(ast, [], fn
      {_, metadata, _} = node, acc when is_list(metadata) ->
        ends = for key <- [:end, :closing, :end_of_expression], value = metadata[key], is_list(value), is_integer(value[:line]), do: value[:line]
        {node, [metadata[:line] || 0 | ends ++ acc]}
      node, acc -> {node, acc}
    end)
    Enum.max(lines, fn -> 0 end)
  end
  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
[root] = System.argv()
ResearchFunctionCensus.run(root)
