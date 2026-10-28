defmodule Aiur.CodingAgent.LabelClassification do
  @moduledoc false
  alias Aiur.Issue

  @levels Map.new(0..5, &{"complexity:#{&1}", &1})
  @key {__MODULE__, :complexity}

  @spec complexity_level(Issue.t()) :: non_neg_integer() | nil
  def complexity_level(issue) do
    labels = Issue.label_names(issue)
    cache = Process.get(@key, %{})

    case Map.fetch(cache, labels) do
      {:ok, level} ->
        level

      :error ->
        level = classify(labels)
        Process.put(@key, Map.put(if(map_size(cache) < 256, do: cache, else: %{}), labels, level))
        level
    end
  end

  @spec prepare([Issue.t()]) :: map()
  def prepare(issues) do
    previous = Process.get(@key, %{})

    current =
      Enum.reduce(issues, %{}, fn issue, current ->
        labels = Issue.label_names(issue)
        Map.put_new_lazy(current, labels, fn -> Map.get_lazy(previous, labels, fn -> classify(labels) end) end)
      end)

    Process.put(@key, current)
    current
  end

  @spec with_cache(map(), (-> result)) :: result when result: var
  def with_cache(cache, fun) do
    previous = Process.put(@key, cache)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  defp classify(labels), do: labels |> Enum.map(&level/1) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)

  defp level("complexity:" <> <<first, _rest::binary>> = label) when first in ?0..?9 do
    case Map.fetch(@levels, label) do
      {:ok, level} ->
        level

      :error ->
        "complexity:" <> digits = label

        case Integer.parse(digits) do
          {level, ""} -> level
          _ -> nil
        end
    end
  end

  defp level(_label), do: nil
end
