# Ported from research/refactor-findings f09e6e5d0, tooling/module_references.exs.
# Parse source without compiling/loading project modules. Output is TSV:
# M path module; R path source target kind line. This is a source-reference
# graph, not a runtime call graph. Docs are excluded; aliases/literals are
# emitted separately for non-allowlistable namespace restrictions.
defmodule ComponentModuleReferences do
  def run(root, paths \\ nil) do
    (paths || Path.wildcard(Path.join(root, "src/lib/**/*.ex")))
    |> Enum.sort()
    |> Enum.each(fn path ->
      ast = path |> File.read!() |> Code.string_to_quoted!(columns: true, file: path)
      env = %{module: nil, aliases: %{}, primary: nil, path: Path.relative_to(path, root)}
      walk(ast, env)
    end)
  end

  defp walk({:defmodule, _, [name_ast, body]}, env) do
    name = module_name(name_ast, env)

    primary = env.primary || if(name == "Aiur", do: "Aiur.Application", else: name)
    env = %{env | primary: primary}
    IO.puts(Enum.join(["M", env.path, name], "\t"))
    walk(Keyword.fetch!(body, :do), %{env | module: name})

    case name_ast do
      {:__aliases__, _, [local]} when is_atom(local) and not is_nil(env.module) ->
        %{env | aliases: Map.put(env.aliases, Atom.to_string(local), name)}

      _ ->
        env
    end
  end

  defp walk({:__block__, _, expressions}, env), do: Enum.reduce(expressions, env, &walk/2)

  defp walk({:alias, metadata, [target | opts]}, env) do
    options = List.flatten(opts)
    names = alias_names(target, env)
    Enum.each(names, &emit(&1, "alias", metadata[:line] || 0, env))

    aliases =
      Enum.reduce(names, env.aliases, fn name, aliases ->
        local =
          case Keyword.get(options, :as) do
            nil -> name |> String.split(".") |> List.last()
            as -> resolve(as, %{env | aliases: %{}})
          end

        Map.put(aliases, local, name)
      end)

    %{env | aliases: aliases}
  end

  defp walk({:@, _, [{attribute, _, _}]}, env) when attribute in [:doc, :moduledoc, :typedoc], do: env

  defp walk({:@, metadata, [{:behaviour, _, [target]}]}, env) do
    emit(resolve(target, env), "behaviour", metadata[:line] || 0, env)
    env
  end

  defp walk({:__aliases__, metadata, _} = reference, env) do
    emit(resolve(reference, env), "reference", metadata[:line] || 0, env)
    env
  end

  defp walk({kind, _, args}, env) when is_list(args) do
    # Alias scope inside functions/branches must not escape to sibling forms.
    walk(kind, env)
    Enum.reduce(args, env, &walk/2)
    env
  end

  defp walk(list, env) when is_list(list), do: Enum.reduce(list, env, &walk/2)

  defp walk(tuple, env) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.reduce(env, &walk/2)
    env
  end

  defp walk(value, env) when is_binary(value) or is_atom(value) do
    value = to_string(value) |> String.trim_leading("Elixir.")
    if Regex.match?(~r/^(Aiur|AiurWeb)(\.[A-Z][A-Za-z0-9_]*)+$/, value), do: emit(value, "literal", 0, env)
    env
  end

  defp walk(_, env), do: env

  defp emit(target, kind, line, env) do
    if env.module, do: IO.puts(Enum.join(["R", env.path, env.primary, target, kind, line], "\t"))
  end

  defp alias_names({{:., _, [prefix, :{}]}, _, children}, env) do
    for child <- children, do: resolve(prefix, env) <> "." <> resolve(child, %{env | aliases: %{}})
  end

  defp alias_names(target, env), do: [resolve(target, env)]

  defp module_name(ast, env) do
    name = resolve(ast, env)

    absolute =
      case ast do
        {:__aliases__, _, [first | _]} when is_atom(first) ->
          first == :"Elixir" or Map.has_key?(env.aliases, Atom.to_string(first))

        _ ->
          true
      end

    if env.module && not absolute, do: env.module <> "." <> name, else: name
  end

  defp resolve({:__MODULE__, _, _}, env), do: env.module || "__MODULE__"

  defp resolve({:__aliases__, _, parts}, env) do
    [first | rest] =
      Enum.map(parts, fn
        {:__MODULE__, _, _} -> env.module || "__MODULE__"
        part when is_atom(part) -> Atom.to_string(part)
      end)

    Enum.join([Map.get(env.aliases, first, first) | rest], ".")
    |> String.trim_leading("Elixir.")
  end

  defp resolve(atom, _) when is_atom(atom), do: atom |> Atom.to_string() |> String.trim_leading("Elixir.")
end

case System.argv() do
  [root] -> ComponentModuleReferences.run(root)
  [root, "--files" | paths] -> ComponentModuleReferences.run(root, Enum.map(paths, &Path.join(root, &1)))
end
