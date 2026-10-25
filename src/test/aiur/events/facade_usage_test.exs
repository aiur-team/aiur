defmodule Aiur.Events.FacadeUsageTest do
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)
  @internals ~w(Aiur.Events.Publisher Aiur.Events.Exchange Aiur.Events.IdGenerator Aiur.Events.Topic)

  # Supervision and availability checks retain registered process identities.
  # Invoking the bus must cross its facade.
  test "no production module outside the bus calls bus internals directly" do
    violations =
      for path <- Path.wildcard(Path.join(@lib, "**/*.ex")),
          Path.relative_to(path, @lib) != "aiur/events.ex",
          not String.starts_with?(Path.relative_to(path, @lib), "aiur/events/"),
          call <- internal_calls(File.read!(path)),
          do: "#{Path.relative_to(path, @lib)}: #{call}"

    assert violations == []
  end

  defp internal_calls(source) do
    ast = Code.string_to_quoted!(source)
    {_, aliases} = Macro.prewalk(ast, %{}, &collect_aliases/2)

    {_, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, parts}, function]}, _, _} = node, calls ->
          module = expand(parts, aliases)
          {node, if(module in @internals, do: ["#{module}.#{function}" | calls], else: calls)}

        node, calls ->
          {node, calls}
      end)

    Enum.uniq(calls)
  end

  defp collect_aliases({:alias, _, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, members}]} = node, aliases) do
    aliases = Enum.reduce(members, aliases, fn {:__aliases__, _, parts}, acc -> Map.put(acc, List.last(parts), Enum.join(prefix ++ parts, ".")) end)
    {node, aliases}
  end

  defp collect_aliases({:alias, _, [{:__aliases__, _, parts} | opts]} = node, aliases) do
    name =
      case Keyword.get(List.flatten(opts), :as) do
        {:__aliases__, _, [name]} -> name
        nil -> List.last(parts)
      end

    {node, Map.put(aliases, name, Enum.join(parts, "."))}
  end

  defp collect_aliases(node, aliases), do: {node, aliases}

  defp expand([first | rest] = parts, aliases) do
    if Enum.all?(parts, &is_atom/1), do: Enum.join([Map.get(aliases, first, first) | rest], "."), else: ""
  end
end
