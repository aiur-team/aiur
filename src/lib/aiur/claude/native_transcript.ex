defmodule Aiur.Claude.NativeTranscript do
  @moduledoc "Bounded read of the live Claude Executor's native transcript; other harnesses remain unavailable in the prototype."

  alias Aiur.Claude.{RemoteControl, Transcript}

  @max_tail_bytes 262_144
  @session_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @spec read(map(), pos_integer()) :: {:ok, map()} | {:error, :unavailable}
  def read(%{"state" => "live", "harness" => harness, "cwd" => cwd, "session_id" => id} = session, n)
      when harness in ["claude", "claude-repl"] and is_binary(cwd) and is_binary(id) do
    opts = if dir = session["config_dir"], do: [projects_dir: Path.join(dir, "projects")], else: []

    if Regex.match?(@session_id, id) do
      cwd |> RemoteControl.session_transcript_path(id, opts) |> read_tail(n)
    else
      {:error, :unavailable}
    end
  end

  def read(_session, _n), do: {:error, :unavailable}

  defp read_tail(path, n) do
    case File.open(path, [:read, :binary], &read_file(&1, n)) do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp read_file(file, n) do
    with {:ok, size} <- :file.position(file, :eof),
         offset = max(size - @max_tail_bytes, 0),
         {:ok, bytes} <- :file.pread(file, offset, @max_tail_bytes) do
      lines = String.split(bytes, "\n", trim: true)
      lines = if offset > 0, do: Enum.drop(lines, 1), else: lines
      {:ok, %{events: lines |> Enum.flat_map(&events/1) |> Enum.take(-n)}}
    else
      :eof -> {:ok, %{events: []}}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp events(line) do
    case Aiur.Jsonl.decode_line(line) do
      {:ok, record} ->
        record
        |> Transcript.extract_disk_record(nil)
        |> Enum.filter(&(&1.role in [:user, :assistant]))
        |> Enum.map(&%{role: Atom.to_string(&1.role), body: &1.body})

      :skip ->
        []
    end
  end
end
