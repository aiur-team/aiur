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
         {:ok, records, next} <- collect(Layout.segments(dir), status.head_seq, after_seq, limit, patterns),
         true <- length(records) == limit or next == status.head_seq + 1 do
      {:ok, Map.take(status, [:instance, :epoch, :head_seq, :oldest_seq]) |> Map.put(:records, records)}
    else
      _ -> {:error, :events_unavailable}
    end
  end

  defp collect(paths, head, after_seq, limit, patterns) do
    next_paths = Enum.drop(paths, 1) ++ [{head + 1, nil}]

    paths
    |> Enum.zip(next_paths)
    |> Enum.reject(fn {{first, _}, {next, _}} -> next <= after_seq + 1 or first > head end)
    |> Enum.reduce_while({:ok, [], after_seq + 1}, fn {{first, path}, _}, {:ok, acc, next} ->
      collect_segment(first, path, head, {acc, next, limit, patterns})
    end)
  end

  defp collect_segment(first, path, head, {acc, next, limit, patterns}) do
    with {:ok, records} <- Layout.replay(path, false),
         true <- Layout.dense?(records, first) do
      visible = Enum.filter(records, &(&1["seq"] >= next and &1["seq"] <= head))
      accept_segment(visible, acc, next, limit, patterns)
    else
      _ -> {:halt, {:error, :journal_corrupt}}
    end
  end

  defp accept_segment(visible, acc, next, limit, patterns) do
    if Layout.dense?(visible, next) do
      selected = visible |> Enum.filter(&matches?(&1, patterns)) |> Enum.take(limit - length(acc))
      acc = acc ++ selected
      next = if visible == [], do: next, else: List.last(visible)["seq"] + 1
      action = if length(acc) == limit, do: :halt, else: :cont
      {action, {:ok, acc, next}}
    else
      {:halt, {:error, :journal_corrupt}}
    end
  end

  defp matches?(%{"type" => "gap"}, _patterns), do: true
  defp matches?(%{"topic" => topic}, patterns), do: Enum.any?(patterns, &Events.matches?(&1, topic))
end
