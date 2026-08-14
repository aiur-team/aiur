defmodule AiurWeb.OperatorControlCenter.TicketDetailModal do
  @moduledoc false

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr(:ticket, :map, default: nil)

  @spec ticket_detail_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def ticket_detail_modal(assigns) do
    ~H"""
    <div :if={@ticket} class="modal-backdrop ticket-detail-backdrop">
      <section
        id="ticket-detail-modal"
        class="modal-panel ticket-detail-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="ticket-detail-title"
        phx-click-away="close-ticket-detail"
        phx-window-keydown="close-ticket-detail"
        phx-key="escape"
        phx-mounted={JS.focus(to: "#ticket-detail-title")}
      >
        <header class="modal-header">
          <div>
            <p class="section-eyebrow">Open ticket</p>
            <h2 id="ticket-detail-title" tabindex="-1">#{@ticket.identifier} {@ticket.title}</h2>
          </div>
          <div class="modal-actions">
            <a :if={@ticket.url} class="tool-btn" href={@ticket.url} target="_blank" rel="noopener noreferrer">Open on tracker</a>
            <button type="button" class="tool-btn" phx-click="close-ticket-detail">Close</button>
          </div>
        </header>

        <div class="ticket-detail-body">
          <dl class="ticket-detail-facts">
            <div>
              <dt>State</dt>
              <dd>{@ticket.state || "Unknown"}</dd>
            </div>
            <div>
              <dt>Assignee</dt>
              <dd>{@ticket.assignee || "Unassigned"}</dd>
            </div>
            <div>
              <dt>Created</dt>
              <dd class="mono num">{timestamp(@ticket.created_at)}</dd>
            </div>
            <div>
              <dt>Updated</dt>
              <dd class="mono num">{timestamp(@ticket.updated_at)}</dd>
            </div>
            <div>
              <dt>Would route to</dt>
              <dd>{routing_sentence(@ticket.routing)}</dd>
            </div>
          </dl>

          <div class="ticket-detail-labels">
            <p class="section-eyebrow">Labels</p>
            <div class="ut-pill-row">
              <span :for={label <- @ticket.labels} class="u-pill u-label">{label}</span>
              <span :if={@ticket.labels == []} class="tk-muted">None</span>
            </div>
          </div>
        </div>
      </section>
    </div>
    """
  end

  defp timestamp(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp timestamp(_at), do: "Unknown"

  defp routing_sentence(%{available?: true, backend: backend} = routing) when is_binary(backend) do
    [backend, routing.resolved_model, routing.effort, routing.remote? && "remote"]
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  defp routing_sentence(_routing), do: "Routing is unavailable"
end
