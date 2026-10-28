defmodule Aiur.Conversation.HistoryReader do
  @moduledoc false
  alias Aiur.Config.Paths
  alias Aiur.Conversation.{Entry, HeadTable, Ref, Session, Store, StoreFiles}

  @spec snapshot(Ref.t() | String.t()) :: {:ok, map()} | {:error, :not_found | :unavailable}
  def snapshot(%Ref{} = ref), do: snapshot(Ref.conversation_id(ref))

  def snapshot(id) when is_binary(id) do
    if Regex.match?(~r/\Aconv_[a-z2-7]{26}\z/, id) do
      with {:ok, root} <- Paths.conversation_state_dir(),
           dir = Path.join(root, id),
           :ok <- StoreFiles.check(dir),
           {:ok, head} <- head(id, dir),
           :ok <- valid_head(head) do
        {:ok, %{id: id, dir: dir, head: head}}
      else
        {:error, :enoent} -> {:error, :not_found}
        _ -> {:error, :unavailable}
      end
    else
      {:error, :not_found}
    end
  end

  def snapshot(_ref), do: {:error, :not_found}

  defp head(id, dir) do
    case HeadTable.get(id, dir) do
      {:ok, head} -> {:ok, head}
      :missing -> writer_head(id, dir)
    end
  end

  defp writer_head(id, dir) do
    case Registry.lookup(Aiur.Conversation.Registry, id) do
      [{pid, _}] -> if Process.alive?(pid), do: GenServer.call(pid, :head), else: disk_head(dir)
      [] -> disk_head(dir)
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp disk_head(dir) do
    with {:ok, bytes} <- File.read(Path.join(dir, "head.json")), do: Jason.decode(bytes)
  end

  defp valid_head(%{"v" => 1, "last_pos" => last, "segments" => segments, "sessions_bytes" => bytes})
       when is_integer(last) and last >= 0 and is_list(segments) and is_integer(bytes) and bytes >= 0 do
    result =
      Enum.reduce_while(segments, {0, 0}, fn
        %{"n" => n, "first_pos" => first, "last_pos" => final, "bytes" => size}, {previous, count}
        when n == count + 1 and is_integer(first) and first == previous + 1 and is_integer(final) and final >= first and is_integer(size) and size > 0 ->
          {:cont, {final, n}}

        %{"n" => n, "first_pos" => nil, "last_pos" => previous, "bytes" => 0}, {previous, count} when n == count + 1 ->
          {:cont, {previous, n}}

        _, _ ->
          {:halt, :invalid}
      end)

    if match?({^last, _}, result), do: :ok, else: {:error, :unavailable}
  end

  defp valid_head(_), do: {:error, :unavailable}

  @doc "Reads exactly the acknowledged prefix, ignoring an append in progress."
  @spec prefix(Path.t(), non_neg_integer()) :: {:ok, binary()} | {:error, :unavailable}
  def prefix(path, size) do
    with {:ok, fd} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        case if(size == 0, do: {:ok, ""}, else: :file.read(fd, size)) do
          {:ok, bytes} when byte_size(bytes) == size ->
            if bytes == "" or String.ends_with?(bytes, "\n"), do: {:ok, bytes}, else: {:error, :unavailable}

          _ ->
            {:error, :unavailable}
        end
      after
        :file.close(fd)
      end
    else
      _ -> {:error, :unavailable}
    end
  end

  @spec entries(map(), non_neg_integer(), non_neg_integer(), :forward | :backward) :: Enumerable.t()
  def entries(snapshot, from, to, direction) do
    segments = Enum.filter(snapshot.head["segments"], &(is_integer(&1["first_pos"]) and &1["last_pos"] >= from and &1["first_pos"] <= to))
    segments = if direction == :backward, do: Enum.reverse(segments), else: segments

    Stream.flat_map(segments, fn segment ->
      case prefix(Store.segment_path(snapshot.dir, segment["n"]), segment["bytes"]) do
        {:ok, bytes} ->
          segment_entries(bytes, segment, from, to, direction)

        error ->
          [error]
      end
    end)
  end

  defp segment_entries(bytes, segment, from, to, direction) do
    lines = bytes |> String.split("\n") |> Enum.drop(-1)
    first = segment["first_pos"]
    last = segment["last_pos"]

    if length(lines) == last - first + 1 do
      rows = lines |> Enum.with_index(first) |> Enum.filter(fn {_line, pos} -> pos >= from and pos <= to end)
      rows = if direction == :backward, do: Enum.reverse(rows), else: rows

      Stream.map(rows, fn {line, expected} ->
        case Entry.from_json(line) do
          {:ok, %{pos: ^expected} = entry} -> {:ok, entry}
          _ -> {:error, :unavailable}
        end
      end)
    else
      [{:error, :unavailable}]
    end
  end

  @spec sessions(map()) :: {:ok, [Session.t()]} | {:error, :unavailable}
  def sessions(snapshot) do
    with {:ok, bytes} <- prefix(Path.join(snapshot.dir, "sessions.jsonl"), snapshot.head["sessions_bytes"]),
         {:ok, sessions} <- fold_sessions(String.split(bytes, "\n", trim: true)) do
      sessions = sessions |> Map.values() |> Enum.sort_by(& &1.session_seq)

      {:ok,
       sessions
       |> Enum.with_index()
       |> Enum.map(fn {session, index} ->
         next = Enum.at(sessions, index + 1)
         last = session.last_pos || if(next, do: next.first_pos - 1, else: snapshot.head["last_pos"])
         %{session | last_pos: last}
       end)}
    end
  end

  defp fold_sessions(lines) do
    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, sessions} ->
      case Session.from_json(line) do
        {:ok, %{end_reason: nil} = session} ->
          {:cont, {:ok, Map.put(sessions, session.session_seq, session)}}

        {:ok, ended} ->
          case Map.fetch(sessions, ended.session_seq) do
            {:ok, session} ->
              session = %{session | last_pos: ended.last_pos, ended_at: ended.ended_at, end_reason: ended.end_reason}
              {:cont, {:ok, Map.put(sessions, ended.session_seq, session)}}

            :error ->
              {:halt, {:error, :unavailable}}
          end

        _ ->
          {:halt, {:error, :unavailable}}
      end
    end)
  end
end
