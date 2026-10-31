defmodule Aiur.Commands.CorrectiveFacts do
  @moduledoc false

  alias Aiur.Commands.CorrectiveFailures
  alias Aiur.DecisionEvent.Validation

  @spec types() :: [atom()]
  def types, do: [:override_successor_ticket, :override_corrective_ticket, :override_corrective_implemented, :override_corrective_failed, :override_corrective_recovered, :override_corrective_closed]

  @spec normalize(atom(), map()) :: {:ok, map()} | {:error, term()}
  def normalize(type, raw) when type in [:override_corrective_ticket, :override_successor_ticket] do
    with {:ok, data} <- ticket_evidence(type, raw),
         ticket when is_map(ticket) <- Validation.get(raw, :ticket),
         {:ok, identifier} <- Validation.map_required_string(ticket, :identifier, 256),
         {:ok, title} <- Validation.bounded_optional(Validation.get(ticket, :title), 512, :title),
         {:ok, url} <- Validation.bounded_optional(Validation.get(ticket, :url), 2048, :url) do
      {:ok, Map.put(data, :ticket, %{identifier: identifier, title: title, url: url})}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_corrective_ticket}
    end
  end

  def normalize(:override_corrective_closed, raw) do
    with {:ok, action_id} <- Validation.map_required_string(raw, :action_id, 256), do: {:ok, %{action_id: action_id}}
  end

  def normalize(:override_corrective_implemented, raw), do: common(raw)
  def normalize(type, raw) when type in [:override_corrective_failed, :override_corrective_recovered], do: CorrectiveFailures.normalize(type, raw)

  defp ticket_evidence(:override_corrective_ticket, raw), do: common(raw)

  defp ticket_evidence(:override_successor_ticket, raw) do
    with {:ok, action_id} <- Validation.map_required_string(raw, :action_id, 256), do: {:ok, %{action_id: action_id}}
  end

  defp common(raw) do
    with {:ok, action_id} <- Validation.map_required_string(raw, :action_id, 256),
         {:ok, sha} <- Validation.map_required_string(raw, :merge_commit_sha, 128),
         number when is_integer(number) and number > 0 <- Validation.get(raw, :pr_number) do
      {:ok, %{action_id: action_id, pr_number: number, merge_commit_sha: sha}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_corrective_evidence}
    end
  end

  @spec apply(map(), map()) :: {:ok, map()} | {:error, term()}
  def apply(decision, %{type: type, data: data} = event) do
    case Enum.find(decision.overrides, &(&1.action_id == data.action_id)) do
      record when is_map(record) ->
        if eligible?(decision, record, type),
          do: update(decision, record, type, data, event),
          else: {:error, :corrective_override_missing}

      _missing ->
        {:error, :corrective_override_missing}
    end
  end

  defp eligible?(decision, record, type) when type in [:override_corrective_failed, :override_corrective_recovered],
    do: record.action_id == decision.active_action_id or corrective?(record)

  defp eligible?(_decision, record, :override_successor_ticket), do: record.pr_merged == false or corrective?(record)
  defp eligible?(_decision, record, _type), do: corrective?(record)

  defp corrective?(record), do: record.route in [:corrective_ticket, :replacement] or is_map(Map.get(record, :corrective_ticket)) or Map.get(record, :pr_merged) == :unknown

  defp update(decision, record, :override_corrective_closed, _data, event),
    do: {:ok, replace(decision, Map.put(record, :closed_without_merged_pr_at, event.occurred_at))}

  defp update(decision, record, type, data, event) when type in [:override_corrective_ticket, :override_successor_ticket] do
    linked = Map.get(record, :corrective_ticket)

    if type == :override_successor_ticket or is_nil(linked) or linked == data.ticket do
      updated = record |> Map.put(:corrective_ticket, data.ticket) |> Map.put(:route, if(is_nil(linked), do: :corrective_ticket, else: record.route))
      updated = if Map.has_key?(record, :merge_reason), do: Map.put(updated, :merge_reason, "PR merged before the change; corrective ticket ##{data.ticket.identifier}"), else: updated
      updated = if type == :override_successor_ticket, do: Map.put(updated, :recovery_path, :successor), else: updated
      decision = replace(decision, updated)
      prior = if type == :override_successor_ticket, do: %{record | corrective_ticket: nil, ticket: linked || record.ticket}, else: record
      {:ok, retarget(decision, prior, data.ticket, event)}
    else
      {:error, :corrective_ticket_mismatch}
    end
  end

  defp update(decision, %{corrective_ticket: ticket, state: state} = record, :override_corrective_implemented, data, event)
       when is_map(ticket) and state != :superseded do
    updated = %{record | state: :implemented, implemented_at: event.occurred_at, evidence: %{kind: :merge, pr_number: data.pr_number, merge_commit_sha: data.merge_commit_sha}}
    {:ok, replace(decision, updated)}
  end

  defp update(decision, %{state: state} = record, :override_corrective_failed = type, data, _at)
       when state not in [:superseded, :implemented] do
    {:ok, replace(decision, CorrectiveFailures.apply(record, type, data))}
  end

  defp update(decision, record, :override_corrective_recovered = type, data, _at) do
    {:ok, replace(decision, CorrectiveFailures.apply(record, type, data))}
  end

  defp update(_decision, _record, _type, _data, _at), do: {:error, :corrective_ticket_missing}

  defp retarget(decision, %{action_id: action_id, corrective_ticket: nil, ticket: prior, state: state}, ticket, event)
       when action_id == decision.active_action_id and prior.identifier != ticket.identifier and state not in [:superseded, :implemented] do
    outcome = %{result: :recorded, reason_class: nil, occurred_at: event.occurred_at, event_id: Map.get(event, :event_id), run_id: Map.get(event, :run_id)}
    record = Enum.find(decision.overrides, &(&1.action_id == action_id))
    {previous, current} = Enum.split_with(decision.dispatch_attempts, &(&1.action_id == action_id))
    record = record |> Map.put(:prior_dispatch_attempts, previous) |> Map.merge(%{state: :queued, delivered_at: nil, implemented_at: nil, evidence: nil})

    decision
    |> replace(record)
    |> Map.merge(%{
      dispatch_attempts: current,
      decision_status: :decided,
      acknowledgement: nil,
      resolution: nil,
      revision_result: :recorded,
      revision_outcomes: Map.put(decision.revision_outcomes, action_id, outcome),
      delivery_status: :pending,
      pending_for_session?: false
    })
  end

  defp retarget(decision, _record, _ticket, _event), do: decision

  defp replace(decision, record) do
    %{decision | overrides: Enum.map(decision.overrides, &if(&1.action_id == record.action_id, do: record, else: &1))}
  end
end
