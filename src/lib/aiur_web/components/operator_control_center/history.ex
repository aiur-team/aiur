defmodule AiurWeb.OperatorControlCenter.History do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.DecisionPath

  attr(:entries, :list, required: true)
  attr(:decisions, :list, default: [])
  attr(:provider_health, :any, default: :ok)

  @spec history(map()) :: Phoenix.LiveView.Rendered.t()
  def history(assigns) do
    historic_decisions = Enum.filter(assigns.decisions, &historic?/1)
    historic_ids = MapSet.new(historic_decisions, & &1.decision_id)

    assigns =
      assigns
      |> assign(:historic_decisions, historic_decisions)
      |> assign(:audit_entries, Enum.reject(assigns.entries, &MapSet.member?(historic_ids, &1.decision_id)))
      |> assign(:empty?, historic_decisions == [] and assigns.entries == [])

    ~H"""
    <section class="recent-section" aria-labelledby="decision-history-title">
      <p class="recent-subtitle" id="decision-history-title">Command history</p>
      <div :if={@provider_health == :unavailable} class="empty-state compact">History provider is currently unavailable.</div>
      <div :if={@provider_health == :degraded} class="empty-state compact">
        Command history is degraded; showing the last validated prefix.
      </div>
      <div :if={@provider_health == :ok and @empty?} class="empty-state compact">No Command actions have been recorded.</div>
      <div class="history-list">
        <article :for={decision <- @historic_decisions} class="history-item" data-severity="good">
          <span class="severity-rail"></span>
          <header>
            <span class="ticket-id">{ticket_identifier(decision.ticket) || decision.decision_id}</span>
            <strong>{decision.question}</strong>
          </header>
          <p :if={decision_choice(decision)} class="history-choice">Choice: <b>{decision_choice(decision)}</b></p>
          <footer>
            <span class="chip good">{decision_status(decision)}</span>
            <span :if={provenance_label(decision)} class="chip mono">{provenance_label(decision)}</span>
            <.link patch={DecisionPath.detail(decision.decision_id, :all)} class="link-pill">Open Command</.link>
          </footer>
        </article>
        <article :for={entry <- @audit_entries} class="history-item">
          <span class="severity-rail"></span>
          <header>
            <span class="ticket-id">{ticket_identifier(entry.ticket) || entry.decision_id}</span>
            <strong>{entry.question || humanize(entry.change)}</strong>
          </header>
          <p :if={entry.choice} class="history-choice">Choice: <b>{entry.choice}</b></p>
          <p :if={entry.rationale} class="history-rationale">{entry.rationale}</p>
          <footer>
            <span class="actor-tag"><span class={["actor-glyph", actor_class(entry.actor)]}>{actor_code(entry.actor)}</span>{actor_label(entry.actor)}</span>
            <span class="timeline-time mono">{format_datetime(entry.changed_at)}</span>
            <.result_chip label="dispatch" result={entry.dispatch_result} />
            <.result_chip label="ack" result={entry.acknowledgement_result} />
            <.result_chip label="revision" result={Map.get(entry, :revision_result)} />
            <span :if={is_integer(confidence(entry))} class="chip super">{confidence(entry)}% confidence</span>
            <span :if={provenance_label(entry)} class="chip mono">{provenance_label(entry)}</span>
            <span :if={identifier(Map.get(entry, :superseded_by))} class="chip attention">
              Superseded by <span class="mono">{identifier(Map.get(entry, :superseded_by))}</span>
            </span>
            <span :if={identifier(Map.get(entry, :revision_of))} class="chip super">
              Supersedes <span class="mono">{identifier(Map.get(entry, :revision_of))}</span>
            </span>
            <span :if={entry.revised?} class="chip super">Revised</span>
            <span :if={entry.follow_up_required and not entry.follow_up_handled} class="chip blocking">Follow-up required</span>
            <span :if={entry.follow_up_handled} class="chip good">Follow-up handled</span>
            <.link patch={DecisionPath.detail(entry.decision_id, :all)} class="link-pill">Open Command</.link>
          </footer>
        </article>
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:result, :any, required: true)

  defp result_chip(assigns) do
    ~H"""
    <span :if={@result} class={["chip", result_tone(@result)]}>{@label}: {humanize(@result)}</span>
    """
  end

  defp result_tone(result) when result in [:ok, :acknowledged, :delivered, "ok", "acknowledged", "delivered"], do: "good"
  defp result_tone(result) when result in [:failed, :delivery_failed, "failed", "delivery_failed"], do: "blocking"
  defp result_tone(result) when result in [:no_longer_applicable, "no_longer_applicable"], do: "blocking"
  defp result_tone(result) when result in [:dispatched, "dispatched"], do: "good"
  defp result_tone(_result), do: "attention"

  defp confidence(entry) do
    confidence = entry |> Map.get(:supervisor_basis) |> map_value(:confidence)
    if is_integer(confidence) and confidence in 0..100, do: confidence
  end

  defp provenance_label(entry) do
    provenance = Map.get(entry, :provenance)
    backend = map_value(provenance, :backend) || map_value(provenance, :agent_family)
    model = map_value(provenance, :resolved_model) || map_value(provenance, :requested_model)

    case {identifier(backend), identifier(model)} do
      {backend, model} when is_binary(backend) and is_binary(model) -> "#{backend} · #{model}"
      {backend, nil} when is_binary(backend) -> backend
      {nil, model} when is_binary(model) -> model
      _unknown -> nil
    end
  end

  defp historic?(decision), do: Map.get(decision, :decision_status) in [:decided, :acknowledged, :resolved, :dismissed]

  defp decision_status(%{decision_status: :decided}), do: "Answered"
  defp decision_status(%{decision_status: :acknowledged}), do: "Acknowledged"
  defp decision_status(%{decision_status: :resolved}), do: "Resolved"
  defp decision_status(%{decision_status: :dismissed}), do: "Dismissed"

  defp decision_choice(%{decision_status: :dismissed}), do: "Dismissed — agent proceeds with best judgement"
  defp decision_choice(%{answer: %{custom_response: response}}) when is_binary(response), do: response

  defp decision_choice(%{answer: %{selected_option_id: option_id}, options: options}) when is_binary(option_id) do
    case Enum.find(options, &(&1.id == option_id)) do
      nil -> "Option #{option_id}"
      option -> option.label
    end
  end

  defp decision_choice(_decision), do: nil

  defp identifier(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp identifier(_value), do: nil

  defp map_value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp map_value(_map, _key), do: nil

  defp ticket_identifier(%{identifier: identifier}), do: identifier
  defp ticket_identifier(identifier) when is_binary(identifier), do: identifier
  defp ticket_identifier(_ticket), do: nil
  defp actor_label(%{label: label}) when is_binary(label), do: label
  defp actor_label(%{type: type}), do: humanize(type)
  defp actor_label(_actor), do: "Unknown source"
  defp actor_code(%{type: :human_operator}), do: "OP"
  defp actor_code(%{type: :supervising_agent}), do: "SA"
  defp actor_code(%{type: :ticket_agent}), do: "TA"
  defp actor_code(_actor), do: "··"
  defp actor_class(%{type: :supervising_agent}), do: "supervising"
  defp actor_class(%{type: :ticket_agent}), do: "ticket"
  defp actor_class(_actor), do: "human"
  defp humanize(nil), do: "System"
  defp humanize(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  defp format_datetime(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp format_datetime(value) when is_binary(value), do: value
  defp format_datetime(_value), do: "unknown"
end
