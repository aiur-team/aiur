defmodule Aiur.GitHub.CodeownersFile do
  @moduledoc "Shared CODEOWNERS grammar and file reader."

  @spec read(Path.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def read(nil), do: {:error, :missing}

  def read(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, :enoent} -> {:error, :missing}
      {:error, reason} -> {:error, {:file_read_failed, reason}}
    end
  end

  @spec parse(String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse(content) do
    content
    |> String.split(~r/\R/)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, &parse_line/2)
    |> finish()
  end

  defp parse_line({line, number}, {:ok, rules}) do
    tokens = line |> String.split(~r/\s+/, trim: true) |> Enum.take_while(&(not String.starts_with?(&1, "#")))

    case tokens do
      [] -> {:cont, {:ok, rules}}
      [pattern | owners] -> parse_rule(pattern, owners, number, rules)
    end
  end

  defp parse_rule(pattern, owners, number, rules) do
    if not String.starts_with?(pattern, "!") and not String.contains?(pattern, "[") and Enum.all?(owners, &valid_owner?/1) do
      {:cont, {:ok, [%{pattern: pattern, owners: owners} | rules]}}
    else
      {:halt, {:error, {:unparseable, number}}}
    end
  end

  defp valid_owner?("@" <> owner), do: Regex.match?(~r/^[A-Za-z0-9_-]+(?:\/[A-Za-z0-9_-]+)?(?:\[bot\])?$/, owner)
  defp valid_owner?(owner), do: Regex.match?(~r/^[^@\s]+@[^@\s]+$/, owner)

  defp finish({:ok, []}), do: {:error, :empty}
  defp finish({:ok, rules}), do: {:ok, Enum.reverse(rules)}
  defp finish(error), do: error
end
