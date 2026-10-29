defmodule Aiur.DecisionStore.CorrectiveOverrides do
  @moduledoc false
  require Logger
  alias Aiur.Commands.CorrectiveTicket
  alias Aiur.DecisionDispatchTasks
  alias Aiur.DecisionStore.{CommandFacts, Dispatch}

  @spec configure(map(), keyword()) :: map()
  def configure(state, opts) do
    Map.merge(state, %{corrective_override_jobs: %{}, corrective_override_reconciler: Keyword.get(opts, :corrective_override_reconciler, &CorrectiveTicket.reconcile/2)})
  end

  @spec reconcile(map()) :: map()
  def reconcile(%{writable?: true, health: :writable} = state) do
    Enum.reduce(state.current, state, fn {_id, decision}, acc ->
      case Enum.find(decision.overrides, &(&1.action_id == decision.active_action_id)) do
        %{route: :corrective_ticket, state: status} = record when status not in [:superseded, :implemented] -> enqueue(acc, decision, record)
        _other -> acc
      end
    end)
  end

  def reconcile(state), do: state

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
      {:error, reason} -> log_failure(state, decision.decision_id, reason)
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

    case result do
      {:ok, facts} when is_list(facts) -> Enum.reduce(facts, state, &record_fact(&2, correlation.decision_id, &1))
      {:error, reason} -> log_failure(state, correlation.decision_id, reason)
      other -> log_failure(state, correlation.decision_id, {:invalid_result, other})
    end
  end

  defp record_fact(%{writable?: true, health: :writable} = state, id, {type, data}) do
    case CommandFacts.record(state, id, type, data, []) do
      {:reply, {:ok, %{decision: decision}}, next} -> Dispatch.maybe_schedule_after_answer(next, decision, false)
      {:reply, {:error, reason}, next} -> log_failure(next, id, reason)
    end
  end

  defp record_fact(state, _id, _fact), do: state

  defp log_failure(state, id, reason) do
    detail = Aiur.SecretRedactor.redact(inspect(reason))
    Logger.warning("aiur_decision_store phase=corrective_override_reconcile_failed decision_id=#{id} reason=#{detail}")
    state
  end
end
