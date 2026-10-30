defmodule AiurWeb.Build.OverrideSummary do
  @moduledoc "Pending Command overrides on the current fleet overview."
  use Phoenix.Component
  alias AiurWeb.OperatorControlCenter.DecisionCommands

  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket), do: assign(socket, :fleet_overrides, DecisionCommands.pending_overrides())

  attr(:state, :any, required: true)

  @spec summary(map()) :: Phoenix.LiveView.Rendered.t()
  def summary(assigns) do
    ~H"""
    <section :if={@state != {:ok, []}} id="fleet-overrides" class="detail-block fleet-overrides" aria-label="Fleet overrides">
      <h2>Pending overrides</h2>
      <p :if={@state == :unavailable}>Override status unavailable</p>
      <ul :if={is_tuple(@state)} class="decision-timeline">
        <li :for={row <- elem(@state, 1)}>
          <.link navigate={row.href} class="chip attention fleet-override-badge">
            Ticket #{row.ticket} · {row.label}
          </.link>
        </li>
      </ul>
    </section>
    """
  end
end
