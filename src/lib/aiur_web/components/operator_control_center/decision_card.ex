defmodule AiurWeb.OperatorControlCenter.DecisionCard do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.{DecisionAction, DecisionDetail, DecisionPath}
  alias AiurWeb.OperatorControlCenter.DecisionPresenter
  alias Phoenix.LiveView.JS

  attr(:decision, :map, required: true)
  attr(:selected, :boolean, default: false)
  attr(:now, :any, required: true)
  attr(:history, :list, default: [])
  attr(:action_state, :map, default: %{})
  attr(:writable, :boolean, required: true)
  attr(:voice_capabilities, :map, default: %{})
  attr(:live_connected, :boolean, default: true)
  attr(:filter, :atom, default: :all)
  attr(:query, :map, default: %{})

  @spec decision_card(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_card(assigns) do
    assigns =
      assigns
      |> assign(:age, age(assigns.decision.created_at, assigns.now))
      |> assign(:collapsed_path, DecisionPath.inbox(assigns.filter, assigns.query))
      |> assign(:detail_path, DecisionPath.detail(assigns.decision.decision_id, assigns.filter, assigns.query))
      |> assign(:recommendation_label, recommendation_label(assigns.decision))
      |> assign(:selected_answer_label, selected_answer_label(assigns.decision))
      |> assign(:operator_answer?, operator_answer?(assigns.decision))
      |> assign(:relay_label, relay_label(assigns.decision))
      |> assign(:executor_answer?, executor_answer?(assigns.decision))
      |> assign(:supervisor_answer?, supervisor_answer?(assigns.decision))
      |> assign(:confidence, supervisor_confidence(assigns.decision))
      |> assign(:agent_label, agent_label(assigns.decision))
      |> assign(:model_label, model_label(assigns.decision))
      |> assign(:status_badge, status_badge(assigns.decision))

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
            <span class="ticket-id">{DecisionPresenter.requester_label(@decision)}</span>
            <span :if={DecisionPresenter.executor?(@decision)} class="decision-ticket-title requester-badge">From Executor</span>
            <span :if={!DecisionPresenter.executor?(@decision)} class="decision-ticket-title">{@decision.ticket[:title]}</span>
          </div>
          <h3 id={question_id(@decision)}>{@decision.question}</h3>
        </div>
        <%!-- At most two status pills: blocking and age. Everything else lives in the disclosure. --%>
        <div class="decision-card-side" data-card-pills>
          <span :if={@decision.blocking} class="chip cmd-blocking blocking"><span class="chip-dot"></span>Blocking</span>
          <span class="chip decision-age mono">asked {@age}</span>
        </div>
      </.link>

      <DecisionAction.decision_action
        :if={
          !@selected and
            (@decision.decision_status in [:open, :deferred, :dismissed] or
               (@decision.decision_status == :expired and @decision.blocking and is_nil(@decision.answer)))
        }
        decision={@decision}
        state={@action_state}
        writable={@writable}
        live_connected={@live_connected}
        voice_capabilities={@voice_capabilities}
        question_heading_id={question_id(@decision)}
        compact
      />

      <details class="decision-more">
        <summary>Details</summary>
        <p :if={present?(@decision.context.short)} class="decision-context">{@decision.context.short}</p>
        <p :if={@recommendation_label} class="decision-recommendation">
          Recommended: <b>{@recommendation_label}</b>{if present?(@decision.recommendation.reason), do: " — #{@decision.recommendation.reason}"}
        </p>
        <div class="decision-card-foot">
          <span :if={@status_badge} class={["cmd-status-badge", @status_badge.tone]}><span class="chip-dot"></span>{@status_badge.label}</span>
          <AiurWeb.OperatorControlCenter.CommandRouting.routing decision={@decision} now={@now} />
          <AiurWeb.OperatorControlCenter.DecisionOverrides.badge decision={@decision} />
          <span :if={@agent_label} class={["chip cmd-agent", agent_class(@decision)]}>{@agent_label}</span>
          <span :if={@model_label} class="chip mono">{@model_label}</span>
          <span :if={@selected_answer_label} class="chip accent">Selected · {@selected_answer_label}</span>
          <span :if={@operator_answer?} class="chip accent">Operator answer</span>
          <span :if={@relay_label} class="chip accent">{@relay_label}</span>
          <span :if={@executor_answer?} class="chip good">Executor answer</span>
          <span :if={@supervisor_answer?} class="chip super">Supervisor answer</span>
          <span :if={is_integer(@confidence)} class="chip super">{@confidence}% confidence</span>
          <span :if={Map.get(@decision, :superseded?, false)} class="chip super">Superseded</span>
          <span :if={Map.get(@decision, :version)} class="chip mono">v{@decision.version}</span>
        </div>
      </details>

      <div phx-mounted={@selected && JS.focus(to: "#decision-detail-#{@decision.decision_id}")}>
        <DecisionDetail.decision_detail
          :if={@selected}
          decision={@decision}
          conversation_link={AiurWeb.OperatorControlCenter.DecisionConversation.link(@decision.decision_id)}
          history={@history}
          action_state={@action_state}
          writable={@writable}
          live_connected={@live_connected}
          voice_capabilities={@voice_capabilities}
          question_heading_id={question_id(@decision)}
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

  # Top-right status badge: reflects where the command sits in its lifecycle so
  # answered/dismissed cards read as historic at a glance.
  defp status_badge(%{decision_status: :open}), do: %{label: "Recorded · open", tone: "is-open"}
  defp status_badge(%{decision_status: :deferred}), do: %{label: "Deferred to Executor", tone: "is-open"}
  defp status_badge(%{decision_status: :expired}), do: %{label: "Expired", tone: "is-dismissed"}
  defp status_badge(%{decision_status: :decided}), do: %{label: "Answered", tone: "is-answered"}
  defp status_badge(%{decision_status: :acknowledged}), do: %{label: "Acknowledged", tone: "is-answered"}
  # `:dismissed` is not `:acknowledged`. Both reach this badge, and labelling
  # them alike made the durable record assert an acknowledgement the operator
  # never gave. "Closed" is true of every route into `:dismissed`.
  defp status_badge(%{decision_status: :dismissed}), do: %{label: "Closed", tone: "is-dismissed"}
  defp status_badge(%{decision_status: :resolved}), do: %{label: "Resolved", tone: "is-resolved"}
  defp status_badge(_decision), do: nil

  defp agent_label(decision) do
    case agent_family(decision) do
      value when is_binary(value) and value != "" ->
        value |> String.replace("_", " ") |> String.capitalize()

      _other ->
        nil
    end
  end

  defp model_label(decision) do
    provenance = Map.get(decision, :provenance)

    case map_value(provenance, :resolved_model) || map_value(provenance, :requested_model) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp agent_class(decision) do
    case agent_family(decision) do
      value when is_binary(value) ->
        "is-" <> (value |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-"))

      _other ->
        "is-generic"
    end
  end

  defp agent_family(decision) do
    provenance = Map.get(decision, :provenance)
    map_value(provenance, :agent_family) || map_value(provenance, :backend)
  end

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

  defp operator_answer?(%{answer: answer}) when is_map(answer) do
    get_in(answer, [:actor, :kind]) in [:operator, "operator"]
  end

  defp operator_answer?(_decision), do: false

  defp relay_label(%{answer: %{actor: %{kind: :operator_relayed}, relayed_by: relayer}}),
    do: "answered by operator, relayed by #{relayer}"

  defp relay_label(_decision), do: nil

  defp executor_answer?(%{answer: answer}) when is_map(answer) do
    get_in(answer, [:actor, :kind]) in [:executor, "executor"]
  end

  defp executor_answer?(_decision), do: false

  defp supervisor_answer?(%{answer: answer}) when is_map(answer) do
    get_in(answer, [:actor, :kind]) in [:supervisor, "supervisor"]
  end

  defp supervisor_answer?(_decision), do: false

  defp supervisor_confidence(%{answer: answer}) when is_map(answer) do
    confidence = answer |> Map.get(:supervisor_basis) |> map_value(:confidence)
    if is_integer(confidence) and confidence in 0..100, do: confidence
  end

  defp supervisor_confidence(_decision), do: nil

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

  defp question_id(decision), do: "decision-question-#{decision.decision_id}"

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
