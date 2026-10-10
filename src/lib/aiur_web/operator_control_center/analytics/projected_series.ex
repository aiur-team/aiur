defmodule AiurWeb.OperatorControlCenter.Analytics.ProjectedSeries do
  @moduledoc "Fills only omitted observations whose contiguous measured coverage is retained."

  @spec fill(map(), [map()], (integer() -> integer())) :: map()
  def fill(cells, samples, bucket) do
    Enum.reduce(samples, cells, fn sample, filled ->
      fill_sample(sample, filled, cells, bucket)
    end)
  end

  defp fill_sample(%{sampled?: true, timestamp_ms: timestamp, covered_until_ms: until}, filled, cells, bucket)
       when is_integer(timestamp) and is_integer(until) and until >= timestamp do
    first = bucket.(timestamp)

    case Map.fetch(cells, first) do
      {:ok, value} -> Enum.reduce(first..bucket.(until), filled, &Map.put_new(&2, &1, value))
      :error -> filled
    end
  end

  defp fill_sample(_sample, filled, _cells, _bucket), do: filled
end
