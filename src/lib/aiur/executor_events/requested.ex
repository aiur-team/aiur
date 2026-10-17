defmodule Aiur.ExecutorEvents.Requested do
  @moduledoc false

  alias Aiur.Decision
  alias Aiur.ExecutorEvents

  @spec payload(Decision.t()) :: map()
  def payload(decision) do
    %{
      decision_id: decision.decision_id,
      decision_version: decision.version,
      issue_identifier: decision.ticket.identifier,
      title: decision.question,
      options: decision.options,
      context: decision.context,
      recommendation: decision.recommendation,
      authority: decision.authority,
      urgency: decision.urgency,
      blocking: decision.blocking,
      reversibility: decision.reversibility,
      consequence_of_delay: decision.consequence_of_delay,
      created_at: decision.created_at,
      provenance: :decision_store
    }
  end

  @spec ensure_requested(Decision.t(), [map()]) :: {:ok, pos_integer(), non_neg_integer()} | {:error, term()}
  def ensure_requested(%Decision{} = decision, events) do
    case requested_event_id(events, decision.decision_id, decision.version) do
      {:ok, id} -> {:ok, id, 0}
      :not_found -> ExecutorEvents.publish_requested(decision)
    end
  end

  @spec reconcile_requested([Decision.t()], [map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile_requested(decisions, events) do
    decisions
    |> missing_requested(events)
    |> publish_missing_requested()
  end

  defp missing_requested(decisions, events) do
    existing =
      events
      |> Enum.filter(&(&1["topic"] == "executor.decision.requested"))
      |> MapSet.new(&{&1["decision_id"], &1["decision_version"]})

    Enum.reject(decisions, &MapSet.member?(existing, {&1.decision_id, &1.version}))
  end

  # Never halts part-way. Halting left the untried tail unpublished while the
  # caller retried the whole batch, so every already-published Decision was
  # published a second time. Each Decision is attempted exactly once here and
  # only the still-unpublished ones can be retried by the caller.
  defp publish_missing_requested(decisions) do
    {published, failures} =
      Enum.reduce(decisions, {0, []}, fn decision, {count, failures} ->
        case ExecutorEvents.publish_requested(decision) do
          {:ok, _id, _subscribers} -> {count + 1, failures}
          {:error, reason} -> {count, [reason | failures]}
        end
      end)

    case Enum.reverse(failures) do
      [] -> {:ok, published}
      [reason | _rest] -> {:error, reason}
    end
  end

  defp requested_event_id(events, decision_id, version) do
    case Enum.find(events, &requested_event?(&1, decision_id, version)) do
      %{"id" => id} when is_integer(id) -> {:ok, id}
      _event -> :not_found
    end
  end

  defp requested_event?(event, decision_id, version) do
    event["topic"] == "executor.decision.requested" and
      event["decision_id"] == decision_id and
      event["decision_version"] == version
  end
end
