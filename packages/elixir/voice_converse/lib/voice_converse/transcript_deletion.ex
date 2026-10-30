defmodule VoiceConverse.TranscriptDeletion do
  @moduledoc false

  alias VoiceConverse.TranscriptIndex.{IndexFile, Transcripts}
  alias VoiceConverse.TranscriptStore

  @doc "Deletes an ended session after explicit confirmation; staged intents survive a crash."
  @spec delete(Path.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(root, id, opts) do
    with true <- Keyword.get(opts, :confirm) == id || {:error, :confirmation_required},
         {:ok, path} <- TranscriptStore.path(root, id),
         :ok <- safe_root(root),
         :ok <- regular(path),
         {:ok, conversation} <- Transcripts.conversation(root, id),
         true <- not is_nil(conversation.ended_at) || {:error, :active_conversation},
         :ok <- prepare_directory(root),
         :ok <- write_intent(root, id, Keyword.get(opts, :by, "operator")),
         :ok <- finish(root, id) do
      :ok
    end
  end

  # Each permanent marker contains only audit identity, never transcript metadata or text.
  @spec tombstones(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def tombstones(root) do
    with {:ok, names} <- marker_names(root) do
      Enum.reduce_while(names, {:ok, []}, fn name, {:ok, items} ->
        with :ok <- regular(Path.join(directory(root), name)),
             {:ok, body} <- File.read(Path.join(directory(root), name)),
             {:ok, %{"conversation_id" => id, "deleted_at" => at, "by" => by} = marker} <- Jason.decode(body),
             {:ok, _} <- TranscriptStore.path(root, id),
             true <- name == id <> ".json" and map_size(marker) == 3 and is_binary(at) and is_binary(by) do
          {:cont, {:ok, [%{conversation_id: id, deleted_at: at, by: by} | items]}}
        else
          _ -> {:halt, {:error, :invalid_deletion_marker}}
        end
      end)
    end
  end

  @spec recover(Path.t()) :: :ok | {:error, term()}
  def recover(root) do
    with {:ok, markers} <- tombstones(root) do
      Enum.reduce_while(markers, :ok, fn marker, :ok ->
        case finish(root, marker.conversation_id) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp finish(root, id) do
    {:ok, source} = TranscriptStore.path(root, id)
    staged = Path.join(directory(root), id <> ".ndjson")

    with :ok <- stage(source, staged),
         :ok <- sync_directory(root),
         :ok <- sync_directory(directory(root)),
         :ok <- IndexFile.rebuild(root),
         :ok <- remove_staged(staged),
         :ok <- sync_directory(directory(root)) do
      :ok
    end
  end

  defp stage(source, staged) do
    case File.lstat(source) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> File.rename(source, staged)
      {:ok, _} -> {:error, :unsafe_transcript}
      error -> error
    end
  end

  defp remove_staged(path) do
    case File.rm(path) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  defp write_intent(root, id, by) when is_binary(by) and by != "" do
    marker = %{conversation_id: id, deleted_at: DateTime.to_iso8601(DateTime.utc_now()), by: by}
    path = Path.join(directory(root), id <> ".json")

    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    with {:ok, fd} <- :file.open(temporary, [:write, :binary, :raw, :exclusive]) do
      try do
        with :ok <- File.chmod(temporary, 0o600),
             :ok <- :file.write(fd, Jason.encode!(marker)),
             :ok <- :file.sync(fd),
             :ok <- File.rename(temporary, path),
             :ok <- sync_directory(directory(root)) do
          :ok
        end
      after
        :file.close(fd)
        File.rm(temporary)
      end
    end
  end

  defp write_intent(_, _, _), do: {:error, :invalid_actor}

  defp marker_names(root) do
    case File.lstat(directory(root)) do
      {:error, :enoent} ->
        {:ok, []}

      {:ok, %File.Stat{type: :directory}} ->
        with :ok <- safe_root(directory(root)), {:ok, names} <- File.ls(directory(root)) do
          {:ok, Enum.filter(names, &String.ends_with?(&1, ".json"))}
        end

      _ ->
        {:error, :unsafe_deletion_directory}
    end
  end

  defp prepare_directory(root) do
    case File.mkdir(directory(root)) do
      :ok ->
        with :ok <- File.chmod(directory(root), 0o700), do: sync_directory(root)

      {:error, :eexist} ->
        safe_root(directory(root))

      error ->
        error
    end
  end

  defp safe_root(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when Bitwise.band(mode, 0o077) == 0 -> :ok
      _ -> {:error, :unsafe_transcript_root}
    end
  end

  defp regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> {:error, :not_found}
      _ -> {:error, :unsafe_transcript}
    end
  end

  defp sync_directory(path) do
    with {:ok, fd} <- :file.open(path, [:read, :raw, :directory]) do
      try do
        :file.sync(fd)
      after
        :file.close(fd)
      end
    end
  end

  defp directory(root), do: Path.join(root, ".deleted")
end
