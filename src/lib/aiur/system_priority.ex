defmodule Aiur.SystemPriority do
  @moduledoc "Reads Linux nice values and CPU ticks from `/proc/<pid>/stat` without assuming launch priority."

  @spec nice() :: integer() | :unavailable
  def nice do
    source = Application.get_env(:aiur, :proc_self_stat_source_override, fn -> File.read("/proc/self/stat") end)

    with {:ok, contents} when is_binary(contents) <- source.(),
         {:ok, %{nice: nice}} <- parse_stat(contents) do
      nice
    else
      _ -> :unavailable
    end
  end

  @doc """
  Parses one `/proc/<pid>/stat` line into its nice value, own CPU ticks
  (utime + stime, excluding reaped children) and start time. The command name
  may contain spaces and parentheses, so fields are counted after the last `) `.
  """
  @spec parse_stat(term()) :: {:ok, %{nice: integer(), ticks: non_neg_integer(), start: non_neg_integer()}} | :error
  def parse_stat(contents) when is_binary(contents) do
    with [_, rest] <- Regex.run(~r/^\d+ \(.*\) (.+)$/s, String.trim(contents)),
         fields when length(fields) >= 20 <- String.split(rest),
         {:ok, [utime, stime, nice, start]} <- integers(Enum.map([11, 12, 16, 19], &Enum.at(fields, &1))),
         true <- nice >= -20 and nice <= 19 and utime >= 0 and stime >= 0 and start >= 0 do
      {:ok, %{nice: nice, ticks: utime + stime, start: start}}
    else
      _ -> :error
    end
  end

  def parse_stat(_contents), do: :error

  defp integers(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case Integer.parse(value) do
        {integer, ""} -> {:cont, {:ok, acc ++ [integer]}}
        _ -> {:halt, :error}
      end
    end)
  end
end
