defmodule Aiur.Asks.Store do
  @moduledoc false

  alias Aiur.RepoBase
  alias Exqlite.Basic

  @max_record_bytes 16 * 1024
  @lock_timeout_ms 30_000

  @spec with_lock(String.t(), (-> result)) :: result | {:error, term()} when result: term()
  def with_lock(repo, operation) do
    with :ok <- RepoBase.ensure_state_tree(repo) do
      asks_path = RepoBase.asks_path(repo)
      path = asks_path <> ".lock.sqlite3"

      case Basic.open(path) do
        {:ok, connection} ->
          try do
            with :ok <- sqlite_exec(connection, "PRAGMA busy_timeout = #{@lock_timeout_ms}", path),
                 :ok <- sqlite_exec(connection, "BEGIN EXCLUSIVE", path) do
              with :ok <- recover_torn_tail(asks_path), do: operation.()
            end
          after
            _ = Basic.exec(connection, "COMMIT")
            Basic.close(connection)
          end

        {:error, error} ->
          {:error, {:ask_lock_open_failed, path, error}}
      end
    end
  end

  @spec append(String.t(), map()) :: :ok | {:error, term()}
  def append(repo, event) do
    with {:ok, encoded} <- Jason.encode(event),
         :ok <- validate_size(encoded <> "\n"),
         :ok <- RepoBase.ensure_state_tree(repo) do
      append_line(RepoBase.asks_path(repo), encoded <> "\n")
    end
  end

  @spec events(String.t()) :: {:ok, [{map(), pos_integer(), Path.t()}]} | {:error, term()}
  def events(repo) do
    path = RepoBase.asks_path(repo)

    with :ok <- recover_torn_tail(path),
         {:ok, contents} <- File.read(path) do
      decode_events(contents, path)
    else
      {:error, reason} -> {:error, {:ask_read_failed, path, reason}}
    end
  end

  defp append_line(path, line) do
    case File.open(path, [:append, :binary]) do
      {:ok, device} ->
        try do
          with :ok <- IO.binwrite(device, line), do: :file.sync(device)
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, {:ask_append_open_failed, path, reason}}
    end
  end

  # Every normal append includes its newline. Under the same SQLite lease, a
  # partial final write is removed and a complete unterminated record is
  # canonicalized before the next append can join two JSON objects.
  defp recover_torn_tail(path) do
    with {:ok, contents} <- File.read(path),
         false <- String.ends_with?(contents, "\n"),
         {prefix, tail} <- split_final_line(contents),
         {:error, _reason} <- Jason.decode(tail) do
      truncate_to(path, byte_size(prefix))
    else
      true -> :ok
      {:ok, _json} -> append_newline(path)
      {:error, reason} -> {:error, {:ask_tail_recovery_failed, path, reason}}
    end
  end

  defp split_final_line(contents) do
    case :binary.matches(contents, "\n") do
      [] ->
        {"", contents}

      matches ->
        {offset, _length} = List.last(matches)
        prefix_size = offset + 1
        {binary_part(contents, 0, prefix_size), binary_part(contents, prefix_size, byte_size(contents) - prefix_size)}
    end
  end

  defp truncate_to(path, size) do
    case File.open(path, [:read, :write, :binary]) do
      {:ok, device} ->
        try do
          with {:ok, _position} <- :file.position(device, size),
               :ok <- :file.truncate(device),
               do: :file.sync(device)
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, {:ask_tail_recovery_open_failed, path, reason}}
    end
  end

  defp append_newline(path), do: append_line(path, "\n")

  defp decode_events(contents, path) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, line_number}, {:ok, events} ->
      case Jason.decode(line) do
        {:ok, event} when is_map(event) -> {:cont, {:ok, [{event, line_number, path} | events]}}
        _ -> {:halt, {:error, {:invalid_ask_record, path, line_number, "invalid JSON"}}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp sqlite_exec(connection, sql, path) do
    case Basic.exec(connection, sql) do
      {:ok, _query, _result, _connection} -> :ok
      {:error, error, _connection} -> {:error, {:ask_lock_failed, path, error}}
    end
  end

  defp validate_size(line) when byte_size(line) <= @max_record_bytes, do: :ok
  defp validate_size(line), do: {:error, {:ask_record_too_large, byte_size(line), @max_record_bytes}}
end
