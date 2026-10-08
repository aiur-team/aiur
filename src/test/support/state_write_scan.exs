defmodule Aiur.StateWriteScan do
  @moduledoc false

  @spec scan_source(String.t(), [atom()]) :: MapSet.t()
  def scan_source(source, fields) do
    context = %{fields: MapSet.new(fields), state_module?: Regex.match?(~r/\bState\b/, source)}
    walk(Code.string_to_quoted!(source), nil, context, MapSet.new())
  end

  defp walk({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, _module, context, writes),
    do: walk(body, Module.concat(parts), context, writes)

  defp walk(ast, module, context, writes) when is_tuple(ast) do
    writes = Enum.reduce(write_fields(ast, context), writes, &MapSet.put(&2, {module, &1}))
    Enum.reduce(Tuple.to_list(ast), writes, &walk(&1, module, context, &2))
  end

  defp walk(nodes, module, context, writes) when is_list(nodes),
    do: Enum.reduce(nodes, writes, &walk(&1, module, context, &2))

  defp walk(_ast, _module, _context, writes), do: writes

  defp write_fields({:%{}, _, [{:|, _, [target, updates]}]}, context) do
    if state_target?(target, context), do: known_fields(Enum.map(updates, &elem(&1, 0)), context), else: []
  end

  defp write_fields({{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [target, field, _value]}, context),
    do: write_to(target, field, context)

  defp write_fields({:|>, _, [target, {{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [field, _value]}]}, context),
    do: write_to(target, field, context)

  defp write_fields({operation, _, [path, _value]}, context) when operation in [:put_in, :update_in] do
    case root_field(path) do
      {target, field} -> write_to(target, field, context)
      nil -> []
    end
  end

  defp write_fields({operation, _, [target, [field | _keys], _value]}, context) when operation in [:put_in, :update_in],
    do: write_to(target, field, context)

  defp write_fields(_ast, _context), do: []

  defp write_to(target, field, context) do
    if state_target?(target, context), do: known_fields([field], context), else: []
  end

  defp known_fields(fields, context), do: Enum.filter(fields, &MapSet.member?(context.fields, &1))

  # Conservative within State-using files: unrelated maps become reasoned allowlist rows.
  # ponytail: dynamic field keys are not classified; add data-flow analysis if State starts using them.
  defp state_target?({name, _, scope}, context) when is_atom(name) and is_atom(scope),
    do: name == :state or context.state_module?

  defp state_target?({:%, _, [_module, _map]}, _context), do: true
  defp state_target?(_target, _context), do: false

  defp root_field({{:., _, [target, field]}, _, []}) do
    root_field(target) || {target, field}
  end

  defp root_field({{:., _, [Access, :get]}, _, [target, field]}) do
    root_field(target) || {target, field}
  end

  defp root_field(_path), do: nil
end
