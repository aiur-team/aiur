defmodule Aiur.SystemPressure do
  @moduledoc "Reads Linux CPU PSI some averages as percentages of stalled time."

  @type sample :: %{avg10: float(), avg60: float()}

  @spec cpu() :: sample() | :unavailable
  def cpu do
    source = Application.get_env(:aiur, :cpu_pressure_source_override, fn -> File.read("/proc/pressure/cpu") end)

    case source.() do
      {:ok, contents} -> parse(contents)
      _ -> :unavailable
    end
  end

  @spec parse(binary()) :: sample() | :unavailable
  def parse(contents) do
    with line when is_binary(line) <- Enum.find(String.split(contents, "\n"), &String.starts_with?(&1, "some ")),
         fields = line |> String.split() |> Enum.drop(1) |> Enum.map(&String.split(&1, "=", parts: 2)),
         true <- Enum.all?(fields, &(length(&1) == 2)),
         values = Map.new(fields, fn [key, value] -> {key, value} end),
         {:ok, avg10} <- percentage(values["avg10"]),
         {:ok, avg60} <- percentage(values["avg60"]) do
      %{avg10: avg10, avg60: avg60}
    else
      _ -> :unavailable
    end
  end

  defp percentage(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} when number >= 0 and number <= 100 -> {:ok, number}
      _ -> :unavailable
    end
  end

  defp percentage(_), do: :unavailable

  @spec print_sample(map()) :: :ok
  def print_sample(capacity) do
    pressure = Map.get(capacity, :cpu_pressure, :unavailable)
    age = sample_age(capacity)

    case pressure do
      %{avg10: avg10, avg60: avg60} ->
        IO.puts("DISPATCH CPU PSI some avg10=#{avg10}% avg60=#{avg60}% threshold=#{inspect(capacity[:pressure_threshold])}% target=#{inspect(capacity[:pressure_target])}%#{age}")

      _ ->
        IO.puts("DISPATCH CPU PSI unavailable; load-average fallback#{age}")
    end

    IO.puts("DISPATCH MEMORY available_mb=#{inspect(capacity[:memory_mb] || :unavailable)} threshold_mb=#{inspect(capacity[:memory_threshold_mb])}#{age}")
  end

  defp sample_age(%{load_sampled_at_ms: sampled_at}) when is_integer(sampled_at),
    do: " sampled=#{div(max(0, System.monotonic_time(:millisecond) - sampled_at), 1_000)}s ago"

  defp sample_age(_), do: " sampled=unavailable"
end
