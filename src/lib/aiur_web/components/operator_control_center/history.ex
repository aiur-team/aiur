defmodule AiurWeb.OperatorControlCenter.History do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.DecisionPath

  attr(:entries, :list, required: true)
  attr(:decisions, :list, default: [])
  attr(:provider_health, :any, default: :ok)
  attr(:visible_count, :integer, default: 10)
  attr(:hidden_decision_ids, :list, default: [])

  @spec history(map()) :: Phoenix.LiveView.Rendered.t()
  def history(assigns) do
    visible_count = max(assigns.visible_count, 10)
    rows = assigns.decisions |> history_rows(assigns.entries, assigns.hidden_decision_ids) |> Enum.take(visible_count + 1)
    {visible_rows, overflow} = Enum.split(rows, visible_count)

    assigns =
      assigns
      |> assign(:rows, visible_rows)
      |> assign(:empty?, visible_rows == [])
      |> assign(:has_more?, overflow != [])

    ~H"""
    <section class="recent-section" aria-labelledby="decision-history-title">
      <p class="recent-subtitle" id="decision-history-title">Command history</p>
      <div :if={@provider_health == :unavailable} class="empty-state compact">History provider is currently unavailable.</div>
      <div :if={@provider_health == :degraded} class="empty-state compact">
        Command history is degraded; showing the last validated prefix.
      </div>
      <div :if={@provider_health == :ok and @empty?} class="empty-state compact">No Command actions have been recorded.</div>
      <div :if={@rows != []} class="command-history-wrap">
        <table class="command-history-table">
          <thead>
            <tr>
              <th scope="col">Command</th>
              <th scope="col">Outcome</th>
              <th scope="col">Actor</th>
              <th scope="col">Time</th>
              <th scope="col">Details</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} data-severity={row.style}>
              <td class="history-command-cell">
                <span class="ticket-id">{row.ticket_identifier}</span>
                <.link patch={DecisionPath.detail(row.decision_id, :all)}>{row.question}</.link>
              </td>
              <td><span class={["history-outcome", row.style]}>{row.outcome}</span></td>
              <td>
                <span class="actor-tag">
                  <span class={["actor-glyph", actor_class(row.actor)]}>{actor_code(row.actor)}</span>{actor_label(row.actor)}
                </span>
              </td>
              <td class="timeline-time mono">{format_datetime(row.changed_at)}</td>
              <td class="history-details-cell">
                <p :if={row.detail}>{row.detail}</p>
                <div class="history-detail-tags">
                  <.result_chip label="dispatch" result={Map.get(row.source, :dispatch_result)} />
                  <.result_chip label="ack" result={Map.get(row.source, :acknowledgement_result)} />
                  <.result_chip label="revision" result={Map.get(row.source, :revision_result)} />
                  <span :if={is_integer(confidence(row.source))} class="chip super">{confidence(row.source)}% confidence</span>
                  <span :if={provenance_label(row.source)} class="chip mono">{provenance_label(row.source)}</span>
                  <span :if={identifier(Map.get(row.source, :superseded_by))} class="chip attention">
                    Superseded by <span class="mono">{identifier(Map.get(row.source, :superseded_by))}</span>
                  </span>
                  <span :if={identifier(Map.get(row.source, :revision_of))} class="chip super">
                    Supersedes <span class="mono">{identifier(Map.get(row.source, :revision_of))}</span>
                  </span>
                  <span :if={Map.get(row.source, :revised?, false)} class="chip super">Revised</span>
                  <span :if={Map.get(row.source, :follow_up_required, false) and not Map.get(row.source, :follow_up_handled, false)} class="chip blocking">
                    Follow-up required
                  </span>
                  <span :if={Map.get(row.source, :follow_up_handled, false)} class="chip good">Follow-up handled</span>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <button :if={@has_more?} type="button" class="btn secondary command-history-more" phx-click="load-command-history">
        Load more
      </button>
    </section>
    """
  end

  defp history_rows(decisions, entries, hidden_decision_ids) do
    hidden_decision_ids = MapSet.new(hidden_decision_ids)

    historic_decisions = Enum.filter(decisions, &historic?/1)
    historic_decisions = Enum.reject(historic_decisions, &MapSet.member?(hidden_decision_ids, &1.decision_id))
    historic_ids = MapSet.new(historic_decisions, & &1.decision_id)

    decision_rows = Stream.map(historic_decisions, &decision_row/1)

    audit_rows =
      entries
      |> Stream.reject(&MapSet.member?(hidden_decision_ids, &1.decision_id))
      |> Stream.reject(&MapSet.member?(historic_ids, &1.decision_id))
      |> Stream.map(&audit_row/1)

    Stream.concat(decision_rows, audit_rows)
  end

  defp decision_row(decision) do
    {outcome, style} = decision_outcome(decision)

    %{
      decision_id: decision.decision_id,
      ticket_identifier: ticket_identifier(decision.ticket) || decision.decision_id,
      question: decision.question,
      outcome: outcome,
      style: style,
      detail: decision_choice(decision),
      actor: decision_actor(decision),
      changed_at: decision_changed_at(decision),
      source: decision
    }
  end

  defp audit_row(entry) do
    {outcome, style} = audit_outcome(Map.get(entry, :change))

    %{
      decision_id: entry.decision_id,
      ticket_identifier: ticket_identifier(entry.ticket) || entry.decision_id,
      question: entry.question || humanize(entry.change),
      outcome: outcome,
      style: style,
      detail: Map.get(entry, :choice) || Map.get(entry, :rationale),
      actor: Map.get(entry, :actor),
      changed_at: Map.get(entry, :changed_at),
      source: entry
    }
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

  defp historic?(decision),
    do: Map.get(decision, :decision_status) in [:deferred, :expired, :decided, :acknowledged, :resolved, :dismissed]

  defp decision_outcome(%{decision_status: :deferred}), do: {"Executor notified", "good"}
  defp decision_outcome(%{decision_status: :expired}), do: {"Expired", "expired"}
  defp decision_outcome(%{decision_status: :decided}), do: {"Answered", "good"}
  defp decision_outcome(%{decision_status: :acknowledged}), do: {"Acknowledged", "good"}
  defp decision_outcome(%{decision_status: :resolved}), do: {"Resolved", "good"}
  defp decision_outcome(%{decision_status: :dismissed}), do: {"Acknowledged", "good"}

  defp audit_outcome(change) when change in [:answered], do: {"Answered", "good"}
  defp audit_outcome(change) when change in [:executor_notified, :decision_deferred], do: {"Executor notified", "good"}
  defp audit_outcome(change) when change in [:acknowledged, :decision_dismissed], do: {"Acknowledged", "good"}
  defp audit_outcome(:resolved), do: {"Resolved", "good"}
  defp audit_outcome(:expired), do: {"Expired", "expired"}
  defp audit_outcome(change), do: {humanize(change), "neutral"}

  defp decision_choice(%{decision_status: :expired}), do: "Expired — agent is no longer running"
  defp decision_choice(%{decision_status: :dismissed}), do: "Acknowledged — closed without a recorded answer"
  defp decision_choice(%{answer: %{custom_response: response}}) when is_binary(response), do: response

  defp decision_choice(%{answer: %{selected_option_id: option_id}, options: options}) when is_binary(option_id) do
    case Enum.find(options, &(&1.id == option_id)) do
      nil -> "Option #{option_id}"
      option -> option.label
    end
  end

  defp decision_choice(_decision), do: nil

  defp decision_actor(%{answer: %{actor: actor}}), do: normalize_decision_actor(actor)
  defp decision_actor(_decision), do: nil

  defp normalize_decision_actor(%{kind: :operator, id: id}),
    do: %{type: :human_operator, id: id, label: id || "Executor"}

  defp normalize_decision_actor(%{kind: :supervisor, id: id}),
    do: %{type: :supervising_agent, id: id, label: id || "Supervising agent"}

  defp normalize_decision_actor(%{kind: :agent, id: id}),
    do: %{type: :ticket_agent, id: id, label: id || "Ticket agent"}

  defp normalize_decision_actor(_actor), do: nil

  defp decision_changed_at(%{answer: %{accepted_at: accepted_at}}), do: accepted_at
  defp decision_changed_at(decision), do: Map.get(decision, :created_at)

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
