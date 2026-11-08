defmodule Aiur.Commands.CorrectiveFailures do
  @moduledoc false

  alias Aiur.DecisionEvent.Validation

  @spec due?(map(), DateTime.t()) :: boolean()
  def due?(%{failure: %{retry_at: retry_at}}, now), do: DateTime.compare(now, retry_at) != :lt
  def due?(_record, _now), do: true

  @spec build(map(), term(), DateTime.t()) :: map()
  def build(record, reason, now) do
    prior = Map.get(record, :failure) || %{}
    attempts = Map.get(prior, :attempts, 0) + 1
    delay = min(60 * Integer.pow(2, min(attempts - 1, 6)), 3_600)
    alerted = Map.get(prior, :alerted, false) or permanent?(reason) or attempts >= 3

    %{
      action_id: record.action_id,
      reason: reason |> inspect(limit: 20, printable_limit: 512) |> Aiur.SecretRedactor.redact() |> String.slice(0, 1_024),
      failure_class: Aiur.Signal.reason_class(reason),
      attempts: attempts,
      retry_at: DateTime.add(now, delay),
      alerted: alerted
    }
  end

  @spec normalize(atom(), map()) :: {:ok, map()} | {:error, term()}
  def normalize(:override_corrective_recovered, raw) do
    with {:ok, action_id} <- Validation.map_required_string(raw, :action_id, 256), do: {:ok, %{action_id: action_id}}
  end

  def normalize(:override_corrective_failed, raw) do
    with {:ok, action_id} <- Validation.map_required_string(raw, :action_id, 256),
         {:ok, reason} <- Validation.map_required_string(raw, :reason, 1_024),
         {:ok, failure_class} <- Validation.map_required_string(raw, :failure_class, 256),
         {:ok, attempts} <- Validation.map_required_pos_integer(raw, :attempts),
         {:ok, retry_at} <- timestamp(Validation.get(raw, :retry_at)),
         alerted when is_boolean(alerted) <- Validation.get(raw, :alerted) do
      {:ok, %{action_id: action_id, reason: reason, failure_class: failure_class, attempts: attempts, retry_at: retry_at, alerted: alerted}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_corrective_failure}
    end
  end

  @spec apply(map(), atom(), map()) :: map()
  def apply(record, :override_corrective_failed, data) do
    state = if record.state == :delivered, do: :delivered, else: :failed
    Map.merge(record, %{state: state, failure: Map.delete(data, :action_id)})
  end

  def apply(record, :override_corrective_recovered, _data) do
    state = if Map.get(record, :delivered_at), do: :delivered, else: :queued
    record |> Map.put(:failure, nil) |> Map.put(:state, if(record.state == :failed, do: state, else: record.state))
  end

  defp permanent?({:github, :http, %{status: status}}), do: status in [400, 401, 403, 404, 410, 422]
  defp permanent?(reason), do: reason in [:original_ticket_missing, :merged_pr_evidence_missing, :invalid_issue]

  defp timestamp(%DateTime{} = at), do: {:ok, at}

  defp timestamp(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      _invalid -> {:error, :invalid_retry_at}
    end
  end

  defp timestamp(_invalid), do: {:error, :invalid_retry_at}
end
