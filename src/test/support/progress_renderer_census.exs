defmodule Aiur.TestSupport.ProgressRendererCensus do
  @moduledoc false

  @fields [:progress, :progress_resolution, :progress_resolved_count]
  @string_fields Enum.map(@fields, &Atom.to_string/1)

  @template_patterns [
    ~r/\b[a-z_][a-z0-9_]*\.(?:progress|progress_resolution|progress_resolved_count)\b/,
    ~r/\[(?:"progress"|:progress|"progress_resolution"|:progress_resolution|"progress_resolved_count"|:progress_resolved_count)\]/,
    ~r/Map\.(?:get|fetch|fetch!)\([^,\n]+,\s*:(?:progress|progress_resolution|progress_resolved_count)\)/
  ]

  @spec offenders(String.t(), String.t()) :: [String.t()]
  def offenders(relative, source) do
    line_offenders =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, number} ->
        two_state? = String.contains?(line, ["completion_state", "completion_known"])
        template_access? = String.contains?(line, "{") and Enum.any?(@template_patterns, &Regex.match?(&1, line))

        if two_state? or template_access?,
          do: [format(relative, number, String.trim(line))],
          else: []
      end)

    ast_offenders =
      source
      |> Code.string_to_quoted!(columns: true)
      |> accesses()
      |> Enum.map(fn {line, form} -> format(relative, line, form) end)

    Enum.uniq(line_offenders ++ ast_offenders)
  end

  defp accesses(ast) do
    {_ast, accesses} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [left, _right]} = node, acc when kind in [:=, :<-] ->
          {node, pattern_fields(left) ++ acc}

        {:->, _meta, [patterns, _body]} = node, acc ->
          {node, Enum.flat_map(patterns, &pattern_fields/1) ++ acc}

        {kind, _meta, [{_name, _head_meta, args} | _rest]} = node, acc
        when kind in [:def, :defp] and is_list(args) ->
          {node, Enum.flat_map(args, &pattern_fields/1) ++ acc}

        node, acc ->
          case raw_access(node) do
            nil -> {node, acc}
            access -> {node, [access | acc]}
          end
      end)

    Enum.uniq(accesses)
  end

  defp pattern_fields(pattern) do
    {_pattern, fields} =
      Macro.prewalk(pattern, [], fn
        {:%{}, meta, pairs} = node, acc ->
          found =
            for {key, _value} <- pairs,
                key in @fields,
                do: {meta[:line] || 1, Macro.to_string(pattern)}

          {node, found ++ acc}

        node, acc ->
          {node, acc}
      end)

    fields
  end

  defp raw_access({{:., dot_meta, [_receiver, field]}, call_meta, []} = node) when field in @fields,
    do: {call_meta[:line] || dot_meta[:line] || 1, Macro.to_string(node)}

  defp raw_access({{:., _dot_meta, [module, function]}, call_meta, args} = node)
       when function in [:get, :fetch, :fetch!] and is_list(args) do
    if module_name(module) in [Map, Access] and Enum.any?(args, &progress_key?/1),
      do: {call_meta[:line] || 1, Macro.to_string(node)},
      else: nil
  end

  defp raw_access({:get_in, meta, args} = node) when is_list(args) do
    {_args, found?} = Macro.prewalk(args, false, fn child, found? -> {child, found? or progress_key?(child)} end)
    if found?, do: {meta[:line] || 1, Macro.to_string(node)}, else: nil
  end

  defp raw_access(_node), do: nil

  defp module_name({:__aliases__, _meta, parts}), do: Module.concat(parts)
  defp module_name(module) when is_atom(module), do: module
  defp module_name(_module), do: nil

  defp progress_key?(key), do: key in @fields or key in @string_fields
  defp format(relative, line, form), do: "#{relative}:#{line}: #{form}"
end
