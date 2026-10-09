defmodule Aiur.GitHub.CodeownersPattern do
  @moduledoc "Path matching for parsed CODEOWNERS rules."

  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(pattern, path) do
    path = normalize_path(path)
    pattern = String.trim(pattern)

    cond do
      pattern == "*" ->
        path != ""

      String.ends_with?(pattern, "/") ->
        directory_pattern_matches?(pattern, path)

      String.starts_with?(pattern, "/") ->
        pattern
        |> String.trim_leading("/")
        |> glob_match?(path)

      String.contains?(pattern, "/") ->
        glob_match?(pattern, path)

      true ->
        glob_match?(pattern, Path.basename(path))
    end
  end

  defp directory_pattern_matches?(pattern, path) do
    directory =
      pattern
      |> String.trim_leading("/")
      |> String.trim_trailing("/")

    path == directory or String.starts_with?(path, directory <> "/")
  end

  defp glob_match?(pattern, path) do
    pattern
    |> glob_regex()
    |> Regex.match?(path)
  end

  defp glob_regex(pattern) do
    pattern =
      pattern
      |> String.graphemes()
      |> glob_regex_parts([])
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    Regex.compile!("^" <> pattern <> "$")
  end

  defp glob_regex_parts([], acc), do: acc
  defp glob_regex_parts(["*", "*" | rest], acc), do: glob_regex_parts(rest, [".*" | acc])
  defp glob_regex_parts(["*" | rest], acc), do: glob_regex_parts(rest, ["[^/]*" | acc])
  defp glob_regex_parts(["?" | rest], acc), do: glob_regex_parts(rest, ["[^/]" | acc])
  defp glob_regex_parts([char | rest], acc), do: glob_regex_parts(rest, [Regex.escape(char) | acc])

  defp normalize_path(path) do
    path
    |> String.trim()
    |> String.trim_leading("./")
    |> String.trim_leading("/")
  end
end
