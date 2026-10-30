defmodule Aiur.TestQuarantine do
  @moduledoc "Parses the repository test quarantine list and derives ExUnit exclusions."

  @type entry :: %{module: String.t(), name: String.t(), ticket: String.t(), expires: Date.t()}

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

  @doc "Inserts a quarantine row while preserving the validator's module/name ordering."
  @spec insert_sorted(String.t(), String.t()) :: String.t()
  def insert_sorted(contents, row) when is_binary(contents) and is_binary(row) do
    rows = String.split(String.trim_trailing(contents), "\n", trim: true)
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

  defp valid_module?("*"), do: true
  defp valid_module?(module), do: Regex.match?(~r/^Aiur(?:Web)?(?:\.[A-Za-z0-9_]+)+$/, module)
  defp valid_ticket?(ticket), do: Regex.match?(~r/^#?[1-9][0-9]*$/, ticket)
end
