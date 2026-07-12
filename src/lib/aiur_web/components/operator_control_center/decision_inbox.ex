defmodule AiurWeb.OperatorControlCenter.DecisionInbox do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.DecisionCard

  attr(:decisions, :list, required: true)
  attr(:selected_decision_id, :string, default: nil)
  attr(:filter, :atom, default: :all)
  attr(:now, :any, required: true)
  attr(:history, :list, default: [])
  attr(:writable, :boolean, required: true)
  attr(:provider_health, :any, default: :ok)

  def decision_inbox(assigns) do
    decisions = filtered(assigns.decisions, assigns.filter)

    assigns =
      assigns
      |> assign(:visible_decisions, decisions)
      |> assign(:counts, filter_counts(assigns.decisions))

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
        <.filter_button filter="all" label="All" count={@counts.all} active={@filter == :all} />
        <.filter_button filter="open" label="Open" count={@counts.open} active={@filter == :open} />
        <.filter_button filter="blocking" label="Blocking" count={@counts.blocking} active={@filter == :blocking} blocking />
        <.filter_button filter="answered" label="Answered" count={@counts.answered} active={@filter == :answered} />
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
      open: Enum.count(decisions, &(&1.lifecycle == :recorded)),
      blocking: Enum.count(decisions, &(&1.blocking and &1.lifecycle == :recorded)),
      answered: Enum.count(decisions, &(&1.lifecycle != :recorded))
    }
  end

  defp filtered(decisions, :open), do: Enum.filter(decisions, &(&1.lifecycle == :recorded))
  defp filtered(decisions, :blocking), do: Enum.filter(decisions, &(&1.blocking and &1.lifecycle == :recorded))
  defp filtered(decisions, :answered), do: Enum.reject(decisions, &(&1.lifecycle == :recorded))
  defp filtered(decisions, _filter), do: decisions
end
