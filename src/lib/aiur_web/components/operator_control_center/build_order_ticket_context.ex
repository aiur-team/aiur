defmodule AiurWeb.OperatorControlCenter.BuildOrderTicketContext do
  @moduledoc false

  use Phoenix.Component

  alias Aiur.BuildOrder.{Bounded, Diagnostic}
  alias Aiur.OpaqueIdentifier
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextAdapter
  alias AiurWeb.BuildOrder.TicketContextAdapter.Relationship
  alias AiurWeb.BuildOrder.TicketContextAdapter.View
  alias AiurWeb.BuildOrder.TicketContextSelection
  alias AiurWeb.BuildOrderViewModel.Edge
  alias AiurWeb.OperatorControlCenter.TicketContext

  @edge_states [:cleared, :blocking, :terminal_unsatisfied, :unknown, :cyclic]
  @readiness_states [:ready, :blocking, :terminal_unsatisfied, :unknown, :cyclic]
  @max_relationships TicketContextAdapter.max_relationships()
  @max_diagnostics 100

  attr(:id, :string, required: true)
  attr(:context, :map, required: true)
  attr(:selection, :map, required: true)

  @spec build_order_ticket_context(map()) :: Phoenix.LiveView.Rendered.t()
  def build_order_ticket_context(assigns) do
    events = TicketContextSelection.event_names()
    selection = selection_view(assigns.selection)
    context = context_view(assigns.context)

    assigns =
      assigns
      |> assign(:events, events)
      |> assign(:selection, selection)
      |> assign(:context, context)
      |> assign(:selected_diagnostics, selected_diagnostics(context))

    ~H"""
    <TicketContext.ticket_context
      id={@id}
      context={@context.base}
      close_event={@events.close}
      focus_key={@selection.focus_key}
      origin_id={@selection.origin_id}
    >
      <:extension>
        <section class="build-order-ticket-context" aria-label="Build Order relationships">
          <nav :if={@selection.back?} class="build-order-context-history" aria-label="Ticket relationship history">
            <button type="button" class="tool-btn" phx-click={@events.back} data-ticket-context-focus="relationship-back">Back</button>
          </nav>

          <div class="build-order-context-grid">
            <.relationship_section
              id={"#{@id}-blocked-by"}
              heading="Blocked by"
              empty="No upstream blockers are available."
              direction={:blocked_by}
              rows={@context.blocked_by}
              metadata={@context.blocked_by_metadata}
              replace_event={@events.replace}
            />
            <.relationship_section
              id={"#{@id}-blocking"}
              heading="Blocking"
              empty="No downstream tickets are available."
              direction={:blocking}
              rows={@context.blocking}
              metadata={@context.blocking_metadata}
              replace_event={@events.replace}
            />
          </div>

          <section
            :if={@selected_diagnostics != []}
            class="build-order-context-diagnostics"
            aria-labelledby={"#{@id}-metadata-warnings"}
          >
            <h3 id={"#{@id}-metadata-warnings"}>Metadata warnings</h3>
            <ul>
              <li :for={diagnostic <- @selected_diagnostics}>{diagnostic.text}</li>
            </ul>
          </section>
        </section>
      </:extension>
    </TicketContext.ticket_context>
    """
  end

  attr(:id, :string, required: true)
  attr(:heading, :string, required: true)
  attr(:empty, :string, required: true)
  attr(:direction, :atom, required: true)
  attr(:rows, :list, required: true)
  attr(:metadata, :map, required: true)
  attr(:replace_event, :string, required: true)

  defp relationship_section(assigns) do
    ~H"""
    <section class="build-order-context-section" aria-labelledby={@id}>
      <h3 id={@id}>{@heading}</h3>
      <p :if={@rows == []} class="empty-state compact">{@empty}</p>
      <p :if={@metadata.truncated?} class="ticket-context-status" role="status">
        {@heading}: showing {@metadata.shown} of {@metadata.total} relationships. Additional relationships are not shown.
      </p>
      <ul :if={@rows != []} class="build-order-context-relationships">
        <li :for={row <- @rows} data-edge-state={row.edge.state}>
          <article>
            <header>
              <button
                :if={row.selectable?}
                type="button"
                class="build-order-context-link"
                phx-click={@replace_event}
                phx-value-member={row.navigation_value}
                data-ticket-context-focus={relationship_focus_key(row)}
              >
                {row.label}
              </button>
              <a
                :if={!row.selectable? and is_binary(row.outbound_url)}
                class="build-order-context-link"
                href={row.outbound_url}
                target="_blank"
                rel="noopener noreferrer"
                data-ticket-context-focus={relationship_focus_key(row)}
              >
                {row.label}<span aria-hidden="true"> ↗</span>
              </a>
              <strong :if={!row.selectable? and !is_binary(row.outbound_url)}>{row.label}</strong>
              <span class="chip">{state_label(row.edge.state)}</span>
            </header>
            <dl>
              <div><dt>Direction</dt><dd>{direction_label(@direction)}</dd></div>
              <div><dt>Edge state</dt><dd>{state_label(row.edge.state)}</dd></div>
              <div><dt>Affected readiness</dt><dd>{state_label(row.readiness)}</dd></div>
            </dl>
            <ul :if={row.edge.diagnostics != []} class="build-order-context-row-diagnostics">
              <li :for={diagnostic <- row.edge.diagnostics}>{diagnostic.text}</li>
            </ul>
          </article>
        </li>
      </ul>
    </section>
    """
  end

  defp context_view(%View{status: :available} = view) do
    blocked_by = safe_rows(view.blocked_by, :blocked_by)
    blocking = safe_rows(view.blocking, :blocking)

    %{
      view
      | blocked_by: blocked_by,
        blocked_by_metadata: safe_relationship_metadata(view.blocked_by_metadata, blocked_by),
        blocking: blocking,
        blocking_metadata: safe_relationship_metadata(view.blocking_metadata, blocking)
    }
  end

  defp context_view(%View{} = view) do
    %{
      view
      | blocked_by: [],
        blocked_by_metadata: empty_relationship_metadata(),
        blocking: [],
        blocking_metadata: empty_relationship_metadata()
    }
  end

  defp safe_rows(rows, direction) do
    rows
    |> List.wrap()
    |> Stream.flat_map(&safe_row(&1, direction))
    |> Enum.take(@max_relationships)
  end

  defp safe_row(
         %Relationship{
           direction: direction,
           edge: %Edge{kind: kind, state: state} = edge,
           label: label,
           readiness: readiness
         } = row,
         direction
       )
       when kind in [:native, :external, :unknown] and state in @edge_states and readiness in @readiness_states do
    with {:ok, label} <- Bounded.title(label),
         {:ok, _id} <- Bounded.text(edge.id, 512) do
      navigation_value = if(row.selectable? and kind == :native, do: OpaqueIdentifier.normalize(row.navigation_value))
      selectable? = is_binary(navigation_value)

      [
        %{
          row
          | edge: %{edge | diagnostics: safe_diagnostics(edge.diagnostics)},
            label: label,
            selectable?: selectable?,
            navigation_value: if(selectable?, do: navigation_value),
            outbound_url: if(selectable?, do: nil, else: safe_outbound_url(row))
        }
      ]
    else
      _invalid -> []
    end
  end

  defp safe_row(_row, _direction), do: []

  defp safe_relationship_metadata(%{total: total}, rows)
       when is_integer(total) and total >= 0 do
    shown = length(rows)
    total = max(total, shown)
    %{total: total, shown: shown, truncated?: total > shown}
  end

  defp safe_relationship_metadata(_metadata, rows) do
    shown = length(rows)
    %{total: shown, shown: shown, truncated?: false}
  end

  defp empty_relationship_metadata, do: %{total: 0, shown: 0, truncated?: false}

  defp safe_outbound_url(%Relationship{
         edge: %Edge{kind: :external},
         endpoint: %TrackerIdentity{} = endpoint,
         outbound_url: outbound_url
       }) do
    case Bounded.github_issue_url_for(outbound_url, endpoint) do
      {:ok, safe} -> safe
      :error -> nil
    end
  end

  defp safe_outbound_url(_row), do: nil

  defp selection_view(%TicketContextSelection{} = selection) do
    %{
      focus_key: focus_key(selection.focus_revision),
      origin_id: OpaqueIdentifier.normalize(selection.origin_id),
      back?: selection.status == :open and is_list(selection.history) and selection.history != []
    }
  end

  defp selection_view(_selection), do: %{focus_key: nil, origin_id: nil, back?: false}

  defp focus_key(revision) when is_integer(revision) and revision >= 0,
    do: OpaqueIdentifier.normalize("navigation-#{revision}")

  defp focus_key(_revision), do: nil

  defp selected_diagnostics(%View{selected: %{diagnostics: diagnostics}}) do
    safe_diagnostics(diagnostics)
  end

  defp selected_diagnostics(_context), do: []

  defp safe_diagnostics(diagnostics) do
    diagnostics
    |> List.wrap()
    |> Stream.flat_map(fn
      %Diagnostic{code: code} when is_atom(code) -> [Diagnostic.new(code)]
      _diagnostic -> []
    end)
    |> Enum.take(@max_diagnostics)
  end

  defp direction_label(:blocked_by), do: "Upstream blocker → selected ticket"
  defp direction_label(:blocking), do: "Selected ticket → downstream ticket"
  defp relationship_focus_key(row), do: "relationship-#{row.edge.id}"
  defp state_label(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
