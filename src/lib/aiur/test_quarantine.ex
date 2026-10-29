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
