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
    meta = read_meta(dir)
    :ok = archive_previous_instance(dir, meta, instance)
    meta = current_meta(meta, instance)
    floor = retained_floor(meta)
    paths = Enum.reject(segments(dir), fn {first, _} -> first < floor end)

    with {:ok, summary} <- recover_segments(paths),
         {:ok, epoch} <- epoch(meta, instance, summary.last) do
      last = summary.last
      head = if(last, do: last["seq"], else: empty_head(paths))
      oldest = if(summary.first, do: summary.first["seq"], else: head + 1)

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

  defp current_meta(%{"instance" => instance} = meta, instance), do: meta
  defp current_meta(_, _), do: nil
  defp retained_floor(nil), do: 1
  defp retained_floor(meta), do: meta["oldest_seq"]

  defp empty_head([]), do: 0
  defp empty_head(paths), do: elem(List.last(paths), 0) - 1

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

  defp epoch(nil, _instance, _last), do: {:ok, Base.encode32(:crypto.strong_rand_bytes(16), padding: false)}
  defp epoch(%{"v" => 1, "instance" => instance, "epoch" => epoch}, instance, _) when is_binary(epoch) and epoch != "", do: {:ok, epoch}
  defp epoch(_, _, _), do: {:error, :journal_corrupt}

  defp read_meta(dir) do
    case JsonStore.read(Path.join(dir, "export.meta.json")) do
      {:ok, meta} ->
        if valid_meta?(meta), do: meta, else: nil

      {:error, %Jason.DecodeError{}} ->
        nil

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read export metadata", path: dir
    end
  end

  defp valid_meta?(%{"v" => 1, "epoch" => epoch, "instance" => instance, "oldest_seq" => oldest, "head_seq" => head}) do
    is_binary(epoch) and epoch != "" and is_binary(instance) and is_integer(oldest) and oldest > 0 and is_integer(head) and head >= oldest - 1
  end

  defp valid_meta?(_), do: false

  defp archive_previous_instance(dir, %{"instance" => previous, "epoch" => epoch}, instance) when previous != instance do
    archive = Path.join(dir, "old-#{epoch}")
    if Path.basename(archive) != "old-#{epoch}", do: raise("Invalid export epoch")
    File.mkdir_p!(archive)
    File.chmod!(archive, 0o700)
    Enum.each(segments(dir), fn {_, path} -> File.rename!(path, Path.join(archive, Path.basename(path))) end)
    File.rename!(Path.join(dir, "export.meta.json"), Path.join(archive, "export.meta.json"))
    :ok
  end

  defp archive_previous_instance(_, _, _), do: :ok

  @spec trim!([map()], map()) :: {[Path.t()], map()}
  def trim!(segments, %{meta: meta, now: now, retention_days: days, retention_max_events: bound}) do
    cutoff = DateTime.add(now, -days * 86_400, :second)
    {closed, active} = Enum.split(segments, -1)
    retained = Enum.reduce(segments, 0, &(&1.count + &2))

    {deleted, _} =
      Enum.reduce_while(closed, {[], retained}, fn segment, {deleted, count} ->
        expired = segment.newest_at && DateTime.compare(segment.newest_at, cutoff) == :lt

        if segment.first < meta.oldest_seq or expired or count - segment.count >= bound do
          {:cont, {[segment.path | deleted], count - segment.count}}
        else
          {:halt, {deleted, count}}
        end
      end)

    remaining = Enum.drop(closed, length(deleted)) ++ active

    oldest =
      case remaining do
        [first | _] -> first.first
        [] -> meta.oldest_seq
      end

    {Enum.reverse(deleted), %{meta | oldest_seq: max(meta.oldest_seq, oldest)}}
  end

  @spec segment_info!(Path.t()) :: [map()]
  def segment_info!(dir) do
    Enum.map(segments(dir), fn {first, path} ->
      {:ok, records} = replay(path, false)
      last = List.last(records)
      timestamp = last && (last["observed_at"] || last["to"])

      newest =
        case timestamp && DateTime.from_iso8601(timestamp) do
          {:ok, time, _} -> time
          _ -> nil
        end

      %{first: first, path: path, count: length(records), newest_at: newest}
    end)
  end

  @spec write_meta(Path.t(), map()) :: :ok
  def write_meta(dir, state) do
    meta = state |> Map.take([:instance, :epoch, :oldest_seq, :head_seq]) |> Map.put(:v, 1)
    JsonStore.write!(Path.join(dir, "export.meta.json"), meta, mode: 0o600)
  end
end
