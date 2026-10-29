defmodule Aiur.DecisionStore.CorrectiveOverrides do
  @moduledoc false
  require Logger
  alias Aiur.Commands.{CorrectiveFailures, CorrectiveTicket}
  alias Aiur.DecisionDispatchTasks
  alias Aiur.DecisionStore.{CommandFacts, Dispatch}

  @spec configure(map(), keyword()) :: map()
  def configure(state, opts) do
    Map.merge(state, %{
      corrective_override_jobs: %{},
      corrective_override_reconciler: Keyword.get(opts, :corrective_override_reconciler, &CorrectiveTicket.reconcile/2),
      corrective_override_now: Keyword.get(opts, :corrective_override_now, &DateTime.utc_now/0),
      corrective_override_alert: Keyword.get(opts, :corrective_override_alert, &Aiur.Signal.agent_alert/3)
    })
  end

  @spec reconcile(map()) :: map()
  def reconcile(%{writable?: true, health: :writable} = state) do
    Enum.reduce(state.current, state, fn {_id, decision}, acc -> reconcile_decision(acc, decision) end)
  end

  def reconcile(state), do: state

  defp reconcile_decision(%{writable?: true, health: :writable} = state, decision) do
    state = clear_inactive_failures(state, decision)

    case Enum.find(decision.overrides, &(&1.action_id == decision.active_action_id)) do
      %{state: status} = record when status not in [:superseded, :implemented] ->
        if candidate?(record) and CorrectiveFailures.due?(record, state.corrective_override_now.()), do: enqueue(state, decision, record), else: state

      _other ->
        state
    end
  end

  defp reconcile_decision(state, _decision), do: state

  defp clear_inactive_failures(state, decision) do
    Enum.reduce(decision.overrides, state, fn
      %{state: status, failure: failure} = record, acc when status in [:superseded, :implemented] and is_map(failure) ->
        reason = if status == :superseded, do: "A newer override superseded this failed action", else: "This override has been implemented"

        if not failure.alerted or resolve_alert(acc, decision, record, reason) == :ok,
          do: clear_failure(acc, decision, record),
          else: acc

      _record, acc ->
        acc
    end)
  end

  defp candidate?(record), do: record.route == :corrective_ticket or is_map(Map.get(record, :corrective_ticket)) or Map.get(record, :pr_merged) == :unknown

  defp enqueue(state, decision, record) do
    if Map.has_key?(state.corrective_override_jobs, decision.decision_id),
      do: state,
      else: start_job(state, decision, record)
  end

  defp start_job(state, decision, record) do
    owner = self()
    correlation = %{decision_id: decision.decision_id, action_id: record.action_id, job_id: make_ref()}
    operation = fn -> state.corrective_override_reconciler.(decision, record) end
    callback = fn key, result -> send(owner, {:corrective_override_result, key, result}) end

    case DecisionDispatchTasks.enqueue(decision.ticket.identifier, correlation, operation, callback, state.decision_dispatch_tasks, owner: owner) do
      :pending -> %{state | corrective_override_jobs: Map.put(state.corrective_override_jobs, decision.decision_id, correlation.job_id)}
      {:error, reason} -> fail(state, decision, record, reason)
    end
  end

  @spec settle(map(), map(), term()) :: map()
  def settle(state, correlation, result) do
    if Map.get(state.corrective_override_jobs, correlation.decision_id) == correlation.job_id,
      do: settle_current(state, correlation, result),
      else: state
  end

  defp settle_current(state, correlation, result) do
    state = %{state | corrective_override_jobs: Map.delete(state.corrective_override_jobs, correlation.decision_id)}
    decision = Map.get(state.current, correlation.decision_id)
    record = if decision, do: Enum.find(decision.overrides, &(&1.action_id == decision.active_action_id))

    if decision && decision.active_action_id == correlation.action_id && record && record.state not in [:superseded, :implemented],
      do: settle_result(state, decision, result),
      else: state
  end

  defp settle_result(state, decision, result) do
    record = Enum.find(decision.overrides, &(&1.action_id == decision.active_action_id))

    case result do
      {:ok, facts} when is_list(facts) -> settle_facts(state, decision, facts)
      {:error, reason} -> fail(state, decision, record, reason)
      other -> fail(state, decision, record, {:invalid_result, other})
    end
  end

  defp settle_facts(state, decision, facts) do
    result =
      Enum.reduce_while(facts, {:ok, state}, fn fact, {:ok, acc} ->
        case record_fact(acc, decision.decision_id, fact) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, reason, next} -> {:halt, {:error, reason, next}}
        end
      end)

    case result do
      {:ok, next} ->
        updated = Map.fetch!(next.current, decision.decision_id)
        record = Enum.find(updated.overrides, &(&1.action_id == updated.active_action_id))
        recover(next, updated, record)

      {:error, reason, next} ->
        updated = Map.fetch!(next.current, decision.decision_id)
        record = Enum.find(updated.overrides, &(&1.action_id == updated.active_action_id))
        fail(next, updated, record, reason)
    end
  end

  defp record_fact(%{writable?: true, health: :writable} = state, id, {type, data}) do
    case CommandFacts.record(state, id, type, data, []) do
      {:reply, {:ok, %{decision: decision}}, next} -> {:ok, Dispatch.maybe_schedule_after_answer(next, decision, false)}
      {:reply, {:error, reason}, next} -> {:error, reason, next}
    end
  end

  defp record_fact(state, _id, _fact), do: {:error, :store_read_only, state}

  defp fail(state, decision, record, reason) do
    detail = Aiur.SecretRedactor.redact(inspect(reason))
    Logger.warning("aiur_decision_store phase=corrective_override_reconcile_failed decision_id=#{decision.decision_id} reason=#{detail}")
    data = CorrectiveFailures.build(record, reason, state.corrective_override_now.())
    prior = Map.get(record, :failure) || %{}
    data = if data.alerted and not Map.get(prior, :alerted, false), do: %{data | alerted: alert(state, decision, record, data) == :ok}, else: data

    case CommandFacts.record(state, decision.decision_id, :override_corrective_failed, data, []) do
      {:reply, {:ok, _result}, next} ->
        next

      {:reply, {:error, _reason}, next} ->
        next
    end
  end

  defp recover(state, decision, %{failure: failure} = record) when is_map(failure) do
    case CommandFacts.record(state, decision.decision_id, :override_corrective_recovered, %{action_id: record.action_id}, []) do
      {:reply, {:ok, _result}, next} ->
        if failure.alerted, do: resolve_alert(next, decision, record, "Corrective reconciliation succeeded")
        next

      {:reply, {:error, _reason}, next} ->
        next
    end
  end

  defp recover(state, _decision, _record), do: state

  defp clear_failure(state, decision, record) do
    case CommandFacts.record(state, decision.decision_id, :override_corrective_recovered, %{action_id: record.action_id}, []) do
      {:reply, _result, next} -> next
    end
  end

  defp alert(state, decision, record, data) do
    state.corrective_override_alert.(topic(decision, record), "Corrective ticket work failed for Command #{decision.decision_id}.",
      issue: decision.ticket.identifier,
      reason: "#{data.reason}; attempt #{data.attempts}; retry at #{DateTime.to_iso8601(data.retry_at)}",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp resolve_alert(state, decision, record, reason) do
    state.corrective_override_alert.(topic(decision, record) <> ".resolved", "Corrective ticket failure is no longer active for Command #{decision.decision_id}.",
      issue: decision.ticket.identifier,
      reason: reason,
      needs_attention: false
    )
  end

  defp topic(decision, record), do: "ticket.#{decision.ticket.identifier}.agent.attention.command-corrective-#{String.replace(record.action_id, "_", "-")}"
end
