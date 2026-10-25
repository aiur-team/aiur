defmodule Aiur.Env.Dotenv do
  @moduledoc "Pure parser for dotenv key/value pairs."

  @spec parse(String.t(), keyword()) :: [{String.t(), String.t()}]
  def parse(content, opts \\ []) do
    include_empty? = Keyword.get(opts, :include_empty, false)

    content
    |> String.split("\n")
    |> Enum.flat_map(&parse_dotenv_line(&1, include_empty?))
  end

  defp parse_dotenv_line(line, include_empty?) do
    trimmed = String.trim(line)

    if trimmed == "" or String.starts_with?(trimmed, "#") do
      []
    else
      parse_dotenv_pair(trimmed, include_empty?)
    end
  end

  defp parse_dotenv_pair(trimmed, include_empty?) do
    case String.split(trimmed, "=", parts: 2) do
      [key, raw] ->
        case dotenv_value(raw) do
          "" when not include_empty? -> []
          value -> [{String.trim(key), value}]
        end

      _ ->
        []
    end
  end

  defp dotenv_value(raw), do: raw |> String.trim() |> String.trim("\"") |> String.trim("'")
end
