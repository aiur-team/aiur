defmodule Aiur.OpenAICompat.Concurrency do
  @moduledoc false

  @counter_key {__MODULE__, :counters}
  @slots 64

  @spec with_slot(String.t(), (-> result)) :: {result, pos_integer()} when result: term()
  def with_slot(backend, fun) when is_binary(backend) and is_function(fun, 0) do
    counters = counters()
    index = index(backend)
    :counters.add(counters, index, 1)
    in_flight = :counters.get(counters, index)

    try do
      {fun.(), in_flight}
    after
      :counters.sub(counters, index, 1)
    end
  end

  @spec current(String.t()) :: non_neg_integer()
  def current(backend) when is_binary(backend) do
    counters() |> :counters.get(index(backend)) |> max(0)
  end

  defp counters do
    case :persistent_term.get(@counter_key, nil) do
      nil -> create_counters()
      counters -> counters
    end
  end

  defp create_counters do
    :global.trans(@counter_key, fn ->
      case :persistent_term.get(@counter_key, nil) do
        nil ->
          counters = :counters.new(@slots, [:write_concurrency])
          :persistent_term.put(@counter_key, counters)
          counters

        counters ->
          counters
      end
    end)
  end

  defp index(backend), do: :erlang.phash2(backend, @slots) + 1
end
