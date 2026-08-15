defmodule AiurWeb.OperatorControlCenter.History do
  @moduledoc """
  Command history: one paginated table of Commands the operator has finished
  with.

  Every row is a retained Command read back from the store, so a row appears
  here only once the store says the Command actually left the queue — never
  because a click optimistically hid a card.

  A row is an accordion: clicking anywhere on it patches to the Command's own
  URL and expands the full retained context in place, directly beneath the row
  it belongs to. The rows are therefore a plain ordered list rather than a
  LiveView stream — a stream only re-renders an item when it is re-inserted, so
  an expansion driven by an assign outside the stream could not reach the row,
  and a stream item may only have one root element, which an inline detail row
  is not.
  """

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.{DecisionDetail, DecisionPath}
  alias Phoenix.LiveView.JS

  @page_size 10

  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  attr(:rows, :list, required: true)
  attr(:loaded, :integer, default: 0)
  attr(:total, :any, default: nil)
  attr(:has_more, :boolean, default: false)
  attr(:loading, :boolean, default: false)
  attr(:provider_health, :any, default: :ok)
  attr(:expanded_id, :string, default: nil)
  attr(:expanded_decision, :any, default: nil)
  attr(:history, :list, default: [])
  attr(:action_state, :map, default: %{})
  attr(:writable, :boolean, default: false)
  attr(:filter, :atom, default: :all)
  attr(:query, :map, default: %{})

  @spec history(map()) :: Phoenix.LiveView.Rendered.t()
  def history(assigns) do
    ~H"""
    <section class="section-card command-history" aria-labelledby="decision-history-title">
      <div class="recent-subtitle-row">
        <p class="recent-subtitle" id="decision-history-title">Command history</p>
        <span class="history-count mono">{count_label(@loaded, @total)}</span>
      </div>
      <div :if={@provider_health == :unavailable} class="empty-state compact">History provider is currently unavailable.</div>
      <div :if={@provider_health == :degraded} class="empty-state compact">
        Command history is degraded; showing the last validated prefix.
      </div>
      <div :if={@provider_health == :ok and @loaded == 0} class="empty-state compact">No Command actions have been recorded.</div>

      <div :if={@loaded > 0} class="history-table-wrap">
        <table class="history-table" aria-label="Command history">
          <thead>
            <tr>
              <th scope="col">Command</th>
              <th scope="col">Decision</th>
              <th scope="col">Result</th>
              <th scope="col">Raised</th>
            </tr>
          </thead>
          <tbody id="command-history-rows">
            <.history_row
              :for={decision <- @rows}
              id={"history-#{decision.decision_id}"}
              decision={row_decision(decision, decision.decision_id == @expanded_id, @expanded_decision)}
              expanded={decision.decision_id == @expanded_id}
              history={@history}
              action_state={@action_state}
              writable={@writable}
              filter={@filter}
              query={@query}
            />
          </tbody>
        </table>
      </div>

      <div :if={@has_more} class="history-more">
        <button
          type="button"
          class="btn ghost"
          phx-click="load-more-history"
          phx-disable-with="Loading…"
        >Load more</button>
      </div>
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:decision, :map, required: true)
  attr(:expanded, :boolean, required: true)
  attr(:history, :list, required: true)
  attr(:action_state, :map, required: true)
  attr(:writable, :boolean, required: true)
  attr(:filter, :atom, required: true)
  attr(:query, :map, required: true)

  defp history_row(assigns) do
    assigns =
      assigns
      |> assign(:detail_id, "history-detail-#{assigns.id}")
      |> assign(:toggle_id, "history-toggle-#{assigns.id}")
      |> assign(:toggle, toggle(assigns))

    ~H"""
    <tr
      id={@id}
      class={["history-row", @expanded && "is-expanded"]}
      data-severity={severity(@decision)}
      phx-click={@toggle}
    >
      <td class="history-command">
        <%!-- The whole row is clickable, but the accordion control is a real
              button: it is what carries the accessible name and aria-expanded,
              and it is what Enter and Space activate. The row click is a mouse
              affordance layered on top — a button click bubbles to the row's
              phx-click, so both paths run exactly one patch.

              aria-controls is emitted only while the panel exists: a collapsed
              row renders no detail row, and the attribute must not name an
              element that is not there. --%>
        <button
          type="button"
          id={@toggle_id}
          class="history-row-toggle"
          aria-expanded={to_string(@expanded)}
          aria-controls={@expanded && @detail_id}
        >
          <span class="ticket-id">{ticket_identifier(@decision.ticket) || @decision.decision_id}</span>
          <span class="history-question">{@decision.question}</span>
        </button>
      </td>
      <td class="history-decision">{decision_choice(@decision) || "—"}</td>
      <td>
        <div class="history-result">
          <span class={["chip", tone(@decision)]}>{decision_status(@decision)}</span>
          <span :if={answer_actor_label(@decision)} class={answer_actor_class(@decision)}>{answer_actor_label(@decision)}</span>
        </div>
      </td>
      <td class="history-when mono">
        {raised_at(@decision.created_at)}
        <span class="expand-chevron" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
            <path d="m6 9 6 6 6-6" />
          </svg>
        </span>
      </td>
    </tr>
    <tr :if={@expanded} id={@detail_id} class="history-detail-row">
      <td colspan="4">
        <%!-- The panel needs its own heading: a table row carries no heading
              level, so without this the detail's own h4 blocks would skip one,
              and a screen reader would meet the panel with nothing naming the
              Command it belongs to. --%>
        <h3 class="sr-only">{@decision.question}</h3>
        <div phx-mounted={JS.focus(to: "#decision-detail-#{@decision.decision_id}")}>
          <DecisionDetail.decision_detail
            decision={@decision}
            history={@history}
            action_state={@action_state}
            writable={@writable}
            filter={@filter}
            query={@query}
          />
        </div>
      </td>
    </tr>
    """
  end

  # Collapsing takes the panel — and whatever inside it had focus — out of the
  # DOM, so the focus has to be put back deliberately. Without this a keyboard
  # or screen-reader user is dropped to <body> and has to tab in from the top
  # of the page again.
  defp toggle(%{expanded: true, id: id, filter: filter, query: query}) do
    filter |> DecisionPath.inbox(query) |> JS.patch() |> JS.focus(to: "#history-toggle-#{id}")
  end

  defp toggle(%{decision: decision, filter: filter, query: query}) do
    decision.decision_id |> DecisionPath.detail(filter, query) |> JS.patch()
  end

  # The open row renders the freshly re-read record rather than the copy the
  # history page returned: a Command can be revised while it is open, and the row
  # must not keep asserting the question it was answered under.
  #
  # This is resolved here, in the caller, rather than inside the row: assigning
  # over the row's own :decision hid the dependency on the re-read record from
  # change tracking. Once a payload reload had refreshed the history row to the
  # same record, the assign was a no-op, the open panel was never re-sent, and it
  # kept rendering the delivery state it was opened with — a retried delivery
  # left a dead "Retry delivery" button on screen until the operator clicked
  # something else.
  defp row_decision(_decision, true, %{} = expanded), do: expanded
  defp row_decision(decision, _expanded?, _expanded_decision), do: decision

  # A count is only shown when the store reported an exact total. "23 of 91"
  # with an unknown total would be a fabricated denominator.
  defp count_label(loaded, total) when is_integer(total), do: "#{loaded} of #{total}"
  defp count_label(loaded, _total), do: "#{loaded} loaded"

  # Answered, acknowledged and resolved are done and read green. Expired and
  # deferred are not the same outcome and must not read as one: expired means
  # nobody answered, deferred means the Executor still owes an answer.
  defp decision_status(%{decision_status: :expired}), do: "Expired"
  defp decision_status(%{decision_status: :decided}), do: "Answered"
  defp decision_status(%{decision_status: :acknowledged}), do: "Acknowledged"
  defp decision_status(%{decision_status: :resolved}), do: "Resolved"
  defp decision_status(%{decision_status: :dismissed}), do: "Closed"
  defp decision_status(%{decision_status: :deferred}), do: "Deferred to Executor"
  defp decision_status(_decision), do: "Recorded"

  defp tone(%{decision_status: :expired}), do: "attention"
  defp tone(%{decision_status: :deferred}), do: "super"
  defp tone(_decision), do: "good"

  defp severity(%{decision_status: :expired}), do: "attn"
  defp severity(%{decision_status: :deferred}), do: "attention"
  defp severity(_decision), do: "good"

  # The Decision column answers one question: what was decided? An expired
  # Command was never decided by anyone, so it has no decision to report — "N/A"
  # rather than a sentence that reads like an outcome. Where somebody did
  # answer, the column quotes what they actually said; a paraphrase would be
  # this component inventing an answer the store never recorded.
  defp decision_choice(%{decision_status: :expired}), do: "N/A"
  defp decision_choice(%{decision_status: :deferred}), do: "Handed to the Executor"
  defp decision_choice(%{decision_status: :dismissed, answer: nil}), do: "Closed without a recorded answer"

  defp decision_choice(%{answer: %{custom_response: response}}) when is_binary(response) do
    # Blank is not an answer. Quoting it would print an empty pair of quotes,
    # which reads as "they said nothing" rather than "nothing was recorded".
    if String.trim(response) == "", do: nil, else: quoted(response)
  end

  defp decision_choice(%{answer: %{selected_option_id: option_id}, options: options}) when is_binary(option_id) do
    case Enum.find(options, &(&1.id == option_id)) do
      nil -> quoted("Option #{option_id}")
      option -> quoted(option.label)
    end
  end

  defp decision_choice(_decision), do: nil

  defp quoted(text), do: "“#{text}”"

  # Who answered is part of the outcome, not decoration: an Executor answer and
  # an operator answer are different facts about the same green row.
  defp answer_actor_label(%{answer: answer}) when is_map(answer) do
    case map_value(Map.get(answer, :actor), :kind) do
      kind when kind in [:operator, "operator"] -> "Operator answer"
      kind when kind in [:executor, "executor"] -> "Executor answer"
      kind when kind in [:supervisor, "supervisor"] -> "Supervisor answer"
      _kind -> nil
    end
  end

  defp answer_actor_label(_decision), do: nil

  defp answer_actor_class(%{answer: answer}) do
    case map_value(Map.get(answer, :actor), :kind) do
      kind when kind in [:operator, "operator"] -> "chip accent"
      kind when kind in [:executor, "executor"] -> "chip good"
      _kind -> "chip super"
    end
  end

  defp map_value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp map_value(_map, _key), do: nil

  defp ticket_identifier(%{identifier: identifier}), do: identifier
  defp ticket_identifier(identifier) when is_binary(identifier), do: identifier
  defp ticket_identifier(_ticket), do: nil

  # Absolute, not relative: a history row is rendered once and then left alone,
  # so a rendered "2h ago" would keep ageing on screen without ever being
  # re-rendered. A timestamp cannot go stale.
  defp raised_at(%DateTime{} = created_at) do
    created_at |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end

  defp raised_at(_created_at), do: "unknown"
end
