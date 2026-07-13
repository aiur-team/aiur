defmodule Aiur.SystemCpu do
  @moduledoc """
  Samples short-window host CPU headroom from Linux `/proc/stat`.

  CPU counters are cumulative, so callers retain one snapshot and compare it
  with the next poll. Missing or malformed procfs data returns `:unavailable`
  and lets admission fall back to the load-average envelope.
  """

  @type snapshot :: %{total: non_neg_integer(), idle: non_neg_integer(), runnable: non_neg_integer()}
  @type headroom :: %{idle_percent: float(), runnable: non_neg_integer()}

  @spec snapshot() :: snapshot() | :unavailable
  def snapshot do
    case stat_source().() do
      {:ok, contents} -> parse(contents)
      _other -> :unavailable
    end
  end

  @spec headroom(snapshot() | nil, snapshot() | :unavailable) :: headroom() | :unavailable
  def headroom(%{total: previous_total, idle: previous_idle}, %{total: total, idle: idle, runnable: runnable})
      when total > previous_total and idle >= previous_idle do
    total_delta = total - previous_total
    idle_delta = idle - previous_idle

    if idle_delta <= total_delta do
      %{idle_percent: idle_delta * 100.0 / total_delta, runnable: runnable}
    else
      :unavailable
    end
  end

  def headroom(_previous, _current), do: :unavailable

  defp parse(contents) when is_binary(contents) do
    with [cpu_line | _rest] <- String.split(contents, "\n", trim: true),
         ["cpu" | fields] <- String.split(cpu_line),
         {:ok, counters} <- parse_counters(fields),
         {:ok, runnable} <- parse_runnable(contents),
         true <- length(counters) >= 4 do
      total = counters |> Enum.take(8) |> Enum.sum()
      idle = Enum.at(counters, 3)
      %{total: total, idle: idle, runnable: runnable}
    else
      _other -> :unavailable
    end
  end

  defp parse(_contents), do: :unavailable

  defp parse_counters(fields) do
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, values} ->
      case Integer.parse(field) do
        {value, ""} when value >= 0 -> {:cont, {:ok, [value | values]}}
        _other -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp parse_runnable(contents) do
    Enum.find_value(String.split(contents, "\n", trim: true), :error, fn line ->
      case String.split(line) do
        ["procs_running", value] -> parse_non_negative_integer(value)
        _other -> nil
      end
    end)
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> :error
    end
  end

  defp stat_source do
    Application.get_env(:aiur, :proc_stat_source_override, fn -> File.read("/proc/stat") end)
  end
end
