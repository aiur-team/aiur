defmodule AiurWeb.OperatorControlCenter.DecisionInbox do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.DecisionCard

  @filter_specs [
    {:open, "Open"},
    {:blocking, "Blocking"},
    {:resolved, "Resolved"},
    {:all, "All"}
  ]

  attr(:decisions, :list, required: true)
  attr(:selected_decision, :map, default: nil)
  attr(:selected_decision_id, :string, default: nil)
  attr(:filter, :atom, default: :all)
  attr(:now, :any, required: true)
  attr(:history, :list, default: [])
  attr(:action_states, :map, default: %{})
  attr(:writable, :boolean, required: true)
  attr(:provider_health, :any, default: :ok)
  attr(:retained_counts, :map, required: true)
  attr(:page, :map, default: %{})
  attr(:query, :map, default: %{})

  @spec decision_inbox(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_inbox(assigns) do
    decisions = visible_decisions(assigns.decisions, assigns.selected_decision, assigns.selected_decision_id, assigns.filter)

    assigns =
      assigns
      |> assign(:visible_decisions, decisions)
      |> assign(:counts, filter_counts(assigns.retained_counts, assigns.page, assigns.filter))
      |> assign(:filter_specs, @filter_specs)
      |> assign(:page_health, get_in(assigns.page, [:health, :status]))

    ~H"""
    <section class="section-card decision-inbox" aria-labelledby="decision-inbox-title">
      <h2 id="decision-inbox-title" class="sr-only">Commands inbox</h2>

      <div class="filter-row" aria-label="Command filters">
        <.filter_button
          :for={{filter, label} <- @filter_specs}
          filter={Atom.to_string(filter)}
          label={label}
          count={Map.fetch!(@counts, filter)}
          active={@filter == filter}
          blocking={filter == :blocking}
        />
      </div>

      <div class="decision-list">
        <div :if={@provider_health != :ok or @page_health == :unavailable} class="empty-state">
          Command projection is currently unavailable. Unit state remains live.
        </div>
        <div :if={@page_health == :partial} class="empty-state compact" role="status">
          Retained Commands are partial; showing the most recent verified entries.
        </div>
        <div :if={@provider_health == :ok and @page_health != :unavailable and @visible_decisions == []} class="empty-state">
          {empty_message(@filter)}
        </div>
        <DecisionCard.decision_card
          :for={decision <- @visible_decisions}
          decision={decision}
          selected={decision.decision_id == @selected_decision_id}
          now={@now}
          history={@history}
          action_state={Map.get(@action_states, decision.decision_id, %{})}
          writable={@writable}
          filter={@filter}
          query={@query}
        />
      </div>

    </section>
    """
  end

  attr(:filter, :string, required: true)
  attr(:label, :string, required: true)
  attr(:count, :any, required: true)
  attr(:active, :boolean, required: true)
  attr(:blocking, :boolean, default: false)

  defp filter_button(assigns) do
    ~H"""
    <button
      type="button"
      class={["filter-chip", @active && "is-active", @blocking && "blocking"]}
      phx-click="filter-decisions"
      phx-value-filter={@filter}
      aria-pressed={to_string(@active)}
    >
      {@label} <span class="count num">{count_label(@count)}</span>
    </button>
    """
  end

  defp filter_counts(retained_counts, page, filter) do
    resolved = if filter == :resolved, do: get_in(page, [:pagination, :total])

    %{
      all: Map.get(retained_counts, :open),
      open: Map.get(retained_counts, :open),
      blocking: Map.get(retained_counts, :blocking),
      resolved: resolved
    }
  end

  defp count_label(count) when is_integer(count), do: count
  defp count_label(_count), do: "—"

  defp filtered(decisions, :open), do: Enum.filter(decisions, &open?/1)
  defp filtered(decisions, :blocking), do: Enum.filter(decisions, &blocking?/1)
  defp filtered(decisions, :undelivered), do: Enum.filter(decisions, &undelivered?/1)
  defp filtered(decisions, :supervisor), do: Enum.filter(decisions, &supervisor_decision?/1)

  # The inbox is actionable work, while answered and dismissed Commands belong
  # exclusively to the compact audit feed below. Keeping historic Commands out
  # of both All and Resolved prevents the same action from reading as an open
  # card and as a history row at the same time.
  defp filtered(_decisions, :resolved), do: []

  defp filtered(decisions, :superseded), do: Enum.filter(decisions, &Map.get(&1, :superseded?, false))
  defp filtered(decisions, _filter), do: Enum.filter(decisions, &open?/1)

  defp empty_message(:resolved), do: "Resolved Commands are shown in Command history below."
  defp empty_message(_filter), do: "No Commands match this filter."

  defp visible_decisions(decisions, selected, selected_id, filter) do
    filtered =
      decisions
      |> Enum.reject(&(&1.decision_id == selected_id))
      |> filtered(filter)

    if is_nil(selected), do: filtered, else: [selected | filtered]
  end

  defp open?(decision), do: decision.decision_status in [:open, :deferred]
  defp blocking?(decision), do: decision.blocking and open?(decision)

  defp undelivered?(decision) do
    not is_nil(decision.answer) and decision.delivery_status not in [:delivered, :consumed]
  end

  defp supervisor_decision?(decision) do
    get_in(decision, [:answer, :actor, :kind]) == :supervisor
  end
end
