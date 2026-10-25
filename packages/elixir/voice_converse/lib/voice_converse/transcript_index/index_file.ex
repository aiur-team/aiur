defmodule VoiceConverse.TranscriptIndex.IndexFile do
  @moduledoc false

  alias VoiceConverse.TranscriptIndex.Transcripts

  @index_filename "index.ndjson"

  def read(root) do
    case File.read(path(root)) do
      {:ok, content} -> decode(content)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_or_rebuild(root) do
    case read(root) do
      {:ok, conversations} ->
        if File.exists?(path(root)), do: {:ok, conversations}, else: with(:ok <- rebuild(root), do: read(root))

      {:error, _reason} ->
        with(:ok <- rebuild(root), do: read(root))
    end
  end

  def append(root, op, conversation) do
    with :ok <- ensure_root(root),
         {:ok, fd} <- :file.open(String.to_charlist(path(root)), [:append, :binary, :raw]),
         :ok <- File.chmod(path(root), 0o600),
         :ok <- write_event(fd, event(op, conversation)),
         :ok <- :file.datasync(fd) do
      :file.close(fd)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def rebuild(root) do
    with :ok <- ensure_root(root),
         {:ok, conversations} <- Transcripts.all(root),
         :ok <- replace(root, conversations) do
      :ok
    end
  end

  defp decode(content) do
    cond do
      content == "" ->
        {:ok, []}

      not String.ends_with?(content, "\n") ->
        {:error, :torn_index}

      true ->
        content
        |> String.split("\n")
        |> Enum.drop(-1)
        |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, conversations} ->
          case Jason.decode(line) do
            {:ok, %{"op" => op, "conversation" => %{"conversation_id" => id} = item}}
            when op in ["opened", "closed"] ->
              {:cont, {:ok, Map.put(conversations, id, decode_conversation(item))}}

            _ ->
              {:halt, {:error, :torn_index}}
          end
        end)
        |> then(fn
          {:ok, conversations} -> {:ok, conversations |> Map.values() |> sort()}
          error -> error
        end)
    end
  end

  defp replace(root, conversations) do
    temporary = path(root) <> ".tmp"
    File.rm(temporary)

    with {:ok, fd} <- :file.open(String.to_charlist(temporary), [:write, :binary, :raw]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- write_all(fd, conversations),
         :ok <- :file.datasync(fd),
         :ok <- :file.close(fd),
         :ok <- File.rename(temporary, path(root)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_all(fd, conversations) do
    Enum.reduce_while(conversations, :ok, fn conversation, :ok ->
      operations = if conversation.end_reason, do: ["opened", "closed"], else: ["opened"]

      case Enum.reduce_while(operations, :ok, fn op, :ok ->
             case write_event(fd, event(op, conversation)) do
               :ok -> {:cont, :ok}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp event(op, conversation),
    do: %{"op" => op, "conversation" => Map.new(conversation, fn {k, v} -> {to_string(k), v} end)}

  defp write_event(fd, event) do
    with {:ok, line} <- Jason.encode(event), do: :file.write(fd, line <> "\n")
  end

  defp decode_conversation(item) do
    %{
      conversation_id: item["conversation_id"],
      target: item["target"],
      role_id: item["role_id"],
      started_at: item["started_at"],
      ended_at: item["ended_at"],
      end_reason: item["end_reason"],
      turn_count: item["turn_count"] || 0,
      draft_counts: item["draft_counts"] || %{},
      duration_s: item["duration_s"]
    }
  end

  defp sort(conversations), do: Enum.sort_by(conversations, &{&1.started_at || "", &1.conversation_id}, :desc)
  defp path(root), do: Path.join(Path.expand(root), @index_filename)

  defp ensure_root(root) when is_binary(root) and root != "" do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when Bitwise.band(mode, 0o077) == 0 -> :ok
      {:ok, %File.Stat{type: :directory, mode: mode}} -> {:error, {:insecure_root, mode}}
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlink_rejected, root}}
      {:ok, %File.Stat{}} -> {:error, {:not_a_directory, root}}
      {:error, :enoent} -> with(:ok <- File.mkdir_p(root), do: File.chmod(root, 0o700))
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_root(_), do: {:error, :invalid_root}
end
