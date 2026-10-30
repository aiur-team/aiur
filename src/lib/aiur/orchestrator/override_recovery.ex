defmodule Aiur.Orchestrator.OverrideRecovery do
  @moduledoc "Recovers queued overrides without starting a competing worker."

  alias Aiur.{Commands, Config, Issue, Workspace}
  alias Aiur.Orchestrator.{AgentTeardown, AutoResume, Dispatcher, State}

  @spec reason(map(), map() | nil, map() | nil, keyword()) :: atom() | nil
  def reason(record, entry, pr, opts) do
    cond do
      match?(%{state: :closed, merged?: false}, pr) -> :pr_closed
      match?(%{branch_exists?: false}, pr) -> :branch_missing
      record.route == :replacement -> Map.get(record, :resume_reason, :worker_unrecoverable)
      Map.get(record, :resume_attempts, 0) >= AutoResume.max_attempts() -> :resume_failed
      match?(%{control: %{status: :unrecoverable}}, entry) -> :worker_unrecoverable
      workspace_missing?(entry) or cold_workspace_missing?(record, entry, pr, opts) -> :workspace_missing
      true -> nil
    end
  end

  defp workspace_missing?(%{workspace_path: path} = entry) when is_binary(path), do: is_nil(Map.get(entry, :worker_host)) and not File.dir?(path)
  defp workspace_missing?(_), do: false

  defp cold_workspace_missing?(record, nil, %{state: :open}, opts) do
    path = Keyword.get(opts, :workspace_path_fun, fn identifier -> Workspace.workspace_path_under(Config.workspace_root(), identifier) end)
    not File.dir?(path.(record.ticket.identifier))
  end

  defp cold_workspace_missing?(_, _, _, _), do: false

  @spec capacity?(term()) :: boolean()
  def capacity?(:max_concurrent_agents_reached), do: true
  def capacity?({:max_concurrent_agents_reached, _}), do: true
  def capacity?({:redispatch_deferred, reason}), do: capacity?(reason)
  def capacity?(_), do: false

  @spec persist(map(), atom(), atom(), non_neg_integer(), keyword()) :: :ok | {:error, term()}
  def persist(decision, route, reason, attempts, opts) do
    case Commands.record_command_fact(decision.decision_id, :override_resume_state, %{action_id: decision.active_action_id, route: route, reason: reason, attempts: attempts},
           server: Keyword.get(opts, :decision_store, Commands.default_store())
         ) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @spec replace(State.t(), Issue.t(), map() | nil, map() | nil, keyword()) :: {term(), State.t()}
  def replace(state, issue, entry, pr, opts) do
    # Keep ticket identity (and its lease) while explicitly selecting the existing PR branch.
    issue = %{issue | continuation_head_ref: if(pr, do: Map.get(pr, :head_ref))}
    stop = Keyword.get(opts, :stop_fun, &stop/3)
    state = stop.(state, issue, entry)
    dispatch = Keyword.get(opts, :dispatch_fun, fn state, issue -> dispatch(state, issue, opts) end)
    dispatch.(state, issue)
  end

  defp stop(state, _issue, nil), do: state
  defp stop(state, issue, _entry), do: AgentTeardown.terminate_running_issue(state, issue.id, false)

  defp dispatch(state, issue, opts) do
    next = Dispatcher.do_dispatch_issue(state, issue, nil, nil, Keyword.merge(opts, prior_work: true, fresh_session: true))

    if Map.has_key?(next.running, issue.id),
      do: {{:ok, :started}, next},
      else: {{:error, :replacement_failed}, next}
  end
end
