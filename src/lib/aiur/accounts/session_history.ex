defmodule Aiur.Accounts.SessionHistory do
  @moduledoc false

  # Merges a moved session's `history.jsonl` rows into the destination profile.

  @spec merge_history(Path.t(), Path.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def merge_history(_source, _destination, nil, _opts), do: :ok

  def merge_history(source, destination, session_id, opts) do
    from = Path.join(source, "history.jsonl")
    to = Path.join(destination, "history.jsonl")

    with {:ok, source_data} <- read_if_present(from), {:ok, dest_data} <- read_if_present(to) do
      merge_history_rows(from, to, source_data, dest_data, session_id, opts)
    end
  end

  defp merge_history_rows(from, to, source_data, dest_data, session_id, opts) do
    session_lines = String.split(source_data, "\n", trim: true) |> Enum.filter(&history_line?(&1, session_id))
    other_lines = String.split(source_data, "\n", trim: true) |> Enum.reject(&history_line?(&1, session_id))
    merged = (String.split(dest_data, "\n", trim: true) ++ session_lines) |> Enum.uniq() |> Enum.sort_by(&history_timestamp/1) |> Enum.join("\n")

    write = Keyword.get(opts, :history_write, &File.write/2)
    merged_data = if(merged == "", do: "", else: merged <> "\n")
    new_source_data = Enum.join(other_lines, "\n")

    with :ok <- write.(to, merged_data) do
      update_source_history(write.(from, new_source_data), to, dest_data)
    end
  end

  @spec update_source_history(:ok | {:error, term()}, Path.t(), binary()) :: :ok | {:error, term()}
  def update_source_history(:ok, _destination, _original_data), do: :ok

  def update_source_history({:error, reason}, destination, original_data) do
    case restore_history(destination, original_data) do
      :ok -> {:error, reason}
      restore -> {:error, {:history_rollback_failed, reason, restore}}
    end
  end

  @spec restore_history(Path.t(), binary()) :: :ok | {:error, term()}
  def restore_history(path, data) do
    if data == "" do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> error
      end
    else
      File.write(path, data)
    end
  end

  defp read_if_present(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> {:ok, ""}
      error -> error
    end
  end

  defp history_line?(line, id) do
    case Jason.decode(line) do
      {:ok, row} -> row["sessionId"] == id or row["session_id"] == id
      _ -> false
    end
  end

  defp history_timestamp(line) do
    case Jason.decode(line) do
      {:ok, row} -> row["timestamp"] || ""
      _ -> ""
    end
  end
end
