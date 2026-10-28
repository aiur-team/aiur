defmodule Aiur.Conversation.Store do
  @moduledoc """
  Single-writer, append-only conversation files. Call `prepare/1` before use.

  State is the JSON-shaped head returned by prepare/read/append. A failed write
  must be reconciled with `rebuild_head/1` before retrying; complete durable
  records may survive an unacknowledged batch. Only head.json is replaceable.
  """

  alias Aiur.Conversation.{Ref, StoreFiles, StoreReplay, SubjectIndex}
  alias Aiur.{Fs, Journal}

  @segment_bytes 8_388_608

  @spec prepare(Path.t()) :: {:ok, map()} | {:error, term()}
  def prepare(dir) when is_binary(dir) do
    with :ok <- StoreFiles.check(dir),
         :ok <- Journal.prepare(dir, Path.join(dir, "sessions.jsonl")),
         :ok <- Journal.prepare(dir, Path.join(dir, "anchors.jsonl")) do
      read_head(dir)
    end
  end

  @doc "Creates immutable identity metadata before opening the conversation."
  @spec prepare(Path.t(), Ref.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(dir, %Ref{} = ref, opts \\ []) do
    with :ok <- StoreFiles.check(dir),
         :ok <- Journal.ensure_directory(dir),
         :ok <- StoreFiles.subject(dir, ref, opts) do
      SubjectIndex.put(dir, ref)
      prepare(dir)
    end
  end

  @doc "Appends one batch in one write and fsync, rolling before the batch."
  @spec append_entries(Path.t(), map(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def append_entries(dir, state, entries, opts \\ [])
  def append_entries(_dir, state, [], _opts), do: {:ok, state}

  def append_entries(dir, state, entries, opts) do
    records = Enum.map(entries, &Aiur.JSONSafe.normalize/1)
    bytes = records |> Enum.map(&[Jason.encode!(&1), "\n"]) |> IO.iodata_length()
    limit = Keyword.get(opts, :segment_bytes, @segment_bytes)

    with :ok <- StoreFiles.check(dir),
         :ok <- StoreReplay.positions(records, state["last_pos"]),
         :ok <- batch_limit(bytes, limit),
         segment = select_segment(state["segments"], bytes, limit),
         path = segment_path(dir, segment["n"]),
         :ok <- Journal.prepare(dir, path),
         :accepted <- Journal.append_many(path, records, Keyword.take(opts, [:file_ops])),
         {:ok, stat} <- File.stat(path),
         updated = update_head(state, segment, records, stat.size),
         :ok <- write_head(dir, updated) do
      {:ok, updated}
    else
      {outcome, reason} when outcome in [:failed, :ambiguous] -> {:error, reason}
      {:error, _} = error -> error
    end
  end

  @spec append_session_line(Path.t(), map()) :: :ok | {:error, term()}
  def append_session_line(dir, line), do: append_line(dir, "sessions.jsonl", line)

  @spec append_anchor_line(Path.t(), map()) :: :ok | {:error, term()}
  def append_anchor_line(dir, line), do: append_line(dir, "anchors.jsonl", line)

  @spec read_head(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_head(dir) do
    with :ok <- StoreFiles.check(dir),
         {:ok, bytes} <- File.read(Path.join(dir, "head.json")),
         {:ok, head} <- Jason.decode(bytes),
         true <- StoreReplay.current?(dir, head) do
      {:ok, head}
    else
      {:error, {:symlink_rejected, _}} = error -> error
      _missing_invalid_or_stale -> rebuild_head(dir)
    end
  end

  @spec rebuild_head(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rebuild_head(dir, opts \\ []) do
    with :ok <- StoreFiles.check(dir),
         {:ok, head} <- StoreReplay.head(dir, opts),
         :ok <- write_head(dir, head) do
      {:ok, head}
    end
  end

  @doc "Returns entries in an inclusive position range, reading overlapping segments only."
  @spec stream_entries(Path.t(), non_neg_integer(), non_neg_integer() | :infinity) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream_entries(dir, from_pos, to_pos) do
    with {:ok, head} <- read_head(dir),
         segments = Enum.filter(head["segments"], &overlaps?(&1, from_pos, to_pos)),
         {:ok, batches} <- read_segments(dir, segments) do
      stream =
        batches
        |> Enum.reverse()
        |> Stream.flat_map(& &1)
        |> Stream.filter(&in_range?(&1["pos"], from_pos, to_pos))

      {:ok, stream}
    end
  end

  defp overlaps?(segment, from, to),
    do:
      not is_nil(segment["first_pos"]) and segment["last_pos"] >= from and
        (to == :infinity or segment["first_pos"] <= to)

  defp in_range?(pos, from, to), do: pos >= from and (to == :infinity or pos <= to)

  defp read_segments(dir, segments) do
    Enum.reduce_while(segments, {:ok, []}, fn segment, {:ok, acc} ->
      case StoreReplay.segment(segment_path(dir, segment["n"]), 0, false) do
        {:ok, records} -> {:cont, {:ok, [records | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  @doc false
  @spec segment_path(Path.t(), pos_integer()) :: Path.t()
  def segment_path(dir, n),
    do: Path.join(dir, "entries.#{String.pad_leading(Integer.to_string(n), 6, "0")}.jsonl")

  defp append_line(dir, name, line) do
    with :ok <- StoreFiles.check(dir),
         :ok <- Journal.prepare(dir, Path.join(dir, name)),
         :ok <- StoreReplay.complete(Path.join(dir, name)) do
      Journal.append(Path.join(dir, name), Aiur.JSONSafe.normalize(line))
    end
  end

  defp batch_limit(bytes, limit) when is_integer(limit) and limit > 0 and bytes <= limit, do: :ok
  defp batch_limit(_bytes, _limit), do: {:error, :batch_too_large}

  defp select_segment([], _bytes, _limit),
    do: %{"n" => 1, "first_pos" => nil, "last_pos" => 0, "bytes" => 0}

  defp select_segment(segments, bytes, limit) do
    last = List.last(segments)

    if last["bytes"] + bytes > limit,
      do: %{"n" => last["n"] + 1, "first_pos" => nil, "last_pos" => 0, "bytes" => 0},
      else: last
  end

  defp update_head(state, segment, records, bytes) do
    segment = %{
      segment
      | "first_pos" => segment["first_pos"] || hd(records)["pos"],
        "last_pos" => List.last(records)["pos"],
        "bytes" => bytes
    }

    segments = Enum.reject(state["segments"], &(&1["n"] == segment["n"])) ++ [segment]
    %{state | "last_pos" => segment["last_pos"], "segments" => segments}
  end

  @doc false
  @spec write_head(Path.t(), map()) :: :ok | {:error, term()}
  def write_head(dir, head),
    do: Fs.atomic_write(Path.join(dir, "head.json"), Jason.encode!(head), fsync: true, mode: 0o600)
end
