defmodule AiurWeb.OperatorControlCenter.TicketsPanel do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.TicketsPresenter

  # Same geometry as the Units table icons so the two action columns line up.
  @icon_svg ~s(viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true")

  @max_labels 6

  # Filtering runs on the server against the projection, not in a client hook
  # over the rendered rows: the server holds the whole backlog, so the filter
  # keeps answering "which tickets match" as the table gains a paged reveal,
  # rather than quietly narrowing to "which rendered tickets match". That costs
  # one round trip per change, and the debounce is what keeps it from being one
  # per character: long enough to collapse a burst of typing into a single
  # filter, short enough that a pause to read still feels immediate.
  @search_debounce_ms 150

  # The server clamps the query too; this is the matching UI affordance, so the
  # operator's input stops where the filter stops rather than silently
  # disagreeing with it.
  @max_query_length 128

  attr(:view, :map, required: true)
  attr(:visible, :integer, default: nil)
  attr(:search_event, :string, default: "search-tickets")
  attr(:clear_search_event, :string, default: "clear-ticket-search")

  @spec tickets_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def tickets_panel(assigns) do
    view = TicketsPresenter.normalize(assigns.view)

    # The view arrives already filtered, so the reveal batches and counts the
    # matches. A search that narrows below the revealed count retires the
    # control rather than offering to reveal rows the query excluded.
    matched_rows = Map.get(view, :rows, [])
    # The LiveView holds the reveal count, so the rows past it are never rendered
    # and never reach the client; the control is a real reveal, not a CSS trick.
    visible = assigns[:visible] || TicketsPresenter.initial_reveal()
    rows = Enum.take(matched_rows, visible)
    hidden_count = length(matched_rows) - length(rows)

    assigns =
      assigns
      |> assign(:status, Map.get(view, :status, :unavailable))
      |> assign(:message, Map.get(view, :message))
      |> assign(:rows, rows)
      |> assign(:hidden_count, hidden_count)
      |> assign(:reveal_label, reveal_label(visible, hidden_count))
      |> assign(:count_label, TicketsPresenter.count_label(view))
      |> assign(:query, Map.get(view, :query, ""))
      |> assign(:search_status, Map.get(view, :search_status, :inactive))
      |> assign(:search_message, Map.get(view, :search_message))
      |> assign(:announcement, TicketsPresenter.search_announcement(view))
      # Searching a listing that has no rows at all would be a control with
      # nothing behind it, so the input appears only once there is a backlog.
      |> assign(:searchable?, Map.get(view, :total_count, 0) > 0)
      |> assign(:search_debounce_ms, @search_debounce_ms)
      |> assign(:max_query_length, @max_query_length)

    ~H"""
    <section class="section-card tickets-card" aria-labelledby="tickets-title">
      <div class="rs-group-head">
        <span class="rs-group-title" id="tickets-title">Tickets</span>
        <span class="rs-group-count">{@count_label}</span>
      </div>

      <form
        :if={@searchable?}
        id="tickets-search-form"
        class="tk-search"
        role="search"
        phx-change={@search_event}
        phx-submit={@search_event}
        aria-label="Search open tickets"
      >
        <label class="sr-only" for="tickets-search">Search tickets by title, description, or ID</label>
        <input
          id="tickets-search"
          class="tk-search-input"
          type="search"
          name="query"
          value={@query}
          placeholder="Filter by title, description, or ID"
          autocomplete="off"
          spellcheck="false"
          maxlength={@max_query_length}
          aria-describedby="tickets-search-hint"
          phx-debounce={@search_debounce_ms}
        />
        <span class="sr-only" id="tickets-search-hint">Matches ticket titles, descriptions, and IDs. Results are announced as you type.</span>
        <%!-- Rendered for as long as the panel is searchable, rather than only while a
        query exists. A button that removes itself takes the keyboard operator's focus
        to the document body with it, and one that disables itself does the same;
        leaving it in place also keeps the input unfocused when the cleared value comes
        back from the server, which is what lets the field actually empty on screen.
        Clearing an already empty query is a no-op, so nothing is lost by keeping it. --%>
        <button
          type="button"
          class="tk-search-clear"
          phx-click={@clear_search_event}
          aria-label="Clear the ticket search"
        >Clear</button>
      </form>

      <p :if={@searchable?} id="tickets-search-status" class="sr-only" role="status" aria-live="polite" aria-atomic="true">{@announcement}</p>

      <div :if={@status in [:stale, :unavailable]} class="units-state readonly-banner" role="status">
        <span aria-hidden="true">◉</span>
        <span>{@message}</span>
      </div>

      <div :if={@status in [:empty, :unsupported]} class="units-state empty-state">{@message}</div>

      <div :if={@searchable? and @search_status == :no_matches} class="units-state empty-state tk-no-matches">{@search_message}</div>

      <div :if={@rows != []} class="units-table-wrap">
        <table id="tickets-table" class="units-table tickets-table" phx-hook="SortableTable" data-sort-table="tickets">
          <caption class="sr-only">Open tickets</caption>
          <thead>
            <tr>
              <th class="tk-col-id" data-sort-key="id" data-sort-type="number">ID</th>
              <th class="tk-col-title" data-sort-key="title">Title</th>
              <th class="tk-col-labels" data-sort-key="labels">Labels</th>
              <th class="tk-col-action"><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody id="tickets-rows">
            <tr :for={row <- @rows} id={"ticket-#{row.token}"} class="units-row tickets-row" data-ticket-token={row.token}>
              <td data-label="ID" data-sort-value={row.identifier} class="tk-id-cell ut-open" phx-click="inspect-ticket" phx-value-ticket={row.token}>
                <span class="ut-id-num mono num">{row.identifier}</span>
              </td>

              <td data-label="Title" data-sort-value={row.title} class="tk-title-cell ut-open" phx-click="inspect-ticket" phx-value-ticket={row.token}>
                <div class="ut-title">{row.title || "Title unknown"}</div>
                <span :if={row.state} class="u-lane is-state">
                  <span class="u-lane-dot" aria-hidden="true"></span>{row.state |> to_string() |> String.replace("-", " ") |> String.upcase()}
                </span>
              </td>

              <td data-label="Labels" data-sort-value={Enum.join(row.labels, " ")} class="tk-labels-cell ut-open" phx-click="inspect-ticket" phx-value-ticket={row.token}>
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
