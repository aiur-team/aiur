defmodule AiurWeb.OperatorControlCenter.BuildOrderStatus do
  @moduledoc "Shared provider-health status for Build Order route surfaces."

  use Phoenix.Component

  alias Aiur.BuildOrder.GraphProjection.Snapshot

  attr(:snapshot, :any, default: nil)
  attr(:now, :any, required: true)

  @spec provider_health(map()) :: Phoenix.LiveView.Rendered.t()
  def provider_health(assigns) do
    assigns = assign(assigns, :health, snapshot_health(assigns.snapshot))

    ~H"""
    <div class="bo-provider-health" role="status" aria-live="polite">
      <span class={["status-badge", health_class(@health)]}>{health_label(@health)}</span>
      <span :if={refreshing?(@health)} class="status-badge">Refreshing</span>
      <span :if={health_age(@health, @now)} class="status-badge mono">{health_age(@health, @now)}</span>
    </div>
    """
  end

  defp snapshot_health(%Snapshot{health: health}), do: health
  defp snapshot_health(_snapshot), do: nil
  defp refreshing?(%{refreshing?: true}), do: true
  defp refreshing?(_health), do: false

  defp health_age(%{observed_at: %DateTime{} = observed_at}, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, observed_at, :second), 0)
    "Observed #{seconds}s ago"
  end

  defp health_age(_health, _now), do: nil

  defp health_label(%{state: :healthy}), do: "Healthy"
  defp health_label(%{state: :stale}), do: "Stale"
  defp health_label(%{state: :structurally_invalid}), do: "Structurally invalid"
  defp health_label(_health), do: "Unavailable"

  defp health_class(%{state: :healthy}), do: "status-badge-live"
  defp health_class(%{state: :stale}), do: "is-warning"
  defp health_class(_health), do: "is-unavailable"
end
