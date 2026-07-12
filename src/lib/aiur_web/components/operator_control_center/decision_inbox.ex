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
  attr(:selected_decision_id, :string, default: nil)
  attr(:filter, :atom, default: :all)
  attr(:now, :any, required: true)
  attr(:history, :list, default: [])
  attr(:action_states, :map, default: %{})
  attr(:writable, :boolean, required: true)
  attr(:provider_health, :any, default: :ok)

  @spec decision_inbox(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_inbox(assigns) do
    decisions = filtered(assigns.decisions, assigns.filter)

    assigns =
      assigns
      |> assign(:visible_decisions, decisions)
      |> assign(:counts, filter_counts(assigns.decisions))
      |> assign(:filter_specs, @filter_specs)

    ~H"""
    <section class="section-card decision-inbox" aria-labelledby="decision-inbox-title">
      <header class="section-header">
        <div>
          <p class="section-eyebrow">Human-in-the-loop</p>
          <h2 id="decision-inbox-title">Decision inbox</h2>
          <p>Durable decisions sorted blocking-first, then urgency and age. Open a card for its full recorded context and lifecycle.</p>
        </div>
      </header>

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
        />
      </div>
    </section>
    """
  end

  attr(:filter, :string, required: true)
  attr(:label, :string, required: true)
  attr(:count, :integer, required: true)
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
      {@label} <span class="count num">{@count}</span>
    </button>
    """
  end

  defp filter_counts(decisions) do
    %{
      all: length(decisions),
      open: Enum.count(decisions, &open?/1),
      blocking: Enum.count(decisions, &blocking?/1),
      undelivered: Enum.count(decisions, &undelivered?/1),
      supervisor: Enum.count(decisions, &supervisor_decision?/1),
      resolved: Enum.count(decisions, &(&1.decision_status == :resolved)),
      superseded: Enum.count(decisions, &Map.get(&1, :superseded?, false))
    }
  end

  defp filtered(decisions, :open), do: Enum.filter(decisions, &open?/1)
  defp filtered(decisions, :blocking), do: Enum.filter(decisions, &blocking?/1)
  defp filtered(decisions, :undelivered), do: Enum.filter(decisions, &undelivered?/1)
  defp filtered(decisions, :supervisor), do: Enum.filter(decisions, &supervisor_decision?/1)
  defp filtered(decisions, :resolved), do: Enum.filter(decisions, &(&1.decision_status == :resolved))
  defp filtered(decisions, :superseded), do: Enum.filter(decisions, &Map.get(&1, :superseded?, false))
  defp filtered(decisions, _filter), do: decisions

  defp open?(decision), do: decision.decision_status == :open
  defp blocking?(decision), do: decision.blocking and open?(decision)

  defp undelivered?(decision) do
    not is_nil(decision.answer) and decision.delivery_status not in [:delivered, :consumed]
  end

  defp supervisor_decision?(decision) do
    get_in(decision, [:answer, :actor, :kind]) == :supervisor
  end
end
