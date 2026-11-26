defmodule Aiur.GitHub.CodeownersPattern do
  @moduledoc """
  Path matching for parsed CODEOWNERS rules, with GitHub's gitignore semantics:
  a pattern without a leading or middle `/` matches at any depth, a trailing
  `/` matches directories only, and a matched directory owns everything in it,
  except that `dir/*` owns only the direct children of `dir`.
  """

  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(pattern, path) do
    components = path |> normalize_path() |> String.split("/", trim: true)
    pattern = String.trim(pattern)
    directory_only? = String.ends_with?(pattern, "/")
    body = String.trim_trailing(pattern, "/")
    anchored? = String.contains?(body, "/")
    regex = body |> String.trim_leading("/") |> glob_regex()
    candidates = if directory_only?, do: Enum.drop(components, -1), else: components
    direct_children_only? = String.ends_with?(body, "/*")

    candidates
    |> Enum.with_index(1)
    |> Enum.any?(fn {component, depth} ->
      cond do
        direct_children_only? and depth != length(components) -> false
        anchored? -> Regex.match?(regex, components |> Enum.take(depth) |> Enum.join("/"))
        true -> Regex.match?(regex, component)
      end
    end)
  end

  defp glob_regex(pattern) do
    pattern
    |> String.graphemes()
    |> glob_regex_parts([])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> then(&Regex.compile!("^" <> &1 <> "$"))
  end

  defp glob_regex_parts([], acc), do: acc
  defp glob_regex_parts(["*", "*", "/" | rest], acc), do: glob_regex_parts(rest, ["(?:.*/)?" | acc])
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
