defmodule Aiur.Claude.HookSpool do
  @moduledoc "Durable, ordered hook replay with a byte cursor in the session handle."

  require Logger

  alias Aiur.Claude.HookSettings
  alias Aiur.SessionHandle

  @doc "Replay complete lines after the persisted cursor; a caller offset is a lower bound."
  @spec replay(String.t(), non_neg_integer(), (map() -> :ok)) :: {:ok, non_neg_integer()} | {:error, term()}
  def replay(identifier, from_offset, publish) do
    :global.trans({{__MODULE__, identifier}, self()}, fn ->
      with {:ok, path} <- HookSettings.spool_path(identifier) do
        replay_file(identifier, path, from_offset, publish)
      end
    end)
  rescue
    error -> {:error, {:spool_replay_failed, Exception.message(error)}}
  end

  @spec clear(String.t()) :: :ok | {:error, term()}
  def clear(identifier) do
    with {:ok, path} <- HookSettings.spool_path(identifier) do
      helper = Application.app_dir(:aiur, "priv/claude_hook_spool.py")

      case System.cmd("python3", [helper, "--reset", path], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:spool_reset_failed, status, output}}
      end
    end
  end

  defp replay_file(identifier, path, from_offset, publish) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          {:ok, info} = :file.read_file_info(file)
          stat = File.Stat.from_record(info)
          generation = "#{stat.major_device}:#{stat.inode}"
          cursor = SessionHandle.hook_cursor(identifier)
          offset = start_offset(cursor, generation, from_offset, stat.size)
          {:ok, ^offset} = :file.position(file, offset)
          read_lines(file, identifier, %{cursor | "offset" => offset, "generation" => generation}, publish)
        after
          File.close(file)
        end

      {:error, :enoent} ->
        {:ok, from_offset}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_offset(%{"generation" => generation, "offset" => offset}, generation, requested, size) when offset <= size,
    do: min(max(offset, requested), size)

  defp start_offset(%{"generation" => nil}, _generation, requested, size), do: min(requested, size)
  defp start_offset(_cursor, _generation, _requested, _size), do: 0

  defp read_lines(file, identifier, cursor, publish) do
    case IO.binread(file, :line) do
      line when is_binary(line) ->
        if String.ends_with?(line, "\n") do
          next = process_line(line, identifier, cursor, publish)
          SessionHandle.save_hook_cursor(identifier, next)
          read_lines(file, identifier, next, publish)
        else
          {:ok, cursor["offset"]}
        end

      :eof ->
        {:ok, cursor["offset"]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_line(line, identifier, cursor, publish) do
    next = %{cursor | "offset" => cursor["offset"] + byte_size(line)}

    case Jason.decode(line) do
      {:ok, raw} when is_map(raw) ->
        key = raw["aiur_hook_id"] || legacy_key(raw, cursor)

        if key in cursor["seen"] do
          next
        else
          :ok = publish.(raw)
          %{next | "seen" => Enum.take([key | cursor["seen"]], 4096)}
        end

      _ ->
        Logger.warning("claude_hook_spool corrupt_line identifier=#{identifier} offset=#{cursor["offset"]}")
        next
    end
  end

  defp legacy_key(raw, cursor) do
    raw = if raw["timestamp"] || raw["transcript_offset"], do: raw, else: Map.put(raw, "timestamp", "#{cursor["generation"]}:#{cursor["offset"]}")

    raw
    |> Map.take(~w(session_id hook_event_name transcript_offset timestamp))
    |> Jason.encode!()
  end
end
