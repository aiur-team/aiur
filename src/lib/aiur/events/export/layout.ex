defmodule Aiur.Events.Export.Layout do
  @moduledoc false
  # aiur:event-bus-boundary-member
  alias Aiur.Config.Paths
  alias Aiur.Events.Journal
  alias Aiur.JsonStore

  @max_bytes 8 * 1024 * 1024
  @event_keys ~w(type seq v instance id topic class occurred_at observed_at source refs attrs payload_version anchor)

  @spec directory() :: {:ok, Path.t()} | {:error, atom()}
  def directory do
    case Paths.runtime_state_dir() do
      {:ok, root} -> {:ok, Path.join(root, "events/export")}
      _ -> {:error, :runtime_dir_unavailable}
    end
  end

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @spec segment(Path.t(), pos_integer()) :: Path.t()
  def segment(dir, first), do: Path.join(dir, "seg.#{first}.ndjson")

  @spec segments(Path.t()) :: [{pos_integer(), Path.t()}]
  def segments(dir) do
    dir
    |> Path.join("seg.*.ndjson")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Regex.run(~r/^seg\.([1-9][0-9]*)\.ndjson$/, Path.basename(path)) do
        [_, seq] -> [{String.to_integer(seq), path}]
        _ -> []
      end
    end)
    |> Enum.sort()
  end

  @spec validate(term()) :: {:ok, map()} | {:error, atom()}
  def validate(%{"type" => type, "seq" => seq} = record) when type in ["event", "gap"] and is_integer(seq) and seq > 0 do
    if valid_record?(record), do: {:ok, record}, else: {:error, :invalid_record}
  end

  def validate(_), do: {:error, :invalid_record}

  defp valid_record?(%{"type" => "gap", "scope" => "*", "reason" => "exporter_start", "from" => from, "to" => to}),
    do: (is_nil(from) or is_binary(from)) and is_binary(to)

  defp valid_record?(%{"type" => "event", "v" => 1, "id" => id, "topic" => topic, "instance" => instance} = record) do
    Enum.all?([
      Enum.sort(Map.keys(record)) == Enum.sort(@event_keys),
      is_integer(id) and id > 0,
      is_binary(topic),
      is_binary(instance) and instance != "",
      record["class"] in ["ephemeral", "live", "ledgered", "logged", "journaled"],
      is_binary(record["source"]),
      is_map(record["refs"]),
      is_map(record["attrs"]),
      is_integer(record["payload_version"]) and record["payload_version"] > 0,
      is_nil(record["anchor"]),
      timestamp?(record["occurred_at"]),
      timestamp?(record["observed_at"])
    ])
  end

  defp valid_record?(_), do: false

  defp timestamp?(nil), do: true
  defp timestamp?(value) when is_binary(value), do: match?({:ok, _, _}, DateTime.from_iso8601(value))
  defp timestamp?(_), do: false

  @spec replay(Path.t(), boolean()) :: {:ok, [map()]} | {:error, term()}
  def replay(path, repair?), do: Journal.replay(path, &validate/1, repair_torn_tail: repair?, max_file_bytes: @max_bytes)

  @spec recover(Path.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def recover(dir, instance) do
    paths = segments(dir)

    with {:ok, meta} <- JsonStore.read(Path.join(dir, "export.meta.json")),
         {:ok, summary} <- recover_segments(paths),
         {:ok, epoch} <- epoch(meta, instance, summary.last) do
      last = summary.last
      head = if(last, do: last["seq"], else: 0)
      oldest = if(summary.first, do: summary.first["seq"], else: 1)

      path =
        case List.last(paths) do
          nil -> segment(dir, head + 1)
          {_, path} -> path
        end

      {:ok, %{instance: instance, epoch: epoch, oldest_seq: oldest, head_seq: head, path: path, last_at: last && (last["observed_at"] || last["to"])}}
    else
      _ -> {:error, :journal_corrupt}
    end
  end

  defp recover_segments(paths) do
    result =
      Enum.reduce_while(paths, {:ok, %{first: nil, last: nil}}, fn {first, path}, {:ok, summary} ->
        with {:ok, records} <- replay(path, false),
             true <- dense?(records, first),
             true <- is_nil(summary.last) or first == summary.last["seq"] + 1 do
          {:cont, {:ok, %{first: summary.first || List.first(records), last: List.last(records) || summary.last}}}
        else
          _ -> {:halt, {:error, :journal_corrupt}}
        end
      end)

    # Validate complete lines before permitting writer-only tail repair.
    with {:ok, summary} <- result,
         :ok <- repair_newest(paths) do
      {:ok, summary}
    end
  end

  defp repair_newest([]), do: :ok

  defp repair_newest(paths) do
    {_, path} = List.last(paths)

    case replay(path, true) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @spec dense?([map()], pos_integer()) :: boolean()
  def dense?(records, first), do: records |> Enum.with_index(first) |> Enum.all?(fn {r, seq} -> r["seq"] == seq end)

  defp epoch(nil, _instance, nil), do: {:ok, Base.encode32(:crypto.strong_rand_bytes(16), padding: false)}
  defp epoch(%{"v" => 1, "instance" => instance, "epoch" => epoch}, instance, _) when is_binary(epoch) and epoch != "", do: {:ok, epoch}
  defp epoch(_, _, _), do: {:error, :journal_corrupt}

  @spec write_meta(Path.t(), map()) :: :ok
  def write_meta(dir, state) do
    meta = state |> Map.take([:instance, :epoch, :oldest_seq, :head_seq]) |> Map.put(:v, 1)
    JsonStore.write!(Path.join(dir, "export.meta.json"), meta, mode: 0o600)
  end
end
