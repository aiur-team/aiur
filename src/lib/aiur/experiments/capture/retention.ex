defmodule Aiur.Experiments.Capture.Retention do
  @moduledoc false
  alias Aiur.Experiments.SpecFields

  @spec run(Path.t(), DateTime.t()) :: :ok
  def run(root, now) do
    cutoff = DateTime.add(now, -365, :day) |> DateTime.to_iso8601() |> String.slice(0, 7)
    oldest = oldest_active_month(Path.dirname(root), cutoff)

    root
    |> Path.join("events-????-??.ndjson")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      month = path |> Path.basename() |> String.slice(7, 7)
      if month < oldest, do: File.rm(path)
    end)
  end

  defp oldest_active_month(root, cutoff) do
    root
    |> Path.join("*/spec.json")
    |> Path.wildcard()
    |> Enum.reduce(cutoff, &spec_month/2)
  end

  defp spec_month(path, oldest) do
    with {:ok, bytes} <- File.read(path), {:ok, spec} <- Jason.decode(bytes) do
      active_month(spec, oldest)
    else
      _error -> "0000-00"
    end
  end

  defp active_month(%{"status" => "active", "windows" => windows}, oldest) when is_map(windows) and map_size(windows) > 0,
    do: windows |> Map.values() |> Enum.reduce(oldest, &window_month/2)

  defp active_month(%{"status" => status}, oldest) when status in ["draft", "concluded", "abandoned"], do: oldest
  defp active_month(_spec, _oldest), do: "0000-00"

  defp window_month(%{"start" => start}, oldest) when is_binary(start) do
    if SpecFields.timestamp?(start), do: min(oldest, String.slice(start, 0, 7)), else: "0000-00"
  end

  defp window_month(_window, _oldest), do: "0000-00"
end
