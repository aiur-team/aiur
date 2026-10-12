defmodule Aiur.SystemCpu do
  @moduledoc """
  Samples short-window host CPU headroom from Linux `/proc/stat`.

  CPU counters are cumulative, so callers retain one snapshot and compare it
  with the next poll. Each snapshot also embeds the latest
  `Aiur.BackgroundCpu` reading: CPU of processes niced above the daemon. Only
  that background share counts as reclaimable beside idle time. The aggregate
  nice column is reported for information only, because the fleet inherits
  the daemon's nice and would be inside it. Missing or malformed procfs data
  returns `:unavailable` and lets admission fall back to the load-average
  envelope; a missing background reading means no discount.
  """

  @type snapshot :: %{
          optional(:background) => Aiur.BackgroundCpu.reading() | :unavailable,
          total: non_neg_integer(),
          idle: non_neg_integer(),
          nice: non_neg_integer(),
          runnable: non_neg_integer()
        }
  @type headroom :: %{
          daemon_nice: integer() | :unavailable,
          background_percent: float() | :unavailable,
          idle_percent: float(),
          nice_percent: float(),
          reclaimable_percent: float(),
          runnable: non_neg_integer()
        }

  @spec snapshot() :: snapshot() | :unavailable
  def snapshot do
    case counters() do
      %{} = counters -> Map.put(counters, :background, Aiur.BackgroundCpu.latest())
      unavailable -> unavailable
    end
  end

  @doc "Parses the aggregate `/proc/stat` counters without the background reading."
  @spec counters() :: map() | :unavailable
  def counters do
    case stat_source().() do
      {:ok, contents} -> parse(contents)
      _other -> :unavailable
    end
  end

  @spec headroom(snapshot() | nil, snapshot() | :unavailable) :: headroom() | :unavailable
  def headroom(%{total: previous_total, idle: previous_idle} = previous, %{total: total, idle: idle, runnable: runnable} = current)
      when total > previous_total and idle >= previous_idle do
    total_delta = total - previous_total
    idle_delta = idle - previous_idle
    nice_delta = Map.get(current, :nice, 0) - Map.get(previous, :nice, 0)

    if nice_delta >= 0 and idle_delta + nice_delta <= total_delta do
      idle_percent = percentage(idle_delta, total_delta)
      {daemon_nice, background} = background(Map.get(previous, :background), Map.get(current, :background))

      %{
        daemon_nice: daemon_nice,
        background_percent: background,
        idle_percent: idle_percent,
        nice_percent: percentage(nice_delta, total_delta),
        reclaimable_percent: min(100.0, idle_percent + if(is_float(background), do: background, else: 0.0)),
        runnable: runnable
      }
    else
      :unavailable
    end
  end

  def headroom(_previous, _current), do: :unavailable

  # Both readings must come from the same sampler epoch (same daemon nice) and
  # move forward; anything else is unknown, never zero.
  defp background(%{epoch: epoch, ticks: t0, cpu_total: c0}, %{epoch: epoch, daemon_nice: nice, ticks: t1, cpu_total: c1})
       when is_integer(nice) and t1 >= t0 and c1 > c0,
       do: {nice, min(100.0, percentage(t1 - t0, c1 - c0))}

  defp background(_previous, %{daemon_nice: nice}) when is_integer(nice), do: {nice, :unavailable}
  defp background(_previous, _current), do: {:unavailable, :unavailable}

  defp parse(contents) when is_binary(contents) do
    lines = String.split(contents, "\n", trim: true)

    with [cpu_line | _rest] <- lines,
         ["cpu" | fields] <- String.split(cpu_line),
         {:ok, counters} <- parse_counters(fields),
         {:ok, runnable} <- parse_runnable(lines),
         true <- length(counters) >= 4 do
      total = counters |> Enum.take(8) |> Enum.sum()
      idle = Enum.at(counters, 3)
      nice = Enum.at(counters, 1)
      %{total: total, idle: idle, nice: nice, runnable: runnable}
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

  defp parse_runnable(lines) do
    Enum.find_value(lines, :error, fn line ->
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

  defp percentage(value, total), do: value * 100.0 / total

  defp stat_source do
    Application.get_env(:aiur, :proc_stat_source_override, fn -> File.read("/proc/stat") end)
  end
end
