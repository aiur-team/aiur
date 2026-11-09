defmodule AiurWeb.OperatorControlCenter.DecisionOverrides do
  @moduledoc false
  use Phoenix.Component

  attr(:decision, :map, required: true)

  @spec timeline(map()) :: Phoenix.LiveView.Rendered.t()
  def timeline(assigns) do
    assigns = assign(assigns, :rows, Aiur.Commands.override_rows(assigns.decision))

    ~H"""
    <section :if={@rows != []} class="detail-block" aria-label="Overrides">
      <h4>Overrides</h4>
      <ol class="decision-timeline override-timeline">
        <li :for={row <- @rows}>
          <span class="chip attention">{row.label}</span>
          <time datetime={row.at}>{row.at || "Time unknown"}</time>
          <span>{row.actor}</span>
          <span :for={link <- row.links} class="override-link"><a href={link.href}>{link.label}</a></span>
        </li>
      </ol>
    </section>
    """
  end

  attr(:decision, :map, required: true)

  @spec badge(map()) :: Phoenix.LiveView.Rendered.t()
  def badge(assigns) do
    assigns = assign(assigns, :pending, Aiur.Commands.pending_override_status(assigns.decision))

    ~H"""
    <span :if={@pending} class="chip attention override-badge">Override · {@pending.label}</span>
    """
  end
end
