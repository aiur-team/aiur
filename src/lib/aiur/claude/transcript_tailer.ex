defmodule Aiur.Claude.TranscriptTailer do
  @moduledoc """
  Per-session tailer for an interactive-REPL transcript jsonl.

  The REPL backend (`Aiur.Claude.ReplAgent`) reads turn output by following
  the transcript jsonl on disk rather than a JSON-RPC notification stream.
  This GenServer tracks a byte offset into the resolved transcript file,
  reads newly-appended whole lines on each poll, maps them through
  `Aiur.Claude.Transcript.extract_disk_record/2`, and invokes `on_message`
  with each extracted `Aiur.AgentEvents.transcript_event/3`.

  Records authored by either surface (local terminal or the Claude app via
  Remote Control) land in the one shared transcript identically, so the
  tailer is surface-agnostic — which is exactly what makes dual-chat
  fan-out work.

  A partial trailing line (no newline yet) is never emitted until complete.
  File truncation or replacement (size shrinks below the tracked offset) is
  detected and the offset resets so the new file is read from its start.
  """

  use GenServer

  require Logger

  alias Aiur.Claude.Transcript

  @default_interval_ms 400

  @type option ::
          {:path, Path.t()}
          | {:on_message, (Aiur.AgentEvents.transcript_event() -> any())}
          | {:turn_id, String.t() | nil}
          | {:from, :start | :end}
          | {:interval_ms, pos_integer() | nil}
          | {:name, GenServer.name()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Run one read cycle synchronously and return the number of events emitted.
  Used in tests for deterministic stepping; production relies on the timer.
  """
  @spec poll(GenServer.server()) :: {:ok, non_neg_integer()}
  def poll(server), do: GenServer.call(server, :poll)

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    on_message = Keyword.fetch!(opts, :on_message)
    turn_id = Keyword.get(opts, :turn_id)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    offset =
      case Keyword.get(opts, :from, :end) do
        :end -> current_size(path)
        :start -> 0
      end

    state = %{
      path: path,
      offset: offset,
      on_message: on_message,
      turn_id: turn_id,
      interval_ms: interval_ms
    }

    if is_integer(interval_ms), do: schedule(interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    {emitted, state} = read_new(state)
    {:reply, {:ok, emitted}, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_emitted, state} = read_new(state)
    if is_integer(state.interval_ms), do: schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)

  # Read the bytes appended since the last offset, emit one event per
  # renderable on-disk record, and advance the offset past the last
  # complete line. A partial trailing line stays unconsumed.
  defp read_new(state) do
    case File.stat(state.path) do
      {:ok, %{size: size}} ->
        offset = if size < state.offset, do: 0, else: state.offset

        if size == offset do
          {0, %{state | offset: offset}}
        else
          consume(state, offset, size)
        end

      {:error, _reason} ->
        {0, state}
    end
  end

  defp consume(state, offset, size) do
    case read_chunk(state.path, offset, size - offset) do
      {:ok, chunk} ->
        {complete, consumed} = complete_lines(chunk)
        emitted = emit_lines(state, complete)
        {emitted, %{state | offset: offset + consumed}}

      :error ->
        {0, %{state | offset: offset}}
    end
  end

  defp read_chunk(path, offset, length) do
    case File.open(path, [:read, :binary]) do
      {:ok, fd} ->
        result = :file.pread(fd, offset, length)
        File.close(fd)

        case result do
          {:ok, chunk} when is_binary(chunk) -> {:ok, chunk}
          _ -> :error
        end

      {:error, _reason} ->
        :error
    end
  end

  # Split into the portion up to and including the last newline (complete
  # records) and report how many bytes that portion consumed. Bytes after
  # the last newline are a partial record and are left for the next read.
  defp complete_lines(chunk) do
    case last_newline_index(chunk) do
      nil ->
        {[], 0}

      index ->
        complete = binary_part(chunk, 0, index + 1)
        {String.split(complete, "\n", trim: true), index + 1}
    end
  end

  defp last_newline_index(chunk) do
    case :binary.matches(chunk, "\n") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp emit_lines(state, lines) do
    Enum.reduce(lines, 0, fn line, acc ->
      case decode(line) do
        {:ok, record} ->
          events = Transcript.extract_disk_record(record, state.turn_id)
          Enum.each(events, state.on_message)
          acc + length(events)

        :error ->
          acc
      end
    end)
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, record} when is_map(record) -> {:ok, record}
      _ -> :error
    end
  end

  defp current_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end
end
