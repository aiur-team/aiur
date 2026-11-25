defmodule Aiur.ProviderMeterProjection.Windows do
  @moduledoc "Projects a provider view's windows: stale with their view, unknown once their reset has passed."

  # A window whose recorded reset has passed reads as unknown until it is observed
  # again: its old figure says nothing about the new window.
  @spec project(term(), atom(), DateTime.t()) :: term()
  def project(windows, freshness, now) when is_map(windows) do
    Map.new(windows, fn {limit_id, window} -> {limit_id, project_window(window, freshness, now)} end)
  end

  def project(windows, _freshness, _now), do: windows

  defp project_window(%{resets_at: %DateTime{} = resets_at} = window, freshness, %DateTime{} = now) do
    if DateTime.compare(resets_at, now) == :gt, do: stale_window(window, freshness), else: Map.put(window, :freshness, :unknown)
  end

  defp project_window(window, freshness, _now), do: stale_window(window, freshness)

  defp stale_window(window, :stale), do: Map.put(window, :freshness, :stale)
  defp stale_window(window, _freshness), do: window
end
