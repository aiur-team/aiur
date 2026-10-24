defmodule Aiur.Orchestrator.ClosedTicketTranscriptArchive do
  @moduledoc "Keeps a bounded diagnostic transcript for ticket closures without a merged PR."

  require Logger

  alias Aiur.{Config, RecentMerge, RecentMergeStore}
  alias Aiur.Workspace.Layout

  @archive_directory "closed-ticket-transcripts"
  @transcript_files ["agent.md", "agent.ndjson"]
  @max_file_bytes 5 * 1024 * 1024
  @retention_limit 100

  @spec archive(String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def archive(identifier, worker_host, opts \\ []) when is_binary(identifier) do
    cond do
      is_binary(worker_host) ->
        Logger.info("Skipping transcript archive for remote workspace; terminal cleanup will continue ticket=#{identifier} worker_host=#{worker_host}")
        :ok

      merged_pr_close?(identifier, opts) ->
        Logger.debug("Skipping transcript archive for ticket closed by merged PR ticket=#{identifier}")
        :ok

      true ->
        archive_local_transcripts(identifier, opts)
    end
  end

  @doc false
  @spec merged_pr_close?(String.t(), keyword()) :: boolean()
  def merged_pr_close?(identifier, opts \\ []) do
    recent_merges = Keyword.get(opts, :recent_merges_fun, &RecentMergeStore.list/0).()

    Enum.any?(recent_merges, fn
      %RecentMerge{} = merge ->
        identifier in RecentMerge.closing_issue_identifiers(merge) or merge.ticket_id == identifier

      _other ->
        false
    end)
  end

  defp archive_local_transcripts(identifier, opts) do
    workspace_resolver = Keyword.get(opts, :workspace_path_fun, &Layout.workspace_path_for_issue/2)
    root = Keyword.get(opts, :archive_root, Path.join(Config.Paths.log_root_dir(), @archive_directory))
    retention_limit = Keyword.get(opts, :retention_limit, @retention_limit)
    max_file_bytes = Keyword.get(opts, :max_file_bytes, @max_file_bytes)
    safe_identifier = Layout.safe_identifier(identifier)

    with {:ok, workspace} <- workspace_resolver.(safe_identifier, nil),
         logs <- Path.join(workspace, "logs"),
         true <- File.dir?(logs) do
      destination = archive_path(root, safe_identifier, opts)

      with :ok <- File.mkdir_p(destination),
           :ok <- copy_transcripts(logs, destination, max_file_bytes),
           :ok <- prune_archives(root, retention_limit) do
        :ok
      end
    else
      false -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp archive_path(root, identifier, opts) do
    timestamp = Keyword.get(opts, :timestamp_fun, fn -> System.system_time(:millisecond) end).()
    unique = System.unique_integer([:positive, :monotonic])
    Path.join([root, identifier, "#{timestamp}-#{unique}"])
  end

  defp copy_transcripts(source, destination, max_file_bytes) do
    Enum.reduce_while(@transcript_files, :ok, fn name, :ok ->
      source_file = Path.join(source, name)
      destination_file = Path.join(destination, name)

      case File.lstat(source_file) do
        {:ok, %File.Stat{type: :regular, size: size}} ->
          case copy_prefix(source_file, destination_file, min(size, max_file_bytes)) do
            :ok ->
              if size > max_file_bytes do
                marker = "\n[transcript truncated at #{max_file_bytes} bytes]\n"

                case File.write(destination_file, marker, [:append]) do
                  :ok -> {:cont, :ok}
                  {:error, reason} -> {:halt, {:error, reason}}
                end
              else
                {:cont, :ok}
              end

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {:error, :enoent} ->
          {:cont, :ok}

        {:ok, _other} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp copy_prefix(source, destination, byte_count) do
    case File.copy(source, destination, byte_count) do
      {:ok, ^byte_count} -> :ok
      {:ok, copied} -> {:error, {:short_transcript_copy, copied, byte_count}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prune_archives(root, retention_limit) do
    archives =
      root
      |> child_directories()
      |> Enum.flat_map(fn ticket_dir ->
        ticket_dir
        |> child_directories()
        |> Enum.map(&{&1, ticket_dir})
      end)
      |> Enum.sort_by(fn {path, _ticket_dir} -> archive_sort_key(path) end, :desc)

    archives
    |> Enum.drop(retention_limit)
    |> Enum.reduce_while(:ok, fn {path, ticket_dir}, :ok ->
      case File.rm_rf(path) do
        {:ok, _removed} ->
          remove_empty_ticket_directory(ticket_dir)
          {:cont, :ok}

        {:error, reason, _failed_path} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp child_directories(path) do
    case File.ls(path) do
      {:ok, names} -> Enum.map(names, &Path.join(path, &1)) |> Enum.filter(&File.dir?/1)
      {:error, _reason} -> []
    end
  end

  defp archive_sort_key(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> {mtime, path}
      {:error, _reason} -> {0, path}
    end
  end

  defp remove_empty_ticket_directory(path) do
    case File.ls(path) do
      {:ok, []} -> File.rmdir(path)
      _other -> :ok
    end
  end
end
