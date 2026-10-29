defmodule Aiur.Commands.CorrectiveFacts do
  @moduledoc false

  alias Aiur.Commands.CorrectiveFailures
  alias Aiur.DecisionEvent.Validation

  @spec types() :: [atom()]
  def types, do: [:override_corrective_ticket, :override_corrective_implemented, :override_corrective_failed, :override_corrective_recovered]

  @spec normalize(atom(), map()) :: {:ok, map()} | {:error, term()}
  def normalize(:override_corrective_ticket, raw) do
    with {:ok, data} <- common(raw),
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

  def normalize(:override_corrective_implemented, raw), do: common(raw)
  def normalize(type, raw) when type in [:override_corrective_failed, :override_corrective_recovered], do: CorrectiveFailures.normalize(type, raw)

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
        if record.route == :corrective_ticket or is_map(Map.get(record, :corrective_ticket)) or Map.get(record, :pr_merged) == :unknown,
          do: update(decision, record, type, data, event.occurred_at),
          else: {:error, :corrective_override_missing}

      _missing ->
        {:error, :corrective_override_missing}
    end
  end

  defp update(decision, record, :override_corrective_ticket, data, _at) do
    linked = Map.get(record, :corrective_ticket)

    if is_nil(linked) or linked == data.ticket do
      updated = record |> Map.put(:corrective_ticket, data.ticket) |> Map.put(:route, if(is_nil(linked), do: :corrective_ticket, else: record.route))
      {:ok, replace(decision, updated)}
    else
      {:error, :corrective_ticket_mismatch}
    end
  end

  defp update(decision, %{corrective_ticket: ticket, state: state} = record, :override_corrective_implemented, data, at)
       when is_map(ticket) and state != :superseded do
    updated = %{record | state: :implemented, implemented_at: at, evidence: %{kind: :merge, pr_number: data.pr_number, merge_commit_sha: data.merge_commit_sha}}
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

  defp replace(decision, record) do
    %{decision | overrides: Enum.map(decision.overrides, &if(&1.action_id == record.action_id, do: record, else: &1))}
  end
end
