defmodule Aiur.RunTelemetry.ResourceSamples do
  @moduledoc "Bounds resource observations and records only contiguous measured coverage."
  @limit 180
  @gap_ms 7_500

  @spec push(map(), tuple()) :: tuple()
  def push(sample, {items, samples, count, stride, latest, boots}) do
    samples = extend_head(samples, sample, latest)
    samples = if rem(count, stride) == 0, do: [{count, sample} | samples], else: samples
    {samples, stride} = compact(samples, stride)
    {items, samples, count + 1, stride, sample, boots}
  end

  @spec finish(tuple()) :: [map()]
  def finish({_items, samples, count, _stride, latest, _boots}) do
    values = samples |> Enum.reverse() |> Enum.map(&elem(&1, 1))
    values = if List.last(values) == latest, do: values, else: values ++ [latest]
    if count > length(values), do: Enum.map(values, &put(&1, :sampled?, true)), else: values
  end

  defp extend_head([{index, previous} | rest], sample, latest) do
    previous = if measured?(latest), do: extend(previous, sample), else: previous
    [{index, previous} | rest]
  end

  defp extend_head([], _sample, _latest), do: []

  defp compact(samples, stride) when length(samples) >= @limit do
    stride = stride * 2
    compacted = Enum.reduce(Enum.reverse(samples), [], &compact_sample(&1, &2, stride))
    {compacted, stride}
  end

  defp compact(samples, stride), do: {samples, stride}

  defp compact_sample({index, sample} = item, kept, stride) do
    if rem(index, stride) == 0, do: [item | kept], else: extend_head(kept, sample, sample)
  end

  defp extend(previous, sample) do
    until = field(previous, :covered_until_ms) || field(previous, :timestamp_ms)
    timestamp = field(sample, :timestamp_ms)

    if same_segment?(previous, sample) and adjacent?(until, timestamp) do
      put(previous, :covered_until_ms, field(sample, :covered_until_ms) || timestamp)
    else
      previous
    end
  end

  defp same_segment?(previous, sample),
    do: measured?(previous) and measured?(sample) and field(previous, :boot_id) == field(sample, :boot_id)

  defp adjacent?(until, timestamp),
    do: is_integer(until) and is_integer(timestamp) and timestamp >= until and timestamp - until <= @gap_ms

  defp measured?(nil), do: false
  defp measured?(sample), do: field(sample, :availability) == "measured"
  defp field(sample, key), do: Map.get(sample, key, Map.get(sample, Atom.to_string(key)))

  defp put(%{"timestamp_ms" => _} = sample, :sampled?, value), do: Map.put(sample, "sampled", value)
  defp put(%{"timestamp_ms" => _} = sample, key, value), do: Map.put(sample, Atom.to_string(key), value)
  defp put(sample, key, value), do: Map.put(sample, key, value)
end
