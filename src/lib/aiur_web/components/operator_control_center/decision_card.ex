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
  attr(:query, :map, default: %{})

  @spec decision_card(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_card(assigns) do
    assigns =
      assigns
      |> assign(:age, age(assigns.decision.created_at, assigns.now))
      |> assign(:collapsed_path, DecisionPath.inbox(assigns.filter, assigns.query))
      |> assign(:detail_path, DecisionPath.detail(assigns.decision.decision_id, assigns.filter, assigns.query))
      |> assign(:source_label, source_label(assigns.decision))
      |> assign(:recommendation_label, recommendation_label(assigns.decision))
      |> assign(:option_previews, Enum.take(assigns.decision.options, 2))
      |> assign(:selected_answer_label, selected_answer_label(assigns.decision))
      |> assign(:supervisor_answer?, supervisor_answer?(assigns.decision))
      |> assign(:confidence, supervisor_confidence(assigns.decision))
      |> assign(:provenance_label, provenance_label(assigns.decision))

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
          <div :if={@option_previews != []} class="decision-option-preview" aria-label="Command option preview">
            <span
              :for={option <- @option_previews}
              class={["chip", selected_option?(@decision, option) && "accent"]}
            >
              {if selected_option?(@decision, option), do: "Selected · ", else: ""}{option.label}
            </span>
            <span :if={length(@decision.options) > 2} class="chip faint">+{length(@decision.options) - 2} more</span>
          </div>
          <div class="decision-card-foot">
            <span class={["chip", @decision.blocking && "blocking"]}><span class="chip-dot"></span>{if @decision.blocking, do: "Blocking", else: "Non-blocking"}</span>
            <span class="chip age">◷ {@age}</span>
            <span class="actor-tag"><span class="actor-glyph ticket">TA</span>{@source_label}</span>
            <span class="chip">{option_count_label(@decision.options)}</span>
            <span :if={@recommendation_label} class="recommendation-chip">SA recommends <b>{@recommendation_label}</b></span>
            <span :if={@selected_answer_label} class="chip accent">Selected · {@selected_answer_label}</span>
            <span :if={@supervisor_answer?} class="chip super">Supervisor answer</span>
            <span :if={is_integer(@confidence)} class="chip super">{@confidence}% confidence</span>
            <span :if={@provenance_label} class="chip mono">{@provenance_label}</span>
            <span :if={Map.get(@decision, :superseded?, false)} class="chip super">Superseded</span>
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
          query={@query}
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

  defp selected_answer_label(%{answer: nil}), do: nil

  defp selected_answer_label(%{answer: answer, options: options}) do
    case Map.get(answer, :selected_option_id) do
      option_id when is_binary(option_id) ->
        case Enum.find(options, &(&1.id == option_id)) do
          nil -> "Option #{option_id}"
          option -> option.label
        end

      _option_id ->
        if present?(Map.get(answer, :custom_response)), do: "Custom response", else: "Recorded response"
    end
  end

  defp selected_option?(%{answer: answer}, option) when is_map(answer),
    do: Map.get(answer, :selected_option_id) == option.id

  defp selected_option?(_decision, _option), do: false

  defp supervisor_answer?(%{answer: answer}) when is_map(answer) do
    get_in(answer, [:actor, :kind]) in [:supervisor, "supervisor"]
  end

  defp supervisor_answer?(_decision), do: false

  defp supervisor_confidence(%{answer: answer}) when is_map(answer) do
    confidence = answer |> Map.get(:supervisor_basis) |> map_value(:confidence)
    if is_integer(confidence) and confidence in 0..100, do: confidence
  end

  defp supervisor_confidence(_decision), do: nil

  defp provenance_label(decision) do
    provenance = Map.get(decision, :provenance)
    backend = map_value(provenance, :backend) || map_value(provenance, :agent_family)
    model = map_value(provenance, :resolved_model) || map_value(provenance, :requested_model)

    case {backend, model} do
      {backend, model} when is_binary(backend) and is_binary(model) -> "#{backend} · #{model}"
      {backend, _model} when is_binary(backend) -> backend
      {_backend, model} when is_binary(model) -> model
      _unknown -> nil
    end
  end

  defp map_value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp map_value(_map, _key), do: nil

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
