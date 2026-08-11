defmodule AiurWeb.OperatorControlCenter.HistoryRowPresenter do
  @moduledoc false

  alias Aiur.EventHumanizerHelpers

  @historic_statuses [:deferred, :expired, :decided, :acknowledged, :resolved, :dismissed]

  @spec rows([map()], [map()], [String.t()]) :: Enumerable.t()
  def rows(decisions, entries, hidden_decision_ids) do
    hidden_decision_ids = MapSet.new(hidden_decision_ids)
    entries_by_decision = Enum.group_by(entries, & &1.decision_id)

    historic_decisions = Enum.filter(decisions, &(Map.get(&1, :decision_status) in @historic_statuses))
    historic_decisions = Enum.reject(historic_decisions, &MapSet.member?(hidden_decision_ids, &1.decision_id))
    historic_ids = MapSet.new(historic_decisions, & &1.decision_id)

    decision_rows =
      Stream.map(historic_decisions, fn decision ->
        audit_entry =
          entries_by_decision
          |> Map.get(decision.decision_id, [])
          |> Enum.find(&outcome_entry?(&1, decision.decision_status))

        decision_row(decision, audit_entry)
      end)

    audit_rows =
      entries
      |> Stream.reject(&MapSet.member?(hidden_decision_ids, &1.decision_id))
      |> Stream.reject(&MapSet.member?(historic_ids, &1.decision_id))
      |> Stream.map(&audit_row/1)

    Stream.concat(decision_rows, audit_rows)
  end

  defp decision_row(decision, audit_entry) do
    {outcome, style} = decision_outcome(decision)

    %{
      decision_id: decision.decision_id,
      ticket_identifier: ticket_identifier(decision.ticket) || decision.decision_id,
      question: decision.question,
      outcome: outcome,
      style: style,
      detail: decision_choice(decision) || map_value(audit_entry, :choice) || map_value(audit_entry, :rationale),
      actor: map_value(audit_entry, :actor) || decision_actor(decision),
      changed_at: map_value(audit_entry, :changed_at) || decision_changed_at(decision)
    }
    |> Map.merge(metadata(audit_entry || decision))
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
      changed_at: Map.get(entry, :changed_at)
    }
    |> Map.merge(metadata(entry))
  end

  defp outcome_entry?(entry, :deferred),
    do: Map.get(entry, :change) in [:executor_notified, :decision_deferred]

  defp outcome_entry?(entry, :expired),
    do: Map.get(entry, :change) in [:expired, :decision_expired]

  defp outcome_entry?(entry, :decided), do: Map.get(entry, :change) == :answered
  defp outcome_entry?(entry, :acknowledged), do: Map.get(entry, :change) == :acknowledged
  defp outcome_entry?(entry, :resolved), do: Map.get(entry, :change) == :resolved

  defp outcome_entry?(entry, :dismissed),
    do: Map.get(entry, :change) in [:acknowledged, :decision_dismissed]

  defp outcome_entry?(_entry, _status), do: false

  defp decision_outcome(%{decision_status: :deferred}), do: {"Executor notified", "good"}
  defp decision_outcome(%{decision_status: :expired}), do: {"Expired", "expired"}
  defp decision_outcome(%{decision_status: :decided}), do: {"Answered", "good"}
  defp decision_outcome(%{decision_status: :acknowledged}), do: {"Acknowledged", "good"}
  defp decision_outcome(%{decision_status: :resolved}), do: {"Resolved", "good"}
  defp decision_outcome(%{decision_status: :dismissed}), do: {"Acknowledged", "good"}

  defp audit_outcome(:answered), do: {"Answered", "good"}
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

  defp metadata(source) do
    %{
      dispatch_result: Map.get(source, :dispatch_result),
      acknowledgement_result: Map.get(source, :acknowledgement_result),
      revision_result: Map.get(source, :revision_result),
      confidence: confidence(source),
      provenance_label: provenance_label(source),
      superseded_by: identifier(Map.get(source, :superseded_by)),
      revision_of: identifier(Map.get(source, :revision_of)),
      revised?: Map.get(source, :revised?, false),
      follow_up_required?: Map.get(source, :follow_up_required, false),
      follow_up_handled?: Map.get(source, :follow_up_handled, false)
    }
  end

  defp confidence(source) do
    confidence = source |> Map.get(:supervisor_basis) |> map_value(:confidence)
    if is_integer(confidence) and confidence in 0..100, do: confidence
  end

  defp provenance_label(source) do
    provenance = Map.get(source, :provenance)
    backend = map_value(provenance, :backend) || map_value(provenance, :agent_family)
    model = map_value(provenance, :resolved_model) || map_value(provenance, :requested_model)

    case {identifier(backend), identifier(model)} do
      {backend, model} when is_binary(backend) and is_binary(model) -> "#{backend} · #{model}"
      {backend, nil} when is_binary(backend) -> backend
      {nil, model} when is_binary(model) -> model
      _unknown -> nil
    end
  end

  defp identifier(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp identifier(_value), do: nil
  defp map_value(map, key), do: EventHumanizerHelpers.map_path(map, [key])
  defp ticket_identifier(%{identifier: identifier}), do: identifier
  defp ticket_identifier(identifier) when is_binary(identifier), do: identifier
  defp ticket_identifier(_ticket), do: nil
  defp humanize(nil), do: "System"
  defp humanize(value), do: Phoenix.Naming.humanize(value)
end
