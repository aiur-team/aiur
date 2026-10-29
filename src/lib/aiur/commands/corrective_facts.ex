defmodule Aiur.Commands.CorrectiveFacts do
  @moduledoc false

  alias Aiur.DecisionEvent.Validation

  @spec types() :: [atom()]
  def types, do: [:override_corrective_ticket, :override_corrective_implemented]

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
      %{route: :corrective_ticket} = record -> update(decision, record, type, data, event.occurred_at)
      _missing -> {:error, :corrective_override_missing}
    end
  end

  defp update(decision, record, :override_corrective_ticket, data, _at) do
    linked = Map.get(record, :corrective_ticket)

    if is_nil(linked) or linked == data.ticket do
      updated = Map.put(record, :corrective_ticket, data.ticket)
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

  defp update(_decision, _record, _type, _data, _at), do: {:error, :corrective_ticket_missing}

  defp replace(decision, record) do
    %{decision | overrides: Enum.map(decision.overrides, &if(&1.action_id == record.action_id, do: record, else: &1))}
  end
end
