defmodule Aiur.Experiments.Packs.DeliverySpeed.Periods do
  @moduledoc false
  alias Aiur.Experiments.Observation
  alias Aiur.Experiments.Packs.DeliverySpeed.Tickets
  alias Aiur.Experiments.Sources.Common

  @spec observations(String.t(), map(), map()) :: {[Observation.t()], non_neg_integer()}
  def observations(id, data, window) do
    buckets =
      Enum.reduce(data.capacity, %{}, fn sample, acc ->
        sample |> slices() |> Enum.reduce(acc, fn {at, ms}, buckets -> Map.update(buckets, at, [{sample, ms}], &[{sample, ms} | &1]) end)
      end)

    merged = data.tickets |> Map.values() |> Enum.map(&Tickets.event_at(&1, "pr_merged")) |> Enum.filter(&(&1 && Common.in_window?(&1, window))) |> Enum.frequencies_by(&hour/1)

    rows =
      buckets
      |> Enum.sort_by(&elem(&1, 0), DateTime)
      |> Enum.flat_map(&bucket_observation(&1, id, merged))

    {rows, map_size(buckets) - length(rows)}
  end

  defp bucket_observation({at, samples}, id, merged) do
    active? = Enum.any?(samples, fn {sample, _ms} -> sample.running > 0 end)

    case if(active?, do: value(id, samples, Map.get(merged, at, 0))) do
      nil -> []
      value -> [%Observation{unit_id: "hour:" <> DateTime.to_iso8601(at), at: at, value: value, attrs: %{"observed_ms" => Enum.sum(Enum.map(samples, &elem(&1, 1)))}}]
    end
  end

  defp value(_id, [], _merges), do: nil
  defp value("merged_per_hour", _samples, merges), do: merges

  defp value("agents_vs_cap", samples, _merges) do
    valid = Enum.filter(samples, fn {sample, _ms} -> is_number(sample.cap) and sample.cap > 0 end)
    weight = Enum.sum(Enum.map(valid, &elem(&1, 1)))
    if weight > 0, do: Enum.sum(Enum.map(valid, fn {sample, ms} -> sample.running / sample.cap * ms end)) / weight
  end

  defp value(_id, _samples, _merges), do: nil

  defp slices(sample) do
    at = hour(sample.start)
    boundary = DateTime.add(at, 3600, :second)
    finish = if DateTime.compare(sample.end, boundary) == :gt, do: boundary, else: sample.end
    first = {at, DateTime.diff(finish, sample.start, :millisecond)}
    if DateTime.compare(sample.end, boundary) == :gt, do: [first | slices(%{sample | start: boundary})], else: [first]
  end

  defp hour(at), do: %{at | minute: 0, second: 0, microsecond: {0, 0}}
end
