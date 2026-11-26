defmodule Aiur.RunTelemetry.SummaryReader do
  @moduledoc """
  Streams retained summaries. Charts retain at most 180 evenly spaced resource
  observations per actor; stored profiles and lifecycle evidence remain intact.
  """

  alias Aiur.RunTelemetry.ResourceSamples
  @collection_limit 10_000
  @token_limit 1024 * 1024
  @retained_limit 24 * 1024 * 1024
  @depth_limit 16

  @spec read(Path.t()) :: {:ok, map()} | {:error, :missing | :invalid_summary}
  def read(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          read_json(file)
        rescue
          _error -> {:error, :invalid_summary}
        after
          File.close(file)
        end

      {:error, _reason} ->
        {:error, :missing}
    end
  end

  @doc "Bounds an already decoded chart series, retaining its first and last samples."
  @spec sample([map()]) :: [map()]
  def sample(values) do
    state = Enum.reduce(values, {[], [], 0, 1, nil, MapSet.new()}, &ResourceSamples.push/2)
    {samples, _old} = finish(state, nil)
    samples
  end

  defp read_json(file) do
    decoders = %{
      null: nil,
      string: &:binary.copy/1,
      array_start: fn old -> container(old, {[], [], 0, 1, nil, MapSet.new()}) end,
      array_push: &array_push/2,
      array_finish: fn acc, old -> finish(acc.value, old) end,
      object_start: fn old -> container(old, %{}) end,
      object_push: &put/3,
      object_finish: fn acc, old -> {acc.value, old} end
    }

    complete(:json.decode_start(read_chunk(file), nil, decoders), file)
  end

  defp complete({:continue, state}, file) do
    if byte_size(elem(state, 0)) > @token_limit, do: raise(ArgumentError, "oversized summary token")
    complete(:json.decode_continue(read_chunk(file), state), file)
  end

  defp complete({value, _acc, rest}, file) when is_map(value) do
    if String.trim(rest) != "", do: raise(ArgumentError, "trailing summary data")
    check_trailing(file)
    {:ok, value}
  end

  defp read_chunk(file) do
    case IO.binread(file, 64 * 1024) do
      :eof -> :end_of_input
      chunk when is_binary(chunk) -> chunk
      {:error, reason} -> raise File.Error, reason: reason, action: "read summary"
    end
  end

  defp check_trailing(file) do
    case read_chunk(file) do
      :end_of_input ->
        :ok

      chunk ->
        if String.trim(chunk) != "", do: raise(ArgumentError, "trailing summary data")
        check_trailing(file)
    end
  end

  defp container(old, value) do
    depth = if is_map(old), do: old.depth + 1, else: 1
    base = if is_map(old), do: old.base + old.bytes, else: 0
    if depth > @depth_limit, do: raise(ArgumentError, "oversized summary depth")
    %{value: value, bytes: 0, base: base, depth: depth}
  end

  defp bounded(acc, value, bytes) do
    if acc.base + bytes > @retained_limit, do: raise(ArgumentError, "oversized retained summary")
    %{acc | value: value, bytes: bytes}
  end

  defp put(key, value, acc) do
    if map_size(acc.value) >= @collection_limit, do: raise(ArgumentError, "oversized summary object")
    bounded(acc, Map.put(acc.value, key, value), acc.bytes + :erlang.external_size({key, value}) + 16)
  end

  defp array_push(value, acc) do
    updated = push(value, acc.value)
    bytes = array_bytes(value, acc.value, updated, acc.bytes)
    bounded(acc, updated, bytes)
  end

  defp array_bytes(%{"availability" => _, "timestamp_ms" => _} = value, old, updated, bytes) do
    {_, _, count, stride, latest, _} = old

    if elem(updated, 3) != stride do
      :erlang.external_size(updated)
    else
      added = if rem(count, stride) == 0, do: :erlang.external_size(value) + 16, else: 0
      bytes + added + :erlang.external_size(value) - :erlang.external_size(latest) + if(added > 0, do: 48, else: 0)
    end
  end

  defp array_bytes(_value, state, state, bytes), do: bytes
  defp array_bytes(value, _old, _updated, bytes), do: bytes + :erlang.external_size(value) + 16

  # Actor samples and stored profiles already hold resource evidence. One
  # resource envelope per boot suffices for boot discovery.
  defp push(%{"kind" => "warning"}, state), do: state

  defp push(%{"kind" => "resource"} = record, {items, samples, count, stride, latest, boots}) do
    if MapSet.member?(boots, record["boot_id"]) do
      {items, samples, count, stride, latest, boots}
    else
      keep(record, {items, samples, count, stride, latest, MapSet.put(boots, record["boot_id"])})
    end
  end

  defp push(%{"availability" => _, "timestamp_ms" => _} = sample, {items, samples, count, stride, latest, boots}) do
    ResourceSamples.push(sample, {items, samples, count, stride, latest, boots})
  end

  defp push(value, state), do: keep(value, state)

  defp keep(value, {items, samples, count, stride, latest, boots}) do
    if count >= @collection_limit, do: raise(ArgumentError, "oversized summary array")
    {[value | items], samples, count + 1, stride, latest, boots}
  end

  defp finish({items, [], _count, _stride, nil, _boots}, old), do: {Enum.reverse(items), old}

  defp finish({items, _samples, _count, _stride, _latest, _boots} = state, old),
    do: {Enum.reverse(items) ++ ResourceSamples.finish(state), old}
end
