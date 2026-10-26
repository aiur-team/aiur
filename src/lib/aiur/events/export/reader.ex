defmodule Aiur.Events.Export.Reader do
  @moduledoc false
  # aiur:event-bus-boundary-member
  alias Aiur.Events
  alias Aiur.Events.Export.Layout

  @spec read(map(), non_neg_integer(), 1..500, [String.t()], keyword()) :: {:ok, map()} | {:reset, map()} | {:error, :events_unavailable}
  def read(%{state: :available} = status, after_seq, limit, patterns, opts)
      when is_integer(after_seq) and after_seq >= 0 and limit in 1..500 and is_list(patterns) do
    if after_seq < status.oldest_seq - 1 or after_seq > status.head_seq or Keyword.get(opts, :epoch, status.epoch) != status.epoch do
      {:reset, Map.take(status, [:epoch, :head_seq, :oldest_seq])}
    else
      read_records(status, after_seq, limit, patterns)
    end
  end

  def read(_, _, _, _, _), do: {:error, :events_unavailable}

  defp read_records(status, after_seq, limit, patterns) do
    with {:ok, dir} <- Layout.directory(),
         {:ok, records} <- collect(Layout.segments(dir), status, after_seq),
         true <- Layout.dense?(records, after_seq + 1),
         true <- length(records) == status.head_seq - after_seq do
      records = records |> Enum.filter(&matches?(&1, patterns)) |> Enum.take(limit)
      {:ok, Map.take(status, [:instance, :epoch, :head_seq, :oldest_seq]) |> Map.put(:records, records)}
    else
      _ -> {:error, :events_unavailable}
    end
  end

  defp collect(paths, status, after_seq) do
    paths
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{first, path}, index}, {:ok, acc} ->
      next =
        case Enum.at(paths, index + 1) do
          nil -> status.head_seq + 1
          {seq, _} -> seq
        end

      if next <= after_seq + 1 or first > status.head_seq do
        {:cont, {:ok, acc}}
      else
        collect_segment(first, path, status.head_seq, after_seq, acc)
      end
    end)
  end

  defp collect_segment(first, path, head, after_seq, acc) do
    with {:ok, records} <- Layout.replay(path, false),
         true <- Layout.dense?(records, first) do
      visible = Enum.filter(records, &(&1["seq"] > after_seq and &1["seq"] <= head))
      {:cont, {:ok, acc ++ visible}}
    else
      _ -> {:halt, {:error, :journal_corrupt}}
    end
  end

  defp matches?(%{"type" => "gap"}, _patterns), do: true
  defp matches?(%{"topic" => topic}, patterns), do: Enum.any?(patterns, &Events.matches?(&1, topic))
end
