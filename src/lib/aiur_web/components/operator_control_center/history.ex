defmodule AiurWeb.OperatorControlCenter.History do
  @moduledoc """
  Command history: one paginated table of Commands the operator has finished
  with.

  The rows are a LiveView stream, so "Load more" appends the next page without
  re-fetching or re-rendering the pages already on screen. Every row is a
  retained Command read back from the store, so a row appears here only once the
  store says the Command actually left the queue — never because a click
  optimistically hid a card.
  """

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.DecisionPath

  @page_size 10

  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  attr(:rows, :any, required: true)
  attr(:loaded, :integer, default: 0)
  attr(:total, :any, default: nil)
  attr(:has_more, :boolean, default: false)
  attr(:loading, :boolean, default: false)
  attr(:provider_health, :any, default: :ok)

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
              <th scope="col">Outcome</th>
              <th scope="col">Result</th>
              <th scope="col">Raised</th>
              <th scope="col"><span class="sr-only">Open</span></th>
            </tr>
          </thead>
          <tbody id="command-history-rows" phx-update="stream">
            <tr :for={{dom_id, decision} <- @rows} id={dom_id} data-severity={severity(decision)}>
              <td>
                <span class="ticket-id">{ticket_identifier(decision.ticket) || decision.decision_id}</span>
                <span class="history-question">{decision.question}</span>
              </td>
              <td class="history-outcome">{decision_choice(decision) || "—"}</td>
              <td>
                <div class="history-result">
                  <span class={["chip", tone(decision)]}>{decision_status(decision)}</span>
                  <span :if={answer_actor_label(decision)} class={answer_actor_class(decision)}>{answer_actor_label(decision)}</span>
                </div>
              </td>
              <td class="history-when mono">{raised_at(decision.created_at)}</td>
              <td class="history-open">
                <.link patch={DecisionPath.detail(decision.decision_id, :all)} class="link-pill">Open</.link>
              </td>
            </tr>
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

  defp decision_choice(%{decision_status: :expired}), do: "Expired — agent is no longer running"
  defp decision_choice(%{decision_status: :deferred}), do: "Handed to the Executor"
  defp decision_choice(%{decision_status: :dismissed, answer: nil}), do: "Closed without a recorded answer"
  defp decision_choice(%{answer: %{custom_response: response}}) when is_binary(response), do: response

  defp decision_choice(%{answer: %{selected_option_id: option_id}, options: options}) when is_binary(option_id) do
    case Enum.find(options, &(&1.id == option_id)) do
      nil -> "Option #{option_id}"
      option -> option.label
    end
  end

  defp decision_choice(_decision), do: nil

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

  # Absolute, not relative: a history row is streamed in once and then left
  # alone, so a rendered "2h ago" would keep ageing on screen without ever being
  # re-rendered. A timestamp cannot go stale.
  defp raised_at(%DateTime{} = created_at) do
    created_at |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end

  defp raised_at(_created_at), do: "unknown"
end
