defmodule Aiur.DecisionMetrics.Log do
  @moduledoc "Bounded append/replay helpers for the best-effort Decision metrics stream."

  require Logger

  alias Aiur.{DecisionLog, Fs}
  alias Aiur.DecisionMetrics.{Options, Sample}

  @type replay :: %{
          samples: %{String.t() => Sample.t()},
          records: %{String.t() => map()},
          event_ids: [String.t()],
          record_count: non_neg_integer(),
          truncated?: boolean()
        }

  @doc "Prepares the owner-only metrics directory and stream once at writer startup."
  @spec prepare(Path.t()) :: :ok | {:error, term()}
  def prepare(path) when is_binary(path) do
    DecisionLog.prepare(Path.dirname(path), path, fn -> :ok end)
  end

  @doc "Builds one redacted, JSON-safe lifecycle snapshot."
  @spec record(Sample.t(), map(), DateTime.t()) :: map()
  def record(sample, fact, observed_at) do
    sample
    |> Sample.to_map()
    |> Map.merge(%{
      observed_at: DateTime.to_iso8601(observed_at),
      observed_event_id: fact.event_id,
      stage: Atom.to_string(fact.stage)
    })
  end

  @doc "Decodes one persisted metrics snapshot."
  @spec decode_record(map()) :: {:ok, {Sample.t(), String.t()}} | {:error, term()}
  def decode_record(raw) when is_map(raw) do
    raw = Map.new(raw, fn {key, value} -> {to_string(key), value} end)

    with {:ok, sample} <- Sample.from_map(raw),
         event_id when is_binary(event_id) <- raw["observed_event_id"] do
      {:ok, {sample, event_id}}
    else
      _other -> {:error, :invalid_metric_record}
    end
  end

  def decode_record(_raw), do: {:error, :invalid_metric_record}

  @doc "Replays only the bounded tail of the metrics stream."
  @spec replay(Path.t(), keyword()) :: replay()
  def replay(path, opts \\ []) do
    record_limit = Options.positive(opts, :record_limit, 2_000)
    max_bytes = Options.positive(opts, :max_bytes, 8 * 1_024 * 1_024)

    case tail_lines(path, record_limit, max_bytes) do
      {:ok, lines, truncated?} -> reduce_lines(lines, truncated?)
      {:error, :enoent} -> empty_replay()
      {:error, reason} -> replay_failed(path, reason)
    end
  end

  @doc "Appends a batch with one file open and no per-event directory work."
  @spec append_batch(Path.t(), [map()]) :: :ok | {:error, term()}
  def append_batch(_path, []), do: :ok

  def append_batch(path, records) when is_binary(path) and is_list(records) do
    lines = Enum.map(records, &[Jason.encode!(&1), "\n"])
    File.write(path, lines, [:append])
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  end

  @doc "Atomically replaces the stream with one latest snapshot per retained Decision."
  @spec compact(Path.t(), [map()]) :: :ok | {:error, term()}
  def compact(path, records) when is_binary(path) and is_list(records) do
    lines =
      records
      |> Enum.sort_by(&Map.get(&1, "last_observed_at", Map.get(&1, :last_observed_at, "")))
      |> Enum.map(&[Jason.encode!(&1), "\n"])

    Fs.atomic_write(path, lines, fsync: true, mode: 0o600)
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  end

  defp tail_lines(path, record_limit, max_bytes) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, fd} -> read_tail(fd, record_limit, max_bytes)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_tail(fd, record_limit, max_bytes) do
    read_tail_contents(fd, record_limit, max_bytes)
  after
    :file.close(fd)
  end

  defp read_tail_contents(fd, record_limit, max_bytes) do
    with {:ok, size} <- :file.position(fd, :eof),
         offset = max(size - max_bytes, 0),
         {:ok, ^offset} <- :file.position(fd, offset),
         {:ok, tail} <- read_bytes(fd, size - offset) do
      tail
      |> drop_partial_prefix(offset > 0)
      |> select_lines(record_limit, offset > 0)
    end
  end

  defp read_bytes(_fd, 0), do: {:ok, ""}

  defp read_bytes(fd, bytes) do
    case :file.read(fd, bytes) do
      {:ok, contents} -> {:ok, contents}
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop_partial_prefix(contents, false), do: contents

  defp drop_partial_prefix(contents, true) do
    case :binary.match(contents, "\n") do
      {index, 1} -> binary_part(contents, index + 1, byte_size(contents) - index - 1)
      :nomatch -> ""
    end
  end

  defp select_lines(contents, record_limit, byte_truncated?) do
    lines = String.split(contents, "\n", trim: true)
    line_truncated? = length(lines) > record_limit
    {:ok, Enum.take(lines, -record_limit), byte_truncated? or line_truncated?}
  end

  defp reduce_lines(lines, truncated?) do
    {samples, records, event_ids, invalid?} =
      Enum.reduce(lines, {%{}, %{}, [], false}, fn line, {samples, records, event_ids, invalid?} ->
        with {:ok, decoded} <- Jason.decode(line),
             {:ok, {sample, event_id}} <- decode_record(decoded) do
          {
            Map.put(samples, sample.decision_id, sample),
            Map.put(records, sample.decision_id, decoded),
            [event_id | event_ids],
            invalid?
          }
        else
          _other -> {samples, records, event_ids, true}
        end
      end)

    %{
      samples: samples,
      records: records,
      event_ids: Enum.reverse(event_ids),
      record_count: length(lines),
      truncated?: truncated? or invalid?
    }
  end

  defp replay_failed(path, reason) do
    Logger.warning("decision_metrics replay_failed path=#{path} reason=#{inspect(reason)}")
    %{empty_replay() | truncated?: true}
  end

  defp empty_replay do
    %{samples: %{}, records: %{}, event_ids: [], record_count: 0, truncated?: false}
  end
end
