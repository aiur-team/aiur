defmodule AiurWeb.OperatorControlCenter.DecisionInbox do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.DecisionCard

  @filter_specs [
    {:all, "All"},
    {:open, "Open"},
    {:blocking, "Blocking"},
    {:undelivered, "Undelivered"},
    {:supervisor, "Supervisor"},
    {:resolved, "Resolved"},
    {:superseded, "Superseded"}
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

  @spec decision_inbox(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_inbox(assigns) do
    decisions = visible_decisions(assigns.decisions, assigns.selected_decision, assigns.selected_decision_id, assigns.filter)

    assigns =
      assigns
      |> assign(:visible_decisions, decisions)
      |> assign(:counts, filter_counts(assigns.decisions, assigns.retained_counts))
      |> assign(:filter_specs, @filter_specs)

    ~H"""
    <section class="section-card decision-inbox" aria-labelledby="decision-inbox-title">
      <h2 id="decision-inbox-title" class="sr-only">Decision inbox</h2>

      <div class="filter-row" aria-label="Decision filters">
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
        <div :if={@provider_health != :ok} class="empty-state">Decision projection is currently unavailable. Fleet state remains live.</div>
        <div :if={@provider_health == :ok and @visible_decisions == []} class="empty-state">No decisions match this filter.</div>
        <DecisionCard.decision_card
          :for={decision <- @visible_decisions}
          decision={decision}
          selected={decision.decision_id == @selected_decision_id}
          now={@now}
          history={@history}
          action_state={Map.get(@action_states, decision.decision_id, %{})}
          writable={@writable}
          filter={@filter}
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

  defp filter_counts(decisions, retained_counts) do
    %{
      all: Map.get(retained_counts, :total),
      open: Map.get(retained_counts, :open),
      blocking: Map.get(retained_counts, :blocking),
      undelivered: Enum.count(decisions, &undelivered?/1),
      supervisor: Enum.count(decisions, &supervisor_decision?/1),
      resolved: Enum.count(decisions, &(&1.decision_status == :resolved)),
      superseded: Enum.count(decisions, &Map.get(&1, :superseded?, false))
    }
  end

  defp count_label(count) when is_integer(count), do: count
  defp count_label(_count), do: "—"

  defp filtered(decisions, :open), do: Enum.filter(decisions, &open?/1)
  defp filtered(decisions, :blocking), do: Enum.filter(decisions, &blocking?/1)
  defp filtered(decisions, :undelivered), do: Enum.filter(decisions, &undelivered?/1)
  defp filtered(decisions, :supervisor), do: Enum.filter(decisions, &supervisor_decision?/1)
  defp filtered(decisions, :resolved), do: Enum.filter(decisions, &(&1.decision_status == :resolved))
  defp filtered(decisions, :superseded), do: Enum.filter(decisions, &Map.get(&1, :superseded?, false))
  defp filtered(decisions, _filter), do: decisions

  defp visible_decisions(decisions, selected, selected_id, filter) do
    filtered =
      decisions
      |> Enum.reject(&(&1.decision_id == selected_id))
      |> filtered(filter)

    if is_nil(selected), do: filtered, else: [selected | filtered]
  end

  defp open?(decision), do: decision.decision_status == :open
  defp blocking?(decision), do: decision.blocking and open?(decision)

  defp undelivered?(decision) do
    not is_nil(decision.answer) and decision.delivery_status not in [:delivered, :consumed]
  end

  defp supervisor_decision?(decision) do
    get_in(decision, [:answer, :actor, :kind]) == :supervisor
  end
end
