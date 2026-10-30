defmodule Aiur.Orchestrator.OverrideRecoveryRead do
  @moduledoc "Fresh recovery evidence with journal-backed bounded retry; ordinary resumes use cached PRs."

  require Logger
  alias Aiur.{CodeHost, Commands, Tracker}
  alias Aiur.Orchestrator.{State, TrackerTasks}

  @spec schedule(State.t(), map(), Aiur.Issue.t(), keyword(), function()) :: State.t()
  def schedule(state, decision, issue, opts, apply_result) do
    record = Commands.pending_override(decision)
    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))

    if now >= (Map.get(record, :read_retry_at) || 0) do
      TrackerTasks.run(state, {:override_recovery_read, issue.id}, fn -> read(record, issue, opts) end, fn current, result ->
        settle(current, decision, result, opts, apply_result)
      end)
    else
      state
    end
  end

  defp read(record, issue, opts) do
    pr = Keyword.get(opts, :recovery_read_fun, &CodeHost.override_pull_request/1)
    issues = Keyword.get(opts, :recovery_issue_fun, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, fresh} <- pr.(record.pr_number),
         {:ok, [latest]} <- issues.([issue.identifier]) do
      {:ok, latest, fresh}
    else
      {:error, _} = error -> error
      _ -> {:error, :recovery_evidence_missing}
    end
  end

  defp settle(state, snapshot, result, opts, apply_result) do
    store = Keyword.get(opts, :decision_store, Commands.default_store())

    with {:ok, %{decision: current}} <- Commands.get(snapshot.decision_id, store: store),
         true <- current.active_action_id == snapshot.active_action_id do
      settle_current(state, current, result, opts, apply_result)
    else
      _ -> state
    end
  end

  defp settle_current(state, decision, {:ok, issue, pr}, opts, apply_result) do
    record = Commands.pending_override(decision)
    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    read = %{read_attempts: 0, read_retry_at: now + 60_000}
    read = if match?(%{state: :open, branch_exists?: true}, pr) and record.resume_reason in [:branch_missing, :pr_closed], do: Map.put(read, :reason, :eligible), else: read

    case persist(decision, read, opts) do
      :ok -> apply_result.(state, [{decision, {:ok, [issue]}, {:ok, pr}}], Keyword.put(opts, :recovery_verified, true))
      {:error, _} -> state
    end
  end

  defp settle_current(state, decision, {:error, reason}, opts, _apply_result) do
    record = Commands.pending_override(decision)
    attempts = Map.get(record, :read_attempts, 0) + 1
    delay_ms = min(60_000 * Integer.pow(2, min(attempts - 1, 6)), 3_600_000)
    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    Logger.warning("Override recovery read deferred: command=#{decision.decision_id} reason=#{inspect(reason)}")
    persist(decision, %{read_attempts: attempts, read_retry_at: now + delay_ms}, opts)
    state
  end

  defp persist(decision, read, opts) do
    record = Commands.pending_override(decision)
    data = Map.merge(%{action_id: decision.active_action_id, route: record.route, reason: record.resume_reason, attempts: Map.get(record, :resume_attempts, 0)}, read)

    case Commands.record_command_fact(decision.decision_id, :override_resume_state, data, server: Keyword.get(opts, :decision_store, Commands.default_store())) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end
end
