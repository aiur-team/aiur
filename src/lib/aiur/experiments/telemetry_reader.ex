defmodule Aiur.Experiments.TelemetryReader do
  @moduledoc """
  Shared streaming reader for experiment telemetry. `read/3` accepts a timestamp
  window and source maps with `:path`, `:format` (`:summary` or `:ndjson`) and
  optional `:start`/`:end` boot bounds. Known non-overlapping sources are never
  opened; unknown bounds remain eligible. `history: true` includes earlier
  lifecycle/context evidence. Default resource projection keeps daemon fleet
  evidence; `projection: :all` includes ticket resources. `projection: :fleet`
  keeps slim fleet samples without resource envelopes.

  Limits apply across all sources: 10,000 records, 32 MiB input, 4 MiB retained
  projection, 1 MiB tokens and 16 nesting levels. Keyword overrides are
  `:max_records`, `:max_bytes` and `:max_retained_bytes`. The result carries
  `:records`, `:samples`, `:state`, `:warnings` and `:stats`; `:truncated` means
  a limit stopped the read, and must never become a zero-valued observation.
  """
  alias Aiur.RunTelemetry.Dataset.{Resources, Source}

  @chunk_bytes 16_384
  @token_bytes 1_048_576
  @depth_limit 16
  @fleet_fields [:timestamp, :timestamp_ms, :boot_id, :record_id, :fleet_capacity_status, "fleet_agents_occupied", "fleet_agents_configured"]

  @spec read(map(), [map()], keyword()) :: {:ok, map()}
  def read(window, sources, opts \\ []) do
    key = {__MODULE__, make_ref()}
    state = %{records: [], samples: [], state: :complete, stats: %{bytes_read: 0, records_seen: 0, retained_bytes: 0}, warnings: []}
    Process.put(key, state)

    try do
      for source <- sources, eligible?(source, window, opts) do
        read_source(source, window, opts, key)
      end
    catch
      :limit -> update(key, &%{&1 | state: :truncated})
    end

    result = Process.delete(key)
    {:ok, %{result | records: Enum.reverse(result.records), samples: Enum.reverse(result.samples), warnings: Enum.reverse(result.warnings)}}
  end

  defp eligible?(source, window, opts) do
    before_end = not match?(%DateTime{}, source[:start]) or DateTime.compare(source.start, window.end) == :lt
    after_start = Keyword.get(opts, :history, false) or not match?(%DateTime{}, source[:end]) or DateTime.compare(source.end, window.start) != :lt
    before_end and after_start
  end

  defp read_source(source, window, opts, key) do
    Keyword.get(opts, :on_open, fn _path -> :ok end).(source.path)

    case File.open(source.path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case source.format do
            :ndjson -> ndjson(file, "", 1, source.path, window, opts, key)
            :summary -> summary(file, source.path, window, opts, key)
          end
        rescue
          _invalid -> warning(key, source.path, :invalid_source)
        after
          File.close(file)
        end

      {:error, _reason} ->
        warning(key, source.path, :missing_source)
    end
  end

  defp chunk(file, opts, key) do
    left = Keyword.get(opts, :max_bytes, 33_554_432) - Process.get(key).stats.bytes_read
    if left <= 0, do: throw(:limit)

    case IO.binread(file, min(left, @chunk_bytes)) do
      :eof ->
        :end_of_input

      data when is_binary(data) ->
        update(key, &put_in(&1.stats.bytes_read, &1.stats.bytes_read + byte_size(data)))
        data

      {:error, _reason} ->
        raise ArgumentError, "telemetry read failed"
    end
  end

  defp ndjson(file, pending, line, path, window, opts, key) do
    case chunk(file, opts, key) do
      :end_of_input ->
        if pending != "", do: accept_line(pending, path, line, window, opts, key)

      data ->
        pieces = :binary.split(pending <> data, "\n", [:global])
        {complete, [rest]} = Enum.split(pieces, -1)
        if byte_size(rest) > @token_bytes, do: throw(:limit)

        next = consume_lines(complete, line, path, window, opts, key)

        ndjson(file, rest, next, path, window, opts, key)
    end
  end

  defp consume_lines(lines, first, path, window, opts, key) do
    Enum.reduce(lines, first, fn value, number ->
      if byte_size(value) > @token_bytes, do: throw(:limit)
      if String.trim(value) != "", do: accept_line(value, path, number, window, opts, key)
      number + 1
    end)
  end

  defp accept_line(line, path, number, window, opts, key) do
    count(key, opts)

    case Source.parse_line(line, path, number) do
      {:ok, record} -> keep(record, window, opts, key)
      {:warning, _warning} -> warning(key, path, :invalid_record)
    end
  end

  defp summary(file, path, window, opts, key) do
    decoders = %{
      null: nil,
      string: &:binary.copy/1,
      object_start: &container(&1, %{}),
      object_push: fn name, value, acc -> bounded(acc, Map.put(acc.value, name, value)) end,
      object_finish: fn acc, old -> finish_container(acc, old, path, window, opts, key) end,
      array_start: &container(&1, []),
      array_push: fn
        nil, acc -> acc
        value, acc -> bounded(acc, [value | acc.value])
      end,
      array_finish: fn acc, old -> {Enum.reverse(acc.value), old} end
    }

    complete(:json.decode_start(chunk(file, opts, key), nil, decoders), file, opts, key)
  end

  defp complete({:continue, continuation}, file, opts, key) do
    if byte_size(elem(continuation, 0)) > @token_bytes, do: throw(:limit)
    complete(:json.decode_continue(chunk(file, opts, key), continuation), file, opts, key)
  end

  defp complete({_value, _acc, rest}, file, opts, key) do
    if String.trim(rest) != "", do: raise(ArgumentError, "trailing summary data")
    trailing(file, opts, key)
  end

  defp trailing(file, opts, key) do
    case chunk(file, opts, key) do
      :end_of_input ->
        :ok

      rest ->
        if String.trim(rest) != "", do: raise(ArgumentError, "trailing summary data")
        trailing(file, opts, key)
    end
  end

  defp container(old, value) do
    depth = if is_map(old), do: old.depth + 1, else: 1
    if depth > @depth_limit, do: throw(:limit)
    %{depth: depth, value: value}
  end

  defp bounded(acc, value) do
    if :erlang.external_size(value) > @token_bytes, do: throw(:limit)
    %{acc | value: value}
  end

  defp finish_container(%{depth: 3, value: %{"kind" => _} = object}, %{value: value} = old, path, window, opts, key) when is_list(value),
    do: finish_record(object, old, path, window, opts, key)

  # Actor/ticket projections duplicate the records; retain only their streamed fleet samples.
  defp finish_container(%{depth: 3} = acc, %{value: value} = old, path, window, opts, key) when is_map(value) do
    finish_object(acc.value, old, path, window, opts, key)
    {nil, old}
  end

  defp finish_container(acc, old, path, window, opts, key), do: finish_object(acc.value, old, path, window, opts, key)

  defp finish_object(%{"kind" => _, "schema_version" => _, "record_id" => _, "attributes" => _} = object, old, path, window, opts, key),
    do: finish_record(object, old, path, window, opts, key)

  defp finish_object(%{"fleet_agents_occupied" => _, "timestamp_ms" => _} = sample, old, _path, window, opts, key) do
    count(key, opts)
    at = sample["timestamp"] || DateTime.to_iso8601(DateTime.from_unix!(sample["timestamp_ms"], :millisecond))
    {:ok, timestamp} = Source.parse_timestamp(at)

    if in_window?(timestamp, window) do
      normalized = Enum.reduce(~w(timestamp timestamp_ms boot_id record_id fleet_capacity_status)a, sample, fn field, acc -> Map.put(acc, field, sample[Atom.to_string(field)]) end)
      store_sample(key, Map.put(normalized, :timestamp, timestamp), opts)
    end

    {nil, old}
  end

  defp finish_object(object, old, _path, _window, _opts, _key), do: {object, old}

  defp finish_record(object, old, path, window, opts, key) do
    accept_line(Jason.encode!(object), path, Process.get(key).stats.records_seen + 1, window, opts, key)
    {nil, old}
  end

  defp count(key, opts) do
    if Process.get(key).stats.records_seen >= Keyword.get(opts, :max_records, 10_000), do: throw(:limit)
    update(key, &put_in(&1.stats.records_seen, &1.stats.records_seen + 1))
  end

  defp keep(record, window, opts, key) do
    if keep_record?(record, window, opts) do
      unless record.kind == "resource" and Keyword.get(opts, :projection) == :fleet, do: retain(key, :records, project_attributes(record, opts), opts)
      keep_samples(record, opts, key)
    else
      if record.kind == "warning", do: warning(key, record.source_path, :runtime_warning)
    end
  end

  defp keep_record?(record, window, opts) do
    kinds = Keyword.get(opts, :keep_kinds, ~w(lifecycle run_context restart resource warning))
    record.kind in kinds and keep_resource?(record, opts) and keep_event?(record, opts) and record_window?(record, window, opts)
  end

  defp project_attributes(record, opts) do
    case Keyword.get(opts, :attribute_keys, %{})[record.kind] do
      nil -> record
      keys -> %{record | attributes: Map.take(record.attributes, keys)}
    end
  end

  defp keep_event?(%{kind: "lifecycle", attributes: attrs}, opts) do
    events = Keyword.get(opts, :lifecycle_events)
    is_nil(events) or attrs["event"] in events
  end

  defp keep_event?(_record, _opts), do: true

  defp keep_resource?(%{kind: "resource", attributes: attrs}, opts), do: attrs["actor"] == "_daemon" or Keyword.get(opts, :projection) == :all
  defp keep_resource?(_record, _opts), do: true

  defp record_window?(record, window, opts) do
    history = Keyword.get(opts, :history, false) and record.kind in ~w(lifecycle run_context restart)
    in_window?(record.timestamp, window) or (history and DateTime.compare(record.timestamp, window.end) == :lt)
  end

  defp keep_samples(%{kind: "resource", attributes: %{"actor" => "_daemon"}} = record, opts, key) do
    {actors, _warnings} = Resources.reduce_actors([record], [])
    for sample <- actors["_daemon"].samples, do: store_sample(key, sample, opts)
  end

  defp keep_samples(_record, _opts, _key), do: :ok

  defp store_sample(key, sample, opts) do
    sample = if Keyword.get(opts, :projection) == :fleet, do: Map.take(sample, @fleet_fields), else: sample
    retain(key, :samples, sample, opts)
  end

  defp retain(key, field, value, opts) do
    bytes = :erlang.external_size(value) + 16
    total = Process.get(key).stats.retained_bytes + bytes
    if total > Keyword.get(opts, :max_retained_bytes, 4_194_304), do: throw(:limit)

    update(key, fn state ->
      state |> Map.put(field, [value | Map.fetch!(state, field)]) |> put_in([:stats, :retained_bytes], total)
    end)
  end

  defp in_window?(at, window), do: DateTime.compare(at, window.start) != :lt and DateTime.compare(at, window.end) == :lt

  defp warning(key, path, reason) do
    update(key, fn state ->
      warnings = Enum.take([%{path: path, reason: reason} | state.warnings], 32)
      %{state | state: :partial, warnings: warnings}
    end)
  end

  defp update(key, fun), do: Process.put(key, fun.(Process.get(key)))
end
