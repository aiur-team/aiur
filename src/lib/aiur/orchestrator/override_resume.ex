defmodule Aiur.Orchestrator.OverrideResume do
  @moduledoc "Admits journal-backed override resumes independently of ordinary candidate dispatch."

  require Logger
  alias Aiur.{Commands, Issue, Tracker}
  alias Aiur.Orchestrator.{AutoResume, ControlLifecycle, Dispatcher, DispatchPolicy, IssueSync, OverrideRecovery, OverrideSuccessor, Slots, State, TrackerTasks}
  alias Aiur.Orchestrator.Dispatcher.Capacity
  alias Aiur.Orchestrator.PauseResume.{QueuedDispatch, Resume}

  @spec schedule(State.t(), [Issue.t()]) :: State.t()
  def schedule(state, _issues) do
    case waiting(Commands.list_decisions(Commands.default_store())) do
      [] -> state
      requests -> TrackerTasks.run(state, :override_resumes, fn -> load(requests) end, &apply_loaded/2)
    end
  end

  defp load(requests) do
    Enum.map(requests, fn decision ->
      identifier = Commands.override_target_ticket(decision).identifier
      record = Commands.pending_override(decision)
      pr = if record.pr_number, do: Aiur.CodeHost.override_pull_request(record.pr_number), else: Tracker.ticket_pull_request(identifier)
      {decision, Tracker.fetch_issue_states_by_ids([identifier]), pr}
    end)
  end

  @doc false
  @spec waiting([Aiur.Decision.t()]) :: [Aiur.Decision.t()]
  def waiting(decisions) do
    decisions
    |> Enum.filter(fn decision ->
      case Commands.pending_resume_override(decision) do
        %{state: :queued} -> true
        _ -> false
      end
    end)
    |> Enum.sort_by(&DateTime.to_unix(Commands.pending_override(&1).queued_at, :microsecond))
    |> Enum.uniq_by(&Commands.override_target_ticket(&1).identifier)
  end

  @doc false
  @spec apply_loaded(State.t(), term(), keyword()) :: State.t()
  def apply_loaded(state, result, opts \\ [])

  def apply_loaded(state, result, opts) when is_list(result) do
    Enum.reduce(result, state, fn
      {snapshot, {:ok, [%Issue{} = issue]}, {:ok, pr}}, current when is_nil(pr) or is_map(pr) ->
        if is_nil(pr) or Map.get(pr, :merged?) == false, do: apply_one(current, snapshot, issue, pr, opts), else: current

      _, current ->
        current
    end)
  end

  def apply_loaded(state, error, _opts) do
    Logger.warning("Override resume lookup failed: #{inspect(error)}")
    state
  end

  defp apply_one(state, snapshot, issue, pr, opts) do
    store = Keyword.get(opts, :decision_store, Commands.default_store())

    with {:ok, %{decision: decision}} <- Commands.get(snapshot.decision_id, store: store),
         true <- decision.active_action_id == snapshot.active_action_id,
         true <- Commands.override_target_ticket(decision).identifier == issue.identifier,
         %{state: :queued} <- Commands.pending_resume_override(decision) do
      entry = State.find_running_by_identifier(state.running, issue.identifier)
      entry = if entry, do: Map.put(entry, :issue, issue)
      current = put_issue(state, issue, entry)

      route(current, decision, issue, entry, pr, opts)
    else
      _stale_or_unavailable -> state
    end
  end

  defp route(current, decision, issue, entry, pr, opts) do
    store = Keyword.get(opts, :decision_store, Commands.default_store())

    cond do
      explicit_pause?(current, issue, entry) and not retiring?(decision) ->
        persist_wait(decision, :resume_pending, :operator_pause, store)
        Keyword.get(opts, :ask_fun, &ask_resume/2).(decision, store)
        current

      retiring?(decision) ->
        OverrideSuccessor.schedule(current, decision, issue, entry, pr, opts)

      true ->
        route_worker(current, decision, issue, entry, pr, opts)
    end
  end

  defp route_worker(current, decision, issue, entry, pr, opts) do
    cond do
      not eligible_issue?(issue) ->
        current

      current.globally_paused ->
        current

      active?(entry) ->
        current

      pending_resume?(current) ->
        current

      not admitted?(current, entry, opts) ->
        persist_wait(decision, :capacity_wait, :capacity, Keyword.get(opts, :decision_store, Commands.default_store()))
        current

      true ->
        case OverrideRecovery.reason(Commands.pending_override(decision), entry, pr, opts) do
          nil -> resume_admitted(current, decision, issue, entry, pr, opts)
          reason -> recover(current, decision, issue, entry, pr, reason, opts)
        end
    end
  end

  defp resume_admitted(current, decision, issue, entry, pr, opts) do
    store = Keyword.get(opts, :decision_store, Commands.default_store())

    case persist_wait(decision, :resume_pending, :eligible, store) do
      :ok ->
        {reply, next} = Keyword.get(opts, :resume_fun, &resume/3).(current, issue, entry)

        case reply do
          {:error, reason} -> resume_failed(next, decision, issue, entry, pr, reason, opts)
          _ -> next
        end

      {:error, _} ->
        current
    end
  end

  defp resume_failed(state, decision, issue, entry, pr, reason, opts) do
    attempts = Map.get(Commands.pending_override(decision), :resume_attempts, 0)

    cond do
      OverrideRecovery.capacity?(reason) ->
        OverrideRecovery.persist(decision, :capacity_wait, :capacity, attempts, opts)
        state

      attempts + 1 >= AutoResume.max_attempts() ->
        recover(state, decision, issue, entry, pr, :resume_failed, Keyword.put(opts, :resume_attempts, attempts + 1))

      true ->
        OverrideRecovery.persist(decision, :resume_pending, :resume_failed, attempts + 1, opts)
        state
    end
  end

  defp recover(state, decision, issue, entry, pr, reason, opts) do
    attempts = Keyword.get(opts, :resume_attempts, Map.get(Commands.pending_override(decision), :resume_attempts, 0))

    with :ok <- OverrideRecovery.persist(decision, :replacement, reason, attempts, opts),
         {:ok, %{decision: decision}} <- Commands.get(decision.decision_id, store: Keyword.get(opts, :decision_store, Commands.default_store())) do
      recover_current(state, decision, issue, entry, pr, reason, attempts, opts)
    else
      {:error, _} -> state
    end
  end

  defp recover_current(state, decision, issue, entry, pr, reason, attempts, opts) do
    if reason in [:branch_missing, :pr_closed] do
      OverrideSuccessor.schedule(state, decision, issue, entry, pr, opts)
    else
      {reply, next} = Keyword.get(opts, :replacement_fun, &OverrideRecovery.replace/5).(state, issue, entry, pr, opts)
      replacement_result(reply, decision, attempts, opts)
      next
    end
  end

  defp replacement_result({:error, _}, decision, attempts, opts) do
    OverrideRecovery.persist(decision, :replacement, :replacement_failed, attempts, opts)
    ask_recovery(decision, opts)
  end

  defp replacement_result(_reply, _decision, _attempts, _opts), do: :ok

  defp ask_recovery(decision, opts) do
    Commands.request(
      %{
        question: "Recover override for ##{Commands.override_target_ticket(decision).identifier}?",
        blocking: false,
        authority: :supervisor_allowed,
        reversibility: :reversible,
        source_id: "override-recovery-#{decision.active_action_id}",
        context: %{
          long_context_markdown:
            "Replacement failed for Command #{decision.decision_id}. The override remains queued. Restore the existing branch/worker, or retire the old PR and continue in a successor ticket."
        }
      },
      [
        ticket: %{identifier: "executor"},
        requester: %{kind: :executor, executor_id: "override-recovery"},
        source: %{agent_id: "executor", session_id: "override-recovery", event_id: decision.active_action_id}
      ],
      Keyword.get(opts, :decision_store, Commands.default_store())
    )
  end

  defp eligible_issue?(issue) do
    terminal = DispatchPolicy.terminal_state_set()

    DispatchPolicy.issue_routable_to_worker?(issue) and DispatchPolicy.issue_dispatch_authorized?(issue) and
      DispatchPolicy.active_issue_state?(issue.state, DispatchPolicy.active_state_set()) and
      not DispatchPolicy.terminal_issue_state?(issue.state, terminal) and
      not DispatchPolicy.issue_held_by_dependency?(issue, terminal)
  end

  defp admitted?(state, entry, opts) do
    fleet? = if entry, do: Slots.resume_fleet_slot_available?(state, entry), else: Slots.available_slots(state) > 0
    # Admission may reuse this worker's reserved pause slot; never reserve it twice.
    admission_state = if entry, do: elem(State.pop_running_entry(state, entry.issue.id), 1), else: state
    admission = Keyword.get(opts, :admission_fun, &Capacity.auto_resume_admission/1)
    fleet? and admission.(admission_state) == :dispatch
  end

  defp retiring?(decision) do
    case Commands.pending_override(decision) do
      %{route: :replacement, resume_reason: reason} when reason in [:branch_missing, :pr_closed] -> true
      _ -> false
    end
  end

  defp explicit_pause?(state, issue, entry),
    do: Issue.parked?(issue) or Issue.paused?(issue) or operator_paused?(state, entry)

  defp operator_paused?(_state, nil), do: false

  defp operator_paused?(state, entry) do
    Map.get(entry, :paused_reason) == :operator_pause or
      match?(%{action: :pause, requester: :operator}, ControlLifecycle.current_pending(state.control_lifecycle, entry.issue.id))
  end

  defp active?(nil), do: false
  defp active?(%{control: %{status: :unrecoverable}}), do: false
  defp active?(%{pid: pid} = entry) when is_pid(pid) and node(pid) == node(), do: Process.alive?(pid) and State.active_running_entry?(entry) and not State.sleeping_running_entry?(entry)
  defp active?(entry), do: State.active_running_entry?(entry) and not State.sleeping_running_entry?(entry)

  # A control resume is not yet an active slot. Serialize until its receipt so
  # two released CI-wait reservations cannot both consume the last fleet slot.
  defp pending_resume?(state) do
    Enum.any?(state.running, fn {id, _} ->
      match?(%{action: :resume}, ControlLifecycle.current_pending(state.control_lifecycle, id))
    end)
  end

  defp resume(state, issue, nil) do
    case QueuedDispatch.queued_issue_resumability(state, issue) do
      :ok -> Dispatcher.dispatch_prevalidated_issue(state, issue)
      error -> {error, state}
    end
  end

  defp resume(state, _issue, entry), do: Resume.do_resume_running_issue(state, entry)

  defp put_issue(state, issue, nil), do: IssueSync.remember_issue(state, issue)
  defp put_issue(state, issue, entry), do: Resume.put_running_entry(state, issue.id, entry)

  defp persist_wait(decision, route, reason, store) do
    record = Commands.pending_override(decision)

    if record.route != route or Map.get(record, :resume_reason) != reason do
      case Commands.record_command_fact(
             decision.decision_id,
             :override_resume_state,
             %{action_id: decision.active_action_id, route: route, reason: reason, attempts: Map.get(record, :resume_attempts, 0)},
             server: store
           ) do
        {:ok, _} ->
          :ok

        {:error, error} ->
          Logger.warning("Override resume state persistence failed: #{inspect(error)}")
          {:error, error}
      end
    else
      :ok
    end
  end

  defp ask_resume(decision, store) do
    identifier = Commands.override_target_ticket(decision).identifier
    source_id = "override-resume-#{identifier}"

    Commands.request(
      %{
        question: "Resume ##{identifier} to apply the override?",
        options: [%{id: "resume", label: "Resume the existing worker"}, %{id: "keep", label: "Keep the ticket parked"}],
        authority: :supervisor_allowed,
        reversibility: :reversible,
        blocking: false,
        source_id: source_id,
        context: %{
          long_context_markdown:
            "Command #{decision.decision_id} has a pending override. The ticket or worker was explicitly parked or paused by the operator. To apply it, resume this same ticket through the normal operator resume control. Without a resume it stays parked; no replacement ticket is created."
        }
      },
      [
        ticket: %{identifier: "executor"},
        requester: %{kind: :executor, executor_id: "override-resume", ticket: identifier},
        source: %{agent_id: "executor", session_id: "override-resume", event_id: source_id}
      ],
      store
    )
  end
end
