defmodule Aiur.TestQuarantine do
  @moduledoc "Parses the repository test quarantine list and derives ExUnit exclusions."

  @type entry :: %{module: String.t(), name: String.t(), ticket: String.t(), expires: Date.t()}

  @module_pattern ~r/^\s*defmodule\s+([A-Za-z0-9_.]+)\s+do\b/
  @describe_pattern ~r/^\s*describe\s+"((?:[^"\\]|\\.)*)"/
  @test_pattern ~r/^\s*test\s+"((?:[^"\\]|\\.)*)"/

  @spec read(Path.t()) :: {:ok, [entry()]} | {:error, term()}
  def read(path), do: File.read(path) |> then(&parse_result/1)

  @spec parse(String.t()) :: {:ok, [entry()]} | {:error, term()}
  def parse(contents) when is_binary(contents) do
    contents
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, &parse_line/2)
    |> reverse_entries()
  end

  @spec filters([entry()]) :: keyword()
  def filters(entries) do
    entries
    |> Enum.map(&filter/1)
    |> Enum.uniq()
  end

  @doc "Sorts quarantine entries in the order enforced by the quarantine list validator."
  @spec sort_key(%{required(:module) => String.t(), required(:name) => String.t()}) ::
          {String.t(), String.t()}
  def sort_key(%{module: module, name: name}), do: {module, name}

  @doc false
  @spec test_name_occurrences(String.t(), Path.t()) :: [{String.t(), Path.t(), pos_integer()}]
  def test_name_occurrences(name, tests_root) do
    tests_root
    |> Path.join("**/*_test.exs")
    |> Path.wildcard()
    |> Enum.flat_map(&test_file_occurrences(&1, name))
  end

  @doc "Inserts a quarantine row while preserving the validator's module/name ordering."
  @spec insert_sorted(String.t(), String.t()) :: String.t()
  def insert_sorted(contents, row) when is_binary(contents) and is_binary(row) do
    rows =
      if contents == "" do
        []
      else
        rows = String.split(contents, "\n", trim: false)
        if String.ends_with?(contents, "\n"), do: Enum.drop(rows, -1), else: rows
      end

    identity = row_identity(row)

    {before, after_rows} =
      Enum.split_while(rows, fn existing ->
        case row_identity(existing) do
          nil -> true
          existing_identity -> existing_identity <= identity
        end
      end)

    (before ++ [row] ++ after_rows)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp row_identity(row) do
    case String.split(row, "\t", parts: 3) do
      [module, name, _] -> sort_key(%{module: module, name: name})
      _ -> nil
    end
  end

  defp test_file_occurrences(path, requested_name) do
    path
    |> File.stream!()
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, &scan_test_line(path, requested_name, &1, &2))
    |> elem(1)
    |> Enum.reverse()
  end

  defp scan_test_line(path, requested_name, {line, line_number}, {stack, found}) do
    if String.trim(line) == "" do
      {stack, found}
    else
      indent = String.length(line) - String.length(String.trim_leading(line))
      stack = pop_scopes(stack, indent)
      context = %{indent: indent, stack: stack, module: scope_value(stack, :module)}
      handle_test_line(classify_test_line(line), context, path, line_number, requested_name, found)
    end
  end

  defp pop_scopes(stack, indent),
    do: Enum.drop_while(stack, fn {depth, _kind, _value} -> indent <= depth end)

  defp scope_value(stack, kind),
    do: Enum.find_value(stack, fn {_depth, scope_kind, value} -> if scope_kind == kind, do: value end)

  defp classify_test_line(line) do
    case Regex.run(@module_pattern, line) do
      [_, child] -> {:module, child}
      _ -> classify_description_or_test(line)
    end
  end

  defp classify_description_or_test(line) do
    case Regex.run(@describe_pattern, line) do
      [_, description] -> {:describe, description}
      _ -> classify_test_name(line)
    end
  end

  defp classify_test_name(line) do
    case Regex.run(@test_pattern, line) do
      [_, name] -> {:test, name}
      _ -> :other
    end
  end

  defp handle_test_line({:module, child}, context, _path, _line_number, _requested_name, found) do
    full_name = qualify_module(context.module, child)
    {[{context.indent, :module, full_name} | context.stack], found}
  end

  defp handle_test_line({:describe, raw_description}, context, _path, _line_number, _requested_name, found) do
    description = Macro.unescape_string(raw_description)
    {[{context.indent, :describe, description} | context.stack], found}
  end

  defp handle_test_line({:test, _raw_name}, %{module: nil} = context, _path, _line_number, _requested_name, found),
    do: {context.stack, found}

  defp handle_test_line({:test, raw_name}, context, path, line_number, requested_name, found) do
    test_name = qualify_test_name(scope_value(context.stack, :describe), Macro.unescape_string(raw_name))
    found = if test_name == requested_name, do: [{context.module, path, line_number} | found], else: found
    {context.stack, found}
  end

  defp handle_test_line(:other, context, _path, _line_number, _requested_name, found), do: {context.stack, found}

  defp qualify_module(nil, child), do: child
  defp qualify_module(parent, child), do: parent <> "." <> child

  defp qualify_test_name(nil, name), do: name
  defp qualify_test_name(description, name), do: description <> " " <> name

  defp filter(%{module: module, name: "*"}), do: {:module, String.to_atom(module)}
  defp filter(%{name: name}), do: {:test, String.to_atom("test " <> name)}

  defp parse_line({line, number}, {:ok, entries}) do
    line = String.trim(line)

    if line == "" or String.starts_with?(line, "#"), do: {:cont, {:ok, entries}}, else: parse_entry(line, number, entries)
  end

  defp parse_result({:ok, contents}), do: parse(contents)
  defp parse_result(error), do: error

  defp parse_entry(line, number, entries) do
    case String.split(line, "\t", trim: false) do
      [module, name, ticket, expires] when module != "" and name != "" and ticket != "" and expires != "" ->
        with true <- valid_module?(module) and valid_ticket?(ticket),
             {:ok, date} <- Date.from_iso8601(expires) do
          {:cont, {:ok, [%{module: module, name: name, ticket: ticket, expires: date} | entries]}}
        else
          _ -> {:halt, {:error, {:invalid_quarantine_entry, number, "expected module, name, ticket, and YYYY-MM-DD expiry"}}}
        end

      _ ->
        {:halt, {:error, {:invalid_quarantine_entry, number}}}
    end
  end

  defp reverse_entries({:ok, entries}), do: {:ok, Enum.reverse(entries)}
  defp reverse_entries(error), do: error

  defp valid_module?(module), do: Regex.match?(~r/^Aiur(?:Web)?(?:\.[A-Za-z0-9_]+)+$/, module)
  defp valid_ticket?(ticket), do: Regex.match?(~r/^#?[1-9][0-9]*$/, ticket)
end
