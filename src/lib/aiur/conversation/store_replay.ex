defmodule Aiur.Conversation.StoreReplay do
  @moduledoc false

  alias Aiur.Conversation.Store
  alias Aiur.Journal

  @spec positions([map()], non_neg_integer()) :: :ok | {:error, :invalid_position}
  def positions(records, previous) do
    Enum.reduce_while(records, previous, fn
      %{"v" => 1, "pos" => pos}, last when is_integer(pos) and pos > last -> {:cont, pos}
      _, _ -> {:halt, :invalid_position}
    end)
    |> case do
      :invalid_position -> {:error, :invalid_position}
      _ -> :ok
    end
  end

  @spec head(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def head(dir, opts \\ []) do
    with {:ok, names} <- segments(dir),
         {:ok, result} <- replay_segments(dir, names),
         :ok <- complete(Path.join(dir, "sessions.jsonl")),
         {:ok, sessions, nil} <-
           Journal.replay(Path.join(dir, "sessions.jsonl"), &session/1, repair_torn_tail: false),
         {:ok, stat} <- File.stat(Path.join(dir, "sessions.jsonl")),
         :ok <- sync_recovered(dir, names, Keyword.get(opts, :file_ops, :file)) do
      seq = Enum.reduce(sessions, 0, &max(&1["session_seq"], &2))
      {:ok, Map.merge(result, %{"last_session_seq" => seq, "sessions_bytes" => stat.size})}
    else
      {:ok, _, {:corrupt, line, _}} -> {:error, {:corrupt, "sessions.jsonl", line}}
      error -> error
    end
  end

  @spec current?(Path.t(), term()) :: boolean()
  def current?(dir, %{
        "v" => 1,
        "last_pos" => last,
        "last_session_seq" => seq,
        "segments" => segments,
        "sessions_bytes" => bytes
      })
      when is_integer(last) and last >= 0 and is_integer(seq) and seq >= 0 and is_list(segments) do
    with {:ok, names} <- segments(dir),
         true <- valid_ranges?(segments, last),
         true <- names == Enum.map(segments, & &1["n"]),
         {:ok, stat} <- File.stat(Path.join(dir, "sessions.jsonl")) do
      bytes == stat.size and valid_ranges?(segments, last) and
        Enum.all?(segments, &same_size?(Store.segment_path(dir, &1["n"]), &1["bytes"]))
    else
      _ -> false
    end
  end

  def current?(_dir, _head), do: false

  @spec segment(Path.t(), non_neg_integer(), boolean()) :: {:ok, [map()]} | {:error, term()}
  def segment(path, previous, repair?) do
    with :ok <- complete_old_segment(path, repair?),
         {:ok, records, nil} <- Journal.replay(path, &entry/1, repair_torn_tail: repair?),
         :ok <- ordered(records, previous, path) do
      {:ok, records}
    else
      {:ok, _, {:corrupt, line, _}} -> {:error, {:corrupt, Path.basename(path), line}}
      error -> error
    end
  end

  defp replay_segments(dir, names) do
    initial = %{"v" => 1, "last_pos" => 0, "segments" => []}

    Enum.reduce_while(names, {:ok, initial}, fn n, {:ok, head} ->
      path = Store.segment_path(dir, n)

      with {:ok, records} <- segment(path, head["last_pos"], n == List.last(names)),
           {:ok, stat} <- File.stat(path) do
        summary = segment_summary(n, records, head["last_pos"], stat.size)

        {:cont, {:ok, %{head | "last_pos" => summary["last_pos"], "segments" => head["segments"] ++ [summary]}}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp segment_summary(n, [], previous, bytes),
    do: %{"n" => n, "first_pos" => nil, "last_pos" => previous, "bytes" => bytes}

  defp segment_summary(n, records, _previous, bytes),
    do: %{
      "n" => n,
      "first_pos" => hd(records)["pos"],
      "last_pos" => List.last(records)["pos"],
      "bytes" => bytes
    }

  defp sync_recovered(dir, names, file_ops) do
    paths = Enum.map(names, &Store.segment_path(dir, &1)) ++ [Path.join(dir, "sessions.jsonl")]

    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case sync_file(path, file_ops) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp sync_file(path, file_ops) do
    with {:ok, fd} <- :file.open(path, [:read, :write, :binary, :raw]) do
      try do
        file_ops.sync(fd)
      after
        :file.close(fd)
      end
    end
  end

  defp segments(dir) do
    with {:ok, files} <- File.ls(dir) do
      names = files |> Enum.filter(&Regex.match?(~r/^entries\.\d{6}\.jsonl$/, &1)) |> Enum.sort()
      numbers = Enum.map(names, fn name -> name |> String.slice(8, 6) |> String.to_integer() end)

      if numbers == Enum.to_list(1..length(numbers)//1),
        do: {:ok, numbers},
        else: {:error, :missing_segment}
    end
  end

  defp entry(%{"v" => 1, "pos" => pos} = row) when is_integer(pos) and pos > 0, do: {:ok, row}
  defp entry(_), do: {:error, :invalid_entry}

  defp session(%{"v" => 1, "session_seq" => seq} = row) when is_integer(seq) and seq > 0,
    do: {:ok, row}

  defp session(_), do: {:error, :invalid_session}

  defp ordered(records, previous, path) do
    records
    |> Enum.with_index(1)
    |> Enum.reduce_while(previous, fn {row, line}, last ->
      if row["pos"] > last,
        do: {:cont, row["pos"]},
        else: {:halt, {:error, {:corrupt, Path.basename(path), line}}}
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp complete_old_segment(_path, true), do: :ok

  defp complete_old_segment(path, false), do: complete(path)

  @doc false
  @spec complete(Path.t()) :: :ok | {:error, term()}
  def complete(path) do
    case File.read(path) do
      {:ok, bytes} ->
        if bytes == "" or String.ends_with?(bytes, "\n"),
          do: :ok,
          else: {:error, {:corrupt, Path.basename(path), length(:binary.matches(bytes, "\n")) + 1}}

      {:error, :enoent} ->
        :ok

      error ->
        error
    end
  end

  defp same_size?(path, size) do
    case File.stat(path) do
      {:ok, stat} -> stat.size == size
      _ -> false
    end
  end

  defp valid_ranges?([], last), do: last == 0

  defp valid_ranges?(segments, last) do
    Enum.reduce_while(segments, 0, fn
      %{"first_pos" => nil, "last_pos" => previous, "bytes" => 0}, previous ->
        {:cont, previous}

      %{"n" => n, "first_pos" => first, "last_pos" => final, "bytes" => bytes}, previous
      when is_integer(n) and n > 0 and is_integer(first) and first > previous and
             is_integer(final) and final >= first and is_integer(bytes) and bytes > 0 ->
        {:cont, final}

      _, _ ->
        {:halt, :invalid}
    end) == last
  end
end
