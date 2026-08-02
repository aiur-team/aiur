defmodule Aiur.OpenAICompat.BoundedGlob do
  @moduledoc false

  alias Aiur.OpenAICompat.WorkspacePath

  @timeout 30_000

  @spec list(Path.t(), String.t(), pos_integer()) :: {:ok, [Path.t()]} | {:error, term()}
  def list(workspace, glob, limit) when is_binary(workspace) and is_binary(glob) and limit > 0 do
    with {:ok, matcher} <- compile(glob),
         executable when is_binary(executable) <- System.find_executable("find") do
      port =
        Port.open(
          {:spawn_executable, executable},
          [:binary, :exit_status, :hide, args: [workspace, "-mindepth", "1", "-print0"]]
        )

      collect(port, workspace, matcher, limit, "", [])
    else
      nil -> {:error, :file_traversal_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp collect(port, workspace, matcher, limit, pending, matches) do
    receive do
      {^port, {:data, data}} ->
        {paths, pending} = complete_paths(pending <> data)

        case collect_paths(paths, workspace, matcher, limit, matches) do
          {:halt, matches} ->
            close_port(port)
            {:ok, matches |> Enum.reverse() |> Enum.sort()}

          {:cont, matches} ->
            collect(port, workspace, matcher, limit, pending, matches)
        end

      {^port, {:exit_status, 0}} ->
        paths = if pending == "", do: [], else: [pending]

        case collect_paths(paths, workspace, matcher, limit, matches) do
          {_status, matches} -> {:ok, matches |> Enum.reverse() |> Enum.sort()}
        end

      {^port, {:exit_status, status}} ->
        {:error, {:file_traversal_failed, status}}
    after
      @timeout ->
        close_port(port)
        {:error, :file_traversal_timeout}
    end
  end

  defp complete_paths(data) do
    parts = :binary.split(data, <<0>>, [:global])
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp collect_paths(paths, workspace, matcher, limit, matches) do
    Enum.reduce_while(paths, {:cont, matches}, fn absolute, {:cont, current} ->
      relative = Path.relative_to(absolute, workspace)
      collect_path(relative, workspace, matcher, limit, current)
    end)
  end

  defp collect_path(relative, workspace, matcher, limit, matches) do
    if Regex.match?(matcher, relative) and inside_workspace?(workspace, relative) do
      add_match(relative, matches, limit)
    else
      {:cont, {:cont, matches}}
    end
  end

  defp add_match(relative, matches, limit) do
    matches = [relative | matches]
    if length(matches) >= limit, do: {:halt, {:halt, matches}}, else: {:cont, {:cont, matches}}
  end

  defp inside_workspace?(workspace, relative),
    do: match?({:ok, _absolute}, WorkspacePath.resolve(workspace, relative))

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp compile(glob) do
    case glob_fragment(glob, "") do
      {:ok, fragment, ""} -> Regex.compile("\\A#{fragment}\\z", "u")
      _other -> {:error, :invalid_glob}
    end
  end

  defp glob_fragment("", acc), do: {:ok, acc, ""}
  defp glob_fragment(<<"**/", rest::binary>>, acc), do: glob_fragment(rest, acc <> "(?:.*/)?")
  defp glob_fragment(<<"**", rest::binary>>, acc), do: glob_fragment(rest, acc <> ".*")
  defp glob_fragment(<<"*", rest::binary>>, acc), do: glob_fragment(rest, acc <> "[^/]*")
  defp glob_fragment(<<??, rest::binary>>, acc), do: glob_fragment(rest, acc <> "[^/]")

  defp glob_fragment(<<?[, rest::binary>>, acc) do
    with {:ok, class, rest} <- character_class(rest) do
      glob_fragment(rest, acc <> class)
    end
  end

  defp glob_fragment(<<?{, rest::binary>>, acc) do
    with {:ok, alternatives, rest} <- brace_alternatives(rest),
         {:ok, fragments} <- compile_alternatives(alternatives) do
      glob_fragment(rest, acc <> "(?:" <> Enum.join(fragments, "|") <> ")")
    end
  end

  defp glob_fragment(<<?\\, char::utf8, rest::binary>>, acc),
    do: glob_fragment(rest, acc <> Regex.escape(<<char::utf8>>))

  defp glob_fragment(<<char::utf8, rest::binary>>, acc),
    do: glob_fragment(rest, acc <> Regex.escape(<<char::utf8>>))

  defp character_class(rest) do
    case :binary.match(rest, "]") do
      {index, 1} when index > 0 ->
        <<contents::binary-size(index), ?], tail::binary>> = rest
        contents = if String.starts_with?(contents, "!"), do: "^" <> binary_part(contents, 1, byte_size(contents) - 1), else: contents
        {:ok, "[" <> contents <> "]", tail}

      _other ->
        {:error, :invalid_glob}
    end
  end

  defp brace_alternatives(rest), do: take_brace(rest, 0, "", [])

  defp take_brace("", _depth, _current, _alternatives), do: {:error, :invalid_glob}
  defp take_brace(<<?}, tail::binary>>, 0, current, alternatives), do: {:ok, Enum.reverse([current | alternatives]), tail}
  defp take_brace(<<?,, tail::binary>>, 0, current, alternatives), do: take_brace(tail, 0, "", [current | alternatives])
  defp take_brace(<<?{, tail::binary>>, depth, current, alternatives), do: take_brace(tail, depth + 1, current <> "{", alternatives)
  defp take_brace(<<?}, tail::binary>>, depth, current, alternatives), do: take_brace(tail, depth - 1, current <> "}", alternatives)

  defp take_brace(<<char::utf8, tail::binary>>, depth, current, alternatives),
    do: take_brace(tail, depth, current <> <<char::utf8>>, alternatives)

  defp compile_alternatives(alternatives) do
    Enum.reduce_while(alternatives, {:ok, []}, fn alternative, {:ok, fragments} ->
      case glob_fragment(alternative, "") do
        {:ok, fragment, ""} -> {:cont, {:ok, [fragment | fragments]}}
        _other -> {:halt, {:error, :invalid_glob}}
      end
    end)
    |> case do
      {:ok, fragments} -> {:ok, Enum.reverse(fragments)}
      error -> error
    end
  end
end
