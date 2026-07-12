defmodule Aiur.Init.Dotenv do
  @moduledoc """
  Loads `.env` key=value pairs into the process environment for the `aiur init`
  wizard. `aiur init` runs as a bare foreground process (the launcher only
  sources .env for the running app, not init), so a GITHUB_TOKEN the operator
  placed in the repo's .env is not yet in the environment.
  """

  @env_file_name ".env"

  # existing env always wins / values never logged
  @spec load() :: :ok
  def load do
    path = Path.join(File.cwd!(), @env_file_name)

    case File.read(path) do
      {:ok, content} -> Enum.each(parse(content), &put_env_if_unset/1)
      {:error, _} -> :ok
    end
  end

  defp put_env_if_unset({key, value}) do
    if System.get_env(key) in [nil, ""], do: System.put_env(key, value)
    :ok
  end

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
