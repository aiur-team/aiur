defmodule AiurWeb.OperatorControlCenter.TicketsPanel do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.TicketsPresenter

  # Same geometry as the Units table icons so the two action columns line up.
  @icon_svg ~s(viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true")

  @max_labels 6

  attr(:view, :map, required: true)
  attr(:visible, :integer, default: nil)

  @spec tickets_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def tickets_panel(assigns) do
    all_rows = Map.get(assigns.view, :rows, [])
    # The LiveView holds the reveal count, so the rows past it are never rendered
    # and never reach the client; the control is a real reveal, not a CSS trick.
    visible = assigns[:visible] || TicketsPresenter.initial_reveal()
    rows = Enum.take(all_rows, visible)
    hidden_count = length(all_rows) - length(rows)

    assigns =
      assigns
      |> assign(:status, Map.get(assigns.view, :status, :unavailable))
      |> assign(:message, Map.get(assigns.view, :message))
      |> assign(:rows, rows)
      |> assign(:hidden_count, hidden_count)
      |> assign(:reveal_label, reveal_label(visible, hidden_count))
      |> assign(:count_label, TicketsPresenter.count_label(assigns.view))

    ~H"""
    <section class="section-card tickets-card" aria-labelledby="tickets-title">
      <div class="rs-group-head">
        <span class="rs-group-title" id="tickets-title">Tickets</span>
        <span class="rs-group-count">{@count_label}</span>
      </div>

      <div :if={@status in [:stale, :unavailable]} class="units-state readonly-banner" role="status">
        <span aria-hidden="true">◉</span>
        <span>{@message}</span>
      </div>

      <div :if={@status in [:empty, :unsupported]} class="units-state empty-state">{@message}</div>

      <div :if={@rows != []} class="units-table-wrap">
        <table class="units-table tickets-table">
          <caption class="sr-only">Open tickets</caption>
          <thead>
            <tr>
              <th class="tk-col-id">ID</th>
              <th class="tk-col-title">Title</th>
              <th class="tk-col-labels">Labels</th>
              <th class="tk-col-action"><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody id="tickets-rows">
            <tr :for={row <- @rows} id={"ticket-#{row.token}"} class="units-row tickets-row" data-ticket-token={row.token}>
              <td data-label="ID" class="tk-id-cell ut-open" phx-click="inspect-ticket" phx-value-ticket={row.token}>
                <span class="ut-id-num mono num">{row.identifier}</span>
              </td>

              <td data-label="Title" class="tk-title-cell ut-open" phx-click="inspect-ticket" phx-value-ticket={row.token}>
                <div class="ut-title">{row.title || "Title unknown"}</div>
                <span :if={row.state} class="u-lane is-state">
                  <span class="u-lane-dot" aria-hidden="true"></span>{row.state |> to_string() |> String.replace("-", " ") |> String.upcase()}
                </span>
              </td>

              <td data-label="Labels" class="tk-labels-cell ut-open" phx-click="inspect-ticket" phx-value-ticket={row.token}>
                <div class="ut-pill-row">
                  <span :for={label <- visible_labels(row.labels)} class="u-pill u-label">{label}</span>
                  <span :if={hidden_label_count(row.labels) > 0} class="u-pill u-label is-more">+{hidden_label_count(row.labels)}</span>
                  <span :if={row.labels == []} class="tk-muted">None</span>
                </div>
              </td>

              <td data-label="Actions" class="tk-action-cell">
                <button
                  id={"ticket-add-agent-#{row.token}"}
                  type="button"
                  class="units-icon-action"
                  phx-click="open-add-agent"
                  phx-value-ticket={row.token}
                  aria-label={"Add an agent to ticket #{row.identifier}"}
                  title="Add an agent"
                >{icon(:robot)}</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@hidden_count > 0} class="tickets-more">
        <%!-- No phx-disable-with, unlike History's "Load more": this reveal only
              widens a slice of rows the LiveView already holds, so there is no
              fetch to wait on and a transient disabled state would only flicker. --%>
        <button type="button" class="btn ghost" phx-click="show-more-tickets">{@reveal_label}</button>
      </div>
    </section>
    """
  end

  # The visible text is the whole accessible name: a bare "Show more" says
  # nothing out of context, and a separate aria-label that did not contain the
  # visible text would break label-in-name. The total stays in the panel header,
  # so this names only the step and never repeats the count beside it.
  defp reveal_label(visible, hidden_count) do
    step = min(TicketsPresenter.reveal_more(visible) - visible, hidden_count)

    "Show #{step} more #{if step == 1, do: "ticket", else: "tickets"}"
  end

  defp visible_labels(labels), do: Enum.take(List.wrap(labels), @max_labels)

  defp hidden_label_count(labels), do: max(length(List.wrap(labels)) - @max_labels, 0)

  # Robot line art: a head outline with antenna, eyes, and mouth. Stroke-only so
  # it inherits the icon button's currentColor like every other action icon.
  defp icon(:robot) do
    Phoenix.HTML.raw(
      ~s(<svg #{@icon_svg}><rect x="4" y="8" width="16" height="12" rx="3"/><path d="M12 4v4"/><circle cx="12" cy="3.2" r="1.2"/><path d="M2 13v3M22 13v3"/><path d="M9 13v1.5M15 13v1.5"/><path d="M9.5 17h5"/></svg>)
    )
  end
end
