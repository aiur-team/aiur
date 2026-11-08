defmodule AiurWeb.OperatorControlCenter.CommandRouting do
  @moduledoc false

  use Phoenix.Component

  attr(:decision, :map, required: true)
  attr(:now, :any, required: true)

  @spec routing(map()) :: Phoenix.LiveView.Rendered.t()
  def routing(assigns) do
    assigns =
      assigns
      |> assign(:label, label(assigns.decision))
      |> assign(:visible_at, Map.get(assigns.decision, :human_visible_at))

    ~H"""
    <span class="chip command-route" data-route-state={@decision[:route_state] || "unknown"}>{@label}</span>
    <span :if={@visible_at && Aiur.Commands.needs_you?(@decision)} class="decision-age mono">
      needs you since {age(@visible_at, @now)}
    </span>
    """
  end

  defp label(decision) when not is_map_key(decision, :route_state), do: "Routing…"
  defp label(%{route_state: nil}), do: "Routing…"
  defp label(%{requester: %{"kind" => "executor"}}), do: "From Executor"
  defp label(%{requester: %{kind: :executor}}), do: "From Executor"
  defp label(%{route_state: :with_executor}), do: "With Executor"
  defp label(%{route_state: :with_human}), do: "Needs you"
  defp label(%{route_state: :with_both}), do: "Needs you and Executor"
  defp label(_decision), do: "Routing…"

  defp age(%DateTime{} = at, %DateTime{} = now) do
    minutes = max(div(DateTime.diff(now, at, :second), 60), 0)
    if minutes == 0, do: "just now", else: "#{minutes} min ago"
  end

  defp age(_at, _now), do: "unknown time"
end
