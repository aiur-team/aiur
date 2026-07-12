defmodule AiurWeb.OperatorControlCenter.DecisionCard do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.{DecisionDetail, DecisionPath, LifecycleComponents}
  alias Phoenix.LiveView.JS

  attr(:decision, :map, required: true)
  attr(:selected, :boolean, default: false)
  attr(:now, :any, required: true)
  attr(:history, :list, default: [])
  attr(:action_state, :map, default: %{})
  attr(:writable, :boolean, required: true)
  attr(:filter, :atom, default: :all)

  @spec decision_card(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_card(assigns) do
    assigns =
      assigns
      |> assign(:age, age(assigns.decision.created_at, assigns.now))
      |> assign(:collapsed_path, DecisionPath.inbox(assigns.filter))
      |> assign(:detail_path, DecisionPath.detail(assigns.decision.decision_id, assigns.filter))
      |> assign(:source_label, source_label(assigns.decision))
      |> assign(:recommendation_label, recommendation_label(assigns.decision))

    ~H"""
    <article
      id={"decision-#{@decision.decision_id}"}
      class={["decision-card", @decision.blocking && "blocking", @selected && "open"]}
      data-severity={severity(@decision)}
      aria-current={@selected && "true"}
    >
      <span class="severity-rail"></span>
      <.link
        patch={if @selected, do: @collapsed_path, else: @detail_path}
        class="decision-card-head"
        aria-expanded={to_string(@selected)}
      >
        <div>
          <div class="decision-meta-row">
            <span class="ticket-id">{@decision.ticket[:identifier] || @decision.decision_id}</span>
            <span class="decision-ticket-title">{@decision.ticket[:title]}</span>
          </div>
          <h3>{@decision.question}</h3>
          <p :if={present?(@decision.context.short)} class="decision-context">{@decision.context.short}</p>
          <div class="decision-card-foot">
            <span class={["chip", @decision.blocking && "blocking"]}><span class="chip-dot"></span>{if @decision.blocking, do: "Blocking", else: "Non-blocking"}</span>
            <span class="chip age">◷ {@age}</span>
            <span class="actor-tag"><span class="actor-glyph ticket">TA</span>{@source_label}</span>
            <span class="chip">{option_count_label(@decision.options)}</span>
            <span :if={@recommendation_label} class="recommendation-chip">SA recommends <b>{@recommendation_label}</b></span>
          </div>
        </div>
        <div class="decision-card-side">
          <LifecycleComponents.lifecycle_chip lifecycle={@decision.lifecycle} />
          <span class="expand-hint">{if @selected, do: "Collapse", else: "Details"} <span aria-hidden="true">⌄</span></span>
        </div>
      </.link>

      <div phx-mounted={@selected && JS.focus(to: "#decision-detail-#{@decision.decision_id}")}>
        <DecisionDetail.decision_detail
          :if={@selected}
          decision={@decision}
          history={@history}
          action_state={@action_state}
          writable={@writable}
          filter={@filter}
        />
      </div>
    </article>
    """
  end

  defp severity(%{lifecycle: :delivery_failed}), do: "block"
  defp severity(%{blocking: true}), do: "block"
  defp severity(%{lifecycle: :resolved}), do: "good"
  defp severity(_decision), do: "attention"

  defp option_count_label([]), do: "Free-form response"
  defp option_count_label(options), do: "#{length(options)} options"

  defp source_label(decision), do: decision.source[:agent_id] || "Ticket agent"

  defp recommendation_label(%{recommendation: nil}), do: nil

  defp recommendation_label(decision) do
    option_id = decision.recommendation.option_id

    case Enum.find(decision.options, &(&1.id == option_id)) do
      nil -> "Option #{option_id}"
      option -> option.label
    end
  end

  defp age(%DateTime{} = created_at, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, created_at, :second), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp age(_created_at, _now), do: "unknown age"
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
