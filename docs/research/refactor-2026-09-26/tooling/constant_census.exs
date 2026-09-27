# Parse-only candidate census. Never evaluates project code or expands macros.
defmodule ResearchConstantCensus do
  @excluded ~w(doc moduledoc typedoc spec type typep opaque callback macrocallback impl behaviour compile derive external_resource before_compile after_compile on_definition)a
  def run(root) do
    files = Path.wildcard(Path.join(root, "src/lib/**/*.ex")) |> Enum.sort()
    {inputs, rows} = Enum.map_reduce(files, [], fn path, acc ->
      source = File.read!(path)
      ast = Code.string_to_quoted!(source, columns: true, token_metadata: true)
      rel = Path.relative_to(path, root)
      {%{path: rel, sha256: hash(source)}, acc ++ walk(ast, nil, rel)}
    end)
    IO.puts(JSON.encode!(%{files: inputs, attributes: rows,
      limits: "Literal module-attribute assignments outside quote blocks. Excludes compiler/docs/type attributes. Numeric evaluation is restricted to literal +, -, *, div; all other expressions remain symbolic. No macro expansion, inferred units, transitive values, inline literal census or semantic equivalence claimed."}))
  end
  defp walk({:quote, _, _}, _, _), do: []
  defp walk({:defmodule, _, [name, body]}, parent, path) do
    local = Macro.to_string(name)
    module = if parent && not String.starts_with?(local, ["Aiur.", "AiurWeb.", "Mix.", "Elixir."]), do: parent <> "." <> local, else: local
    walk(Keyword.fetch!(body, :do), module, path)
  end
  defp walk({:@, meta, [{name, _, [value]}]}, module, path) when name not in @excluded do
    expression = value |> clean() |> Macro.to_string()
    [%{path: path, module: module, name: Atom.to_string(name), line: meta[:line],
      expression: expression, numeric_value: number(value), expression_sha256: hash(expression)}]
  end
  defp walk({:@, _, _}, _, _), do: []
  defp walk(list, module, path) when is_list(list), do: Enum.flat_map(list, &walk(&1, module, path))
  defp walk(tuple, module, path) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.flat_map(&walk(&1, module, path))
  defp walk(_, _, _), do: []
  defp number(n) when is_number(n), do: n
  defp number({:-, _, [x]}) do
    case number(x) do
      n when is_number(n) -> -n
      _ -> nil
    end
  end
  defp number({op, _, [x, y]}) when op in [:+, :-, :*, :div] do
    case {number(x), number(y)} do
      {a, b} when is_number(a) and is_number(b) ->
        case op do
          :+ -> a + b
          :- -> a - b
          :* -> a * b
          :div -> if is_integer(a) and is_integer(b) and b != 0, do: div(a, b), else: nil
        end
      _ -> nil
    end
  end
  defp number(_), do: nil
  defp clean(ast), do: Macro.prewalk(ast, fn
    {form, metadata, args} when is_list(metadata) -> {form, [], args}
    node -> node
  end)
  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
[root] = System.argv()
ResearchConstantCensus.run(root)
